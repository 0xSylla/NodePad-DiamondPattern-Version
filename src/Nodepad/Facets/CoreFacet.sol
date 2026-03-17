//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import "../Libraries/LibNodeManagementSystem.sol";
import "../Libraries/LibReferralSystem.sol";
import "../Libraries/PriceConverter.sol";
import "../Libraries/LibAppStorage.sol";
import "./Modifiers.sol";

contract CoreFacet is Modifiers{

    using PriceConverter for uint256;

    // =============================================================================
    // =============================== ERRORS ======================================
    // =============================================================================

    error GameCore__PlayerAlreadyJoined();
    error GameCore__RefundFailed(string reason);
    error GameCore__MaxNodePadLevelReached(uint256 currentLevel, string reason);
    error GameCore__CoolDownTimeNotReached(uint256 timePassedSinceLastUpgrade, uint256 currentLevelCooldownTime, string reason);
    error GameCore__InsufficientBalance(uint256 userBalance, uint256 upgradePrice, string reason);
    error NodeManagement__InvalidNumberOfPacks(uint256 numberOfPacks, string reason);
    error NodeManagement__InsufficientIngameTokenBalance(uint256 totalCostInGameToken, uint256 PlayerInGameTokenBalance, string reason);
    error NodeManagement__InsufficientNativeToken(uint256 totalCost,uint256 playerBalance, string reason);
    error NodeManagement__RefundFailed(string reason);

    // =============================================================================
    // =============================== EVENTS ======================================
    // =============================================================================

    event NewPlayerJoinedTheGame(address indexed sender);
    event NodePadUpgraded(address sender, uint256 nextLevel);
    event NewPackRipped(address buyer, LibAppStorage.NodeClass class);
    event PlayerReferred(address sender, address referrer,string newReferralCode, bool isInitialPlayer);

    // =============================================================================
    // ==================== PLAYER ONBOARDING ======================================
    // =============================================================================

    /**
     * @notice Join the game with a referral code
     * @param _referralCode Referral code  for first 200 players
     * 
     * Effects:
     * - Creates a new NodePad for the player
     * - Gives a free D_RANK node (activated)
     * - Starts at level 1 with 2 slots and 6 energy capacity
     * - Registers referral relationship
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must not have already joined
     * - Referral code must be valid
     */
    function joinGame(string memory _referralCode) public isPhase1Ongoing {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if (s.hasJoined[msg.sender]) {
            revert GameCore__PlayerAlreadyJoined();
        }

        // Process Referral
        (address referrer, bool isInitialPlayer, string memory newReferralCode) = LibReferralSystem._processReferral(_referralCode);

        // Add player to the game
        s.totalPlayersList.push(msg.sender);
        s.hasJoined[msg.sender] = true;
        // Update rewards before adding new player
        LibNodeManagementSystem._distributeRewards();
        // Initialize Player NodePad with a DRANK Node
        LibAppStorage.NodePad storage newNodePad = s.PlayerToNodePads[msg.sender];
        LibAppStorage.Node memory startingUnit = LibAppStorage.getNode(0);
        newNodePad.VPSLevel = 1;
        newNodePad.nodefolio.push(s.nodeCounter);
        s.nodeCounter++;
        newNodePad.lastVPSUpgradeTime = block.timestamp;
        (,,,uint256 cooldowTime) = LibAppStorage.getVPSLevelStats(1);
        newNodePad.currentVPSLevelCooldownTime = cooldowTime;
        s.totalNetworkHashPower += startingUnit.hashPower;


        emit NewPlayerJoinedTheGame(msg.sender);
        emit PlayerReferred(msg.sender, referrer, newReferralCode, isInitialPlayer);
    }

    /**
     * @notice Upgrade player's NodePad to the next level
     * @dev Increases slots, energy capacity, and sets new cooldown
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must have joined
     * - Not at maximum level (10)
     * - Cooldown period must have passed
     * - Sufficient payment token balance
     * - Sufficient allowance
     * 
     * Effects:
     * - Increases NodePad level
     * - Adds more node slots
     * - Increases energy capacity
     * - Sets new cooldown time
     * - Transfers payment tokens to contract
     */
    function upgradeNodePad() public payable isPhase1Ongoing hasPlayerJoined {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];
        // Check if player is already at max level
        uint256 currentLevel = playerNodePad.VPSLevel;
        if(currentLevel >= 10) {
            revert GameCore__MaxNodePadLevelReached(currentLevel, "You reached the max level of 10");
        }
        
        // Check cooldown - player must wait before upgrading
        uint256 timeSinceLastUpgrade = block.timestamp - playerNodePad.lastVPSUpgradeTime;
        (,,,uint256 currentLevelCooldowTime) = LibAppStorage.getVPSLevelStats(currentLevel);
        if(timeSinceLastUpgrade < currentLevelCooldowTime) {
            revert GameCore__CoolDownTimeNotReached(timeSinceLastUpgrade, currentLevelCooldowTime, "Cooldown Time not finished");
        }
        
        // Get upgrade info for the next level (array index is currentLevel - 1 since level 1 has no upgrade yet)
        (,,uint256 upgradePrice,uint256 upgradeCooldowTime) = LibAppStorage.getVPSLevelStats(currentLevel + 1);
        
        // Check if player has sufficient balance
        if(msg.value.ethToUsd() < upgradePrice) {
            revert GameCore__InsufficientBalance(msg.value, upgradePrice.usdToEth(), "Insufficient Balance(ETH)");
        }
        if(msg.value.ethToUsd() > upgradePrice) {
                (bool success, ) = msg.sender.call{value: msg.value - upgradePrice.usdToEth()}("");
                require(success, "Refund failed");
                if(!success){
                    revert GameCore__RefundFailed("Refund of Excess fund during pack buyout");
                }
        }
        
        // Apply upgrades
        uint256 nextLevel = currentLevel + 1;
        playerNodePad.VPSLevel = nextLevel;
        playerNodePad.lastVPSUpgradeTime = block.timestamp;
        playerNodePad.currentVPSLevelCooldownTime = upgradeCooldowTime; 
        s.gameGlobalAnalytics.totalUpgradesSold[nextLevel] += 1;

        //Distribute InGameTokenRewards
        LibNodeManagementSystem._distributeRewards();
        
        emit NodePadUpgraded(msg.sender, nextLevel);
    }
        /**
     * @notice Purchase multiple node packs at once
     * @dev Each pack is ripped to reveal a random node based on tier probabilities
     * @param numberOfPacks Number of packs to purchase (1-1000)
     * 
     * Tier Distribution:
     * - D_RANK: 50% (0-4999)
     * - C_RANK: 25% (5000-7499)
     * - B_RANK: 15% (7500-8999)
     * - A_RANK: 9% (9000-9899)
     * - S_RANK: 1% (9900-9999)
     */
    function purchaseNodePack(uint256 numberOfPacks, bool withInGameToken) public payable isPhase1Ongoing hasPlayerJoined {
        if(numberOfPacks == 0 || numberOfPacks > 1000){
            revert NodeManagement__InvalidNumberOfPacks(numberOfPacks, "Number of packs must be between 1 and 1000");
        }
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];

        //Distribute InGameToken Rewards
        LibNodeManagementSystem._distributeRewards();

        if(withInGameToken){
            // Calculate total cost for bulk purchase in Game token
            uint256 totalCostInGameToken = s.PriceNodePackInGameToken * numberOfPacks;
            // Check if player has enough balance
            if(s.PlayerToNodePads[msg.sender].inGameTokenBalance < totalCostInGameToken) {
                revert NodeManagement__InsufficientIngameTokenBalance(totalCostInGameToken, s.PlayerToNodePads[msg.sender].inGameTokenBalance, "Insufficient InGameToken Balance");
            }
            
            s.PlayerToNodePads[msg.sender].inGameTokenBalance -= totalCostInGameToken;
            s.gameGlobalAnalytics.totalPacksBoughtInGameToken += numberOfPacks;
        }else{
            // Calculate total cost for bulk purchase in Payment token
            uint256 totalCost = s.PriceNodePackUSD * numberOfPacks;
            
            // Check if player has enough balance
            if(msg.value.ethToUsd() < totalCost) {
                revert NodeManagement__InsufficientNativeToken(totalCost.usdToEth(), msg.value, "Insuficient amount sent(Native Token)");
            }
            
            if(msg.value.ethToUsd() > totalCost) {
                (bool success, ) = msg.sender.call{value: msg.value - totalCost.usdToEth()}("");
                require(success, "Refund failed");
                if(!success){
                    revert NodeManagement__RefundFailed("Refund of Excess fund during pack buyout");
                }
            }
            //Adds referral reward to the referrer when referee makes a purchase
            LibReferralSystem._addReferralReward(totalCost.usdToEth());
        }

        //Update Game Analytics
        s.gameGlobalAnalytics.totalPacksBought += numberOfPacks;
        
        // Rip each pack and add Node to player's inventory
        for(uint256 i = 0; i < numberOfPacks; i++) {
            LibAppStorage.Node memory newNode = LibNodeManagementSystem._ripPack(i);

            newNode.nodeOwner = msg.sender;
            s.IdToNodes[s.nodeCounter]= newNode;
            

            playerNodePad.nodefolio.push(s.nodeCounter);
            s.nodeCounter++;

            emit NewPackRipped(msg.sender, newNode.nodeClass);
        }

    }
}