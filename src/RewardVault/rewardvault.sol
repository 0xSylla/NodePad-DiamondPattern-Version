// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Interfaces/IRewardVault.sol";

contract DummyRewardToken is ERC20 {
    constructor() ERC20("Dummy Reward Token", "DRT") {
        _mint(address(this), 1);
    }
}

contract RewardVault is ERC4626, Ownable, IRewardVault {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    IERC20 public rewardToken;
    bool public rewardTokenSet;
    uint256 public totalRewardDeposited;
    uint256 public initialRewardBalance;
    uint256 public constant FORFEIT_INITIAL_RATE = 0.69 * 1e18;
    uint256 public totalForfeited;
    DummyRewardToken private immutable dummyToken;

    address[] private _holders;          // Track all share holders
    mapping(address => bool) private _hasClaimed;  // Track who claimed
    mapping(address => bool) private _isHolder; 

    // --- Pause System Variables ---
    bool public paused;
    uint256 public pausedAt;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    // --- Events ---
    event RewardTokenSet(address indexed rewardTokenAddress);
    event RewardTokensDeposited(uint256 amount);
    event RewardTokensClaimed(
        address indexed user,
        uint256 shares,
        uint256 claimedAmount,
        uint256 forfeitAmount,
        uint256 forfeitRate
    );
    event ForfeitRedistributed(uint256 amount, uint256 remainingReward);
    event Paused(address indexed by, string reason);
    event Unpaused(address indexed by);

    // --- Modifiers ---
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(IERC20(address(new DummyRewardToken()))) Ownable(msg.sender) {
        dummyToken = DummyRewardToken(address(asset()));
    }

    // --- Pause Functions ---

    /**
     * @dev Pause normal operations (redemptions disabled, but view functions work)
     * @param reason Human-readable reason for pausing
     */
    function pause(string calldata reason) external onlyOwner {
        require(!paused, "Already paused");
        paused = true;
        pausedAt = block.timestamp;
        emit Paused(msg.sender, reason);
    }

    /**
     * @dev Unpause normal operations
     */
    function unpause() external onlyOwner {
        require(paused, "Not paused");
        paused = false;
        pausedAt = 0;
        emit Unpaused(msg.sender);
    }

    /**
     * @dev Auto-unpause if MAX_PAUSE_DURATION exceeded (safety mechanism)
     * Can be called by anyone
     */
    function checkAndUnpause() external {
        require(paused, "Not paused");
        require(pausedAt > 0, "Invalid pause state");
        require(block.timestamp >= pausedAt + MAX_PAUSE_DURATION, "Pause duration not exceeded");
        
        paused = false;
        pausedAt = 0;
        emit Unpaused(address(0)); // address(0) indicates auto-unpause
    }

    /**
     * @dev Get current pause status and timing information
     */
    function getPauseStatus() external view returns (
        bool isPaused,
        uint256 pausedTimestamp,
        uint256 timeUntilAutoUnpause
    ) {
        isPaused = paused;
        pausedTimestamp = pausedAt;
        
        if (paused && pausedAt > 0) {
            uint256 elapsed = block.timestamp - pausedAt;
            timeUntilAutoUnpause = elapsed >= MAX_PAUSE_DURATION ? 0 : MAX_PAUSE_DURATION - elapsed;
        } else {
            timeUntilAutoUnpause = 0;
        }
    }

    // --- Core Functions (with pause protection) ---

    function setRewardToken(address rewardTokenAddress) external onlyOwner whenNotPaused {
        require(!rewardTokenSet, "Reward token already set");
        require(rewardTokenAddress != address(0), "Invalid address");

        rewardToken = IERC20(rewardTokenAddress);
        rewardTokenSet = true;
        emit RewardTokenSet(rewardTokenAddress);
    }

    function depositRewardTokens(uint256 amount) external onlyOwner whenNotPaused {
        require(rewardTokenSet, "RewardToken token not set");
        require(amount > 0, "Amount must be > 0");

        //rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        totalRewardDeposited += amount;

        if (initialRewardBalance == 0) {
            initialRewardBalance = totalRewardDeposited;
        }

        emit RewardTokensDeposited(amount);
    }

    function redeemForReward(uint256 shares) external whenNotPaused {
        require(rewardTokenSet, "Reward token not set");
        require(shares > 0, "Must redeem > 0 shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");
        require(totalSupply() > 0, "No shares exist");
        require(initialRewardBalance > 0, "Reward tokens not deposited yet");

        _hasClaimed[msg.sender] = true;
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        uint256 baseClaimable = (shares * rewardBalance) / totalSupply();
        uint256 remainingReward = rewardBalance;
        uint256 forfeitRate = (FORFEIT_INITIAL_RATE * remainingReward) / initialRewardBalance;
        uint256 forfeitAmount = (baseClaimable * forfeitRate) / 1e18;
        uint256 finalClaimable = baseClaimable - forfeitAmount;

        require(finalClaimable > 0, "No claimable Reward tokens");

        _burn(msg.sender, shares);
        rewardToken.safeTransfer(msg.sender, finalClaimable);
        totalForfeited += forfeitAmount;

        if (totalSupply() > 0 && forfeitAmount > 0) {
            _redistributeForfeit(forfeitAmount);
        }

        emit RewardTokensClaimed(
            msg.sender,
            shares,
            finalClaimable,
            forfeitAmount,
            forfeitRate
        );
    }

    function _redistributeForfeit(uint256 amount) private {
        if (totalSupply() == 0) return;

        uint256 additionalShares = (amount * totalSupply()) / rewardToken.balanceOf(address(this));

        if (additionalShares > 0) {
            _mint(address(this), additionalShares);
        }
    }

    /// @notice Returns unclaimed users and total beneficiaries (holders)
    /// @return unclaimedUsers Array of addresses with shares but no claims
    /// @return totalBeneficiaries Total number of share holders
    function getUnclaimedUsersAndBeneficiaries()
        external
        view
        returns (address[] memory unclaimedUsers, uint256 totalBeneficiaries)
    {
        totalBeneficiaries = _holders.length;

        // Count unclaimed users first (to size the array)
        uint256 unclaimedCount = 0;
        for (uint256 i = 0; i < _holders.length; i++) {
            address user = _holders[i];
            if (balanceOf(user) > 0 && !_hasClaimed[user]) {
                unclaimedCount++;
            }
        }

        // Allocate array and fill it
        unclaimedUsers = new address[](unclaimedCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _holders.length; i++) {
            address user = _holders[i];
            if (balanceOf(user) > 0 && !_hasClaimed[user]) {
                unclaimedUsers[index] = user;
                index++;
            }
        }
    }

    function previewRewardRedemption(address user) external view returns (uint256 claimable, uint256 forfeitAmount, uint256 forfeitRate) {
        if (!rewardTokenSet || totalSupply() == 0 || initialRewardBalance == 0) {
            return (0, 0, FORFEIT_INITIAL_RATE);
        }

        uint256 userShares = balanceOf(user);
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        uint256 baseClaimable = (userShares * rewardBalance) / totalSupply();
        uint256 remainingReward = rewardBalance;
        forfeitRate = (FORFEIT_INITIAL_RATE * remainingReward) / initialRewardBalance;
        forfeitAmount = (baseClaimable * forfeitRate) / 1e18;
        claimable = baseClaimable - forfeitAmount;
    }

    // --- Getters ---
    function getVaultStats() external view returns (
        uint256 totalShares,
        uint256 availableReward,
        uint256 avgRewardPerShare,
        uint256 currentForfeitRate,
        uint256 totalForfeitedSoFar
    ) {
        totalShares = totalSupply();
        availableReward = rewardTokenSet ? rewardToken.balanceOf(address(this)) : 0;
        avgRewardPerShare = totalShares > 0 ? (availableReward * 1e18) / totalShares : 0;

        if (initialRewardBalance > 0) {
            uint256 remainingReward = rewardToken.balanceOf(address(this));
            currentForfeitRate = (FORFEIT_INITIAL_RATE * remainingReward) / initialRewardBalance;
        } else {
            currentForfeitRate = 0;
        }

        totalForfeitedSoFar = totalForfeited;
    }

    function getCurrentForfeitRate() public view returns(uint256 currentForfeitRate){
        if (initialRewardBalance > 0) {
            uint256 remainingReward = rewardToken.balanceOf(address(this));
            currentForfeitRate = (FORFEIT_INITIAL_RATE * remainingReward) / initialRewardBalance;
        } else {
            currentForfeitRate = 0;
        }
    }

    function getClaimedAndRemainingRewards()
        public
        view
        returns (uint256 totalClaimed, uint256 remainingRewards)
    {
        if (!rewardTokenSet || initialRewardBalance == 0) {
            return (0, 0);
        }
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        totalClaimed = initialRewardBalance - currentBalance;
        remainingRewards = currentBalance;
    }

    /**
    * @dev Returns the base reward allocation (before forfeit) for a user's shares.
    * @param user Address of the user to check.
    * @return baseAllocation The raw reward amount (without forfeit deduction).
    */
    function getUserBaseRewardAllocation(address user) external view returns (uint256 baseAllocation) {
        if (!rewardTokenSet || totalSupply() == 0 || initialRewardBalance == 0) {
            return (0);
        }

        uint256 userShares = balanceOf(user);
        uint256 rewardBalance = rewardToken.balanceOf(address(this));

        baseAllocation = (userShares * rewardBalance) / totalSupply();
    }

    // --- ERC4626 Overrides ---
    function mintShares(address recipient, uint256 shares) external onlyOwner whenNotPaused {
        require(recipient != address(0), "Invalid recipient");
        require(shares > 0, "Must mint > 0 shares");
        _mint(recipient, shares);
        if (!_isHolder[recipient]) {
            _isHolder[recipient] = true;
            _holders.push(recipient);
        }
    }

    function deposit(uint256, address) public virtual override(IERC4626, ERC4626) returns (uint256) {
        revert("Deposits disabled. Shares are minted directly by the game contract.");
    }
}