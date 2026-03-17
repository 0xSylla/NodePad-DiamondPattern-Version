//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20; 

import "../Libraries/LibAppStorage.sol";
import "../Libraries/LibReferralSystem.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@solidstate/contracts/access/ownable/OwnableInternal.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AdminFacet is OwnableInternal{
    using SafeERC20 for IERC20;
    // =============================================================================
    // ================================ ERRORS =====================================
    // =============================================================================

    error Guild__BonusesAlreadyDistributed();
    error GameCore__GuildBonusesNotDistributedYet();
    error GameCore__NotInPhase2(LibAppStorage.GameStatus _gameStatus, string reason);
    error GameCore__AlreadyInPhase2(LibAppStorage.GameStatus _gameStatus, string reason);
    error GameCore__AllInGameTokenNotDistributed(uint256 totalInGameTokenRewardsDistributed, uint256 totalInGameTokenAvailabeForMining, string reason );
    error GameCore__InvalidAddress(address _addressConcerned, string reason);
    error GameCore__NotOnPause();
    error GameCore__AlreadyOnPause(LibAppStorage.GameStatus _gameStatus, string reason);
    error GameCore__NoRewardTokenToTransfer(uint256 _contractBalance, string reason);
    error AdminFacet__EmergencyWithdrawFailed();

    // =============================================================================
    // ================================ EVENTS =====================================
    // =============================================================================

    event GuildBonusDistributed(uint256 indexed GuildId, uint256 totalBonus, uint256 leaderBonus);
    event PhaseTransition(LibAppStorage.GameStatus newPhase);
    event PaymentWithdrawn(address indexed treasuryAddress, uint256 amount);


    // =============================================================================
    // ==================== INITIALIZE FUNCTION ====================================
    // =============================================================================

    function initialize(string memory _initialReferralCode) public onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        s.startTime = block.timestamp;
        s.totalInGameTokenBalance = 69000000;
        s.guildsInGameTokenRewardPool = (s.totalInGameTokenBalance*20)/100;
        s.PriceNodePackUSD = 10e18;
        s.PriceNodePackInGameToken = 300;

        s.rewardVault = new RewardVault("RewardVault","RVT");
    
        s.lastDistributionTime = block.timestamp;
        s.gameStatus = LibAppStorage.GameStatus.PHASE_1;
        s.nodeCounter = 0;
        s.initialReferralCode = _initialReferralCode;
        s.nextGuildId = 1;
    }

    // =============================================================================
    // ==================== PHASE TRANSITION =======================================
    // =============================================================================

    /**
     * @notice Transition from Phase 1 to Phase 2
     * @dev Only callable by owner. Deploys RewardToken and locks Phase 1
     * 
     * Requirements:
     * - Must be in Phase 1
     * - All in-game tokens must be minted (balance == 0)
     * 
     * Effects:
     * - Deploys new RewardToken
     * - Changes game status to PHASE_2
     * - Records Phase 1 end metrics
     * - Locks Phase 1 gameplay (no more joining, mining, etc.)
     */
    function transitionToPhase2() external onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(s.gameStatus == LibAppStorage.GameStatus.PHASE_2){
            revert GameCore__AlreadyInPhase2(s.gameStatus, "Already in phase 2");
        }
        uint256 totalInGameTokenAvailabeForMining = s.totalInGameTokenBalance - s.guildsInGameTokenRewardPool;
        if(s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed < totalInGameTokenAvailabeForMining){
            revert GameCore__AllInGameTokenNotDistributed(s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed, totalInGameTokenAvailabeForMining, "All InGameToken not distributed yet" );
        }
        if(!s.isGuildBonusesDistributed){
            revert GameCore__GuildBonusesNotDistributedYet();
        }
        // Update game status
        s.gameStatus = LibAppStorage.GameStatus.PHASE_2;

        // Deploy reward token for Phase 2 and set it in the reward vault
        s.rewardToken = new RewardToken();
        s.rewardVault.setRewardToken(address(s.rewardToken));

        transferRewardTokensInRewardVault(address(s.rewardVault));

        s.phase2StartTime = block.timestamp;

        // Record Phase 1 end metrics
        s.gameGlobalAnalytics.phase1EndTotalHashpower = s.totalNetworkHashPower;
        s.gameGlobalAnalytics.phase1Duration = block.timestamp - s.startTime;

        emit PhaseTransition(LibAppStorage.GameStatus.PHASE_2);
    }

    /**
     * @notice Transfer reward tokens to reward vault for player claims
     * @param _rewardVaultAddress Reward vault address
     */
    function transferRewardTokensInRewardVault(address _rewardVaultAddress) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(s.gameStatus != LibAppStorage.GameStatus.PHASE_2){
            revert GameCore__NotInPhase2(s.gameStatus, "Phase 2 on pause or not started yet");
        }
        if(_rewardVaultAddress == address(0)){
            revert GameCore__InvalidAddress(_rewardVaultAddress, "Vault Address is invalid");
        }
        
        if(s.rewardToken.balanceOf(address(this)) <= 0){
            revert GameCore__NoRewardTokenToTransfer(s.rewardToken.balanceOf(address(this)), "Contract Balance empty");
        }
        s.rewardVault.depositRewardTokens(s.rewardToken.balanceOf(address(this)));
        IERC20(address(s.rewardToken)).safeTransfer(_rewardVaultAddress, s.rewardToken.balanceOf(address(this)));
        emit PaymentWithdrawn(_rewardVaultAddress, s.rewardToken.balanceOf(address(this)));
    }
    // =============================================================================
    // ==================== BONUS DISTRIBUTION =====================================
    // =============================================================================
    
    /**
     * @notice Distribute bonuses to top 10 Guilds
     */
    function distributeGuildBonuses() external onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if (s.isGuildBonusesDistributed) {
            revert Guild__BonusesAlreadyDistributed();
        }
        
        // Get top 10 Guilds
        uint256[10] memory topGuildIds;
        uint256[10] memory topHashpowers;
        
        for (uint256 GuildId = 1; GuildId < s.nextGuildId; GuildId++) {
            if (!s.guilds[GuildId].exists) continue;
            
            uint256 hashpower = s.guilds[GuildId].totalHashpower;
            
            for (uint256 i = 0; i < 10; i++) {
                if (hashpower > topHashpowers[i]) {
                    // Shift down
                    for (uint256 j = 9; j > i; j--) {
                        topGuildIds[j] = topGuildIds[j-1];
                        topHashpowers[j] = topHashpowers[j-1];
                    }
                    topGuildIds[i] = GuildId;
                    topHashpowers[i] = hashpower;
                    break;
                }
            }
        }
        
        // Distribute bonuses
        uint256 totalWeight = 55; // 10+9+8+...+1
        for (uint256 i = 0; i < 10; i++) {
            if (topGuildIds[i] == 0) break;
            
            uint256 GuildId = topGuildIds[i];
            LibAppStorage.Guild storage guild = s.guilds[GuildId];
            
            uint256 rankWeight = 10 - i;
            uint256 GuildBonus = (s.guildsInGameTokenRewardPool * rankWeight) / totalWeight;
            
            // Leader gets 40%
            uint256 leaderBonus = (GuildBonus * LibAppStorage.LEADER_BONUS_SHARE) / 100;
            
            // Members split 60%
            uint256 memberBonus = (GuildBonus * LibAppStorage.MEMBER_BONUS_SHARE) / 100;
            uint256 perMemberBonus = memberBonus / (guild.memberCount - 1);
            
            // Distribute via game contract
            distributeWinningGuildBonus(guild.leader, leaderBonus);
            _distributeToReferralTree(guild.leader, perMemberBonus);
            
            emit GuildBonusDistributed(GuildId, GuildBonus, leaderBonus);
        }
        
        s.isGuildBonusesDistributed = true;
    }

    /**
     * @notice Distribute Reward to Winning Guild
     * @param player Contract address
     * @param amount Amount of reward to be distributed
     */
    function distributeWinningGuildBonus(address player, uint256 amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        s.PlayerToNodePads[player].totalInGameTokenRewardsEarned += amount;
    }
    
    function _distributeToReferralTree(address referrer, uint256 bonusPerMember) internal {
        (address[] memory directReferees,) = LibReferralSystem.getReferees(referrer);
        
        for (uint256 i = 0; i < directReferees.length; i++) {
            address referee = directReferees[i];
            distributeWinningGuildBonus(referee, bonusPerMember);
            _distributeToReferralTree(referee, bonusPerMember);
        }
    }

    // =============================================================================
    // ==================== EMERGENCY FUNCTIONS ====================================
    // =============================================================================

    /**
     * @notice Emergency withdraw all tokens to a beneficiary
     * @param _beneficiary Address to receive tokens
     * @dev Only use in emergency situations
     */
    function emergencyWithdraw(address _beneficiary) public onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(_beneficiary == address(0)){
            revert GameCore__InvalidAddress(_beneficiary,"Invalid beneficiary address");
        }
        uint256 contractRewardTokenBalance = s.rewardToken.balanceOf(address(this));
        IERC20(address(s.rewardToken)).safeTransfer(_beneficiary, contractRewardTokenBalance);
        (bool success,)= payable(_beneficiary).call{value: address(this).balance}("");
        if(!success){
            revert AdminFacet__EmergencyWithdrawFailed();
        }
        emit PaymentWithdrawn(_beneficiary, address(this).balance);
        emit PaymentWithdrawn(_beneficiary, contractRewardTokenBalance);
    }

    /**
     * @notice Pause the game (emergency use)
     * @dev Can only pause during active phases (not already paused)
     */
    function pauseGame() public onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(s.gameStatus == LibAppStorage.GameStatus.PAUSED_DURING_PHASE_1 || s.gameStatus == LibAppStorage.GameStatus.PAUSED_DURING_PHASE_2){
            revert GameCore__AlreadyOnPause(s.gameStatus, "Game already on pause");
        }
        s.rewardVault.pause("Emergency Pause");
        if(s.gameStatus == LibAppStorage.GameStatus.PHASE_1){
            s.gameStatus = LibAppStorage.GameStatus.PAUSED_DURING_PHASE_1;
        }else{
            s.gameStatus = LibAppStorage.GameStatus.PAUSED_DURING_PHASE_2;
        }
        
    }

    /**
     * @notice Resume the game after pause
     * @dev Restores game to the phase it was in before pausing
     */
    function unpause() public onlyOwner{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(s.gameStatus != LibAppStorage.GameStatus.PAUSED_DURING_PHASE_1 && s.gameStatus != LibAppStorage.GameStatus.PAUSED_DURING_PHASE_2){
            revert GameCore__NotOnPause();
        }
        s.rewardVault.unpause();
        if(s.gameStatus == LibAppStorage.GameStatus.PAUSED_DURING_PHASE_1){
            s.gameStatus = LibAppStorage.GameStatus.PHASE_1;
        }
        if(s.gameStatus == LibAppStorage.GameStatus.PAUSED_DURING_PHASE_2){
            s.gameStatus = LibAppStorage.GameStatus.PHASE_2;
        }
    }
}