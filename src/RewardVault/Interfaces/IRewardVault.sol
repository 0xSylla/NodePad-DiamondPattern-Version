//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IRewardVault
 * @notice Extended interface for RewardVault with custom minting capability
 */
interface IRewardVault is IERC4626 {
    /**
     * @notice Mint vault shares directly to a recipient without requiring deposit
     * @param recipient Address to receive the shares
     * @param shares Amount of shares to mint
     */
    function mintShares(address recipient, uint256 shares) external;
    
    /**
     * @notice Set the Zero token address
     * @param rewardTokenAddress Address of the Reward token
     */
    function setRewardToken(address rewardTokenAddress) external;
    
    /**
     * @notice Deposit Zero tokens for distribution
     * @param amount Amount of Zero tokens to deposit
     */
    function depositRewardTokens(uint256 amount) external;
    
    /**
     * @notice Redeem vault shares for Zero tokens
     * @param shares Amount of shares to redeem
     */
    function redeemForReward(uint256 shares) external;
    

    function previewRewardRedemption(address user) external view returns (uint256 claimable, uint256 forfeitAmount, uint256 forfeitRate);
}