///SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LibAppStorage.sol";

library LibNodeManagementSystem{

    // =============================================================================
    // ============================== ERRORS =======================================
    // =============================================================================
    error NodeManagement__InsufficientIngameTokenBalance(uint256 totalCostInGameToken, uint256 PlayerInGameTokenBalance, string reason);
    error NodeManagement__RefundFailed(string reason);
    error NodePad__InvalidNodeID(uint256 providedId, string reason);
    error NodeManagement__InvalidNumberOfPacks(uint256 numberOfPacks, string reason);
    error NodeManagement__InsufficientNativeToken(uint256 totalCost,uint256 playerBalance, string reason);

    // ==========================================================================================
    // ==================== NODE MANAGEMENT SYSTEM INTERNAL HELPER FUNCTIONS ====================
    // ==========================================================================================

    /**
     * @notice Distribute rewards to all players based on their hashpower
     * @dev Called before any state-changing operations to ensure up-to-date rewards
     * 
     * Algorithm:
     * 1. Calculate time elapsed since last distribution
     * 2. Determine if rate change occurred during this period
     * 3. Calculate rewards for each time segment (before/after halving)
     * 4. Distribute proportionally to each player based on hashpower
     * 
     * Gas Optimization:
     * - Skips if no time elapsed or no hashpower
     * - Only iterates players with active hashpower
     */
    function _distributeRewards() internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        // Skip if no hashpower or same timestamp
        if (s.totalNetworkHashPower == 0 || s.lastDistributionTime == block.timestamp) {
            return;
        }

        uint256 timeElapsed = block.timestamp - s.lastDistributionTime;
        uint256 timeBeforeReduction = 0;
        uint256 timeAfterReduction = 0;
        uint256 startTimeForPeriod = s.lastDistributionTime;

        // Determine if the rate changed during this period
        if (startTimeForPeriod < s.startTime + LibAppStorage.DURATION_BEFORE_HALVING) {
            // Case 1: Rate changes DURING this period
            if (block.timestamp > s.startTime + LibAppStorage.DURATION_BEFORE_HALVING) {
                timeBeforeReduction = (s.startTime + LibAppStorage.DURATION_BEFORE_HALVING) - startTimeForPeriod;
                timeAfterReduction = timeElapsed - timeBeforeReduction;
            }
            // Case 2: Entire period is before rate reduction
            else {
                timeBeforeReduction = timeElapsed;
            }
        }
        // Case 3: Entire period is after rate reduction
        else {
            timeAfterReduction = timeElapsed;
        }

        // Calculate rewards for each segment
        uint256 rewardsBeforeReduction = timeBeforeReduction * LibAppStorage.INITIAL_REWARD_RATE;
        uint256 rewardsAfterReduction = timeAfterReduction * LibAppStorage.REWARD_RATE_AFTER_HALVING;
        uint256 totalRewards = rewardsBeforeReduction + rewardsAfterReduction;
        uint256 totalInGameTokenAvailabeForMining = s.totalInGameTokenBalance - s.guildsInGameTokenRewardPool;

        if (totalRewards == 0) {
            return; // No rewards to distribute
        }else if(totalRewards + s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed > totalInGameTokenAvailabeForMining){
            totalRewards = totalInGameTokenAvailabeForMining - s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed;
            s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed = totalInGameTokenAvailabeForMining;
        }

        if(s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed < totalInGameTokenAvailabeForMining){
            // Distribute proportionally to each player
            for (uint256 i = 0; i < s.totalPlayersList.length; i++) {
                address player = s.totalPlayersList[i];
                uint256 hashPower =  _getPlayerTotalHashRate(player); //s_PlayerToNodePads[player].totalNodePadHashPower;
                
                if (hashPower == 0) continue; // Skip players with no active nodes

                // Calculate player's share: (playerHashpower / totalHashpower) * totalRewards
                uint256 playerRewards = (hashPower * totalRewards) / s.totalNetworkHashPower;
                s.PlayerToNodePads[player].totalInGameTokenRewardsEarned += playerRewards;
            }

            // Update last distribution time
            s.lastDistributionTime = block.timestamp;
            
            // Update global statistics
            
            s.gameGlobalAnalytics.totalInGameTokenRewardsDistributed += totalRewards;
        }else{
            for (uint256 i = 0; i < s.totalPlayersList.length; i++) {
                address player = s.totalPlayersList[i];
                uint256 hashPower = _getPlayerTotalHashRate(player);
                
                if (hashPower == 0) continue; // Skip players with no active nodes

                // Calculate player's share: (playerHashpower / totalHashpower) * totalRewards
                uint256 playerRewards = (hashPower * totalRewards) / s.totalNetworkHashPower;
                s.PlayerToNodePads[player].totalInGameTokenRewardsEarned += playerRewards;
            }

            // Update last distribution time
            s.lastDistributionTime = block.timestamp;
            s.gameStatus = LibAppStorage.GameStatus.PHASE_1_ENDED;
        }

    }

    function _getPlayerTotalHashRate(address player) view internal returns(uint256 totalHashRate) { 
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[player];

        for(uint256 i= 0; i< playerNodePad.nodefolio.length; i++){
            uint256 nodeKey = playerNodePad.nodefolio[i];
            LibAppStorage.Node memory node = s.IdToNodes[nodeKey];
            if(node.isActive){
                totalHashRate += node.hashPower;
            }
        }
    }

    /**
     * @notice Internal function to rip a pack and determine node rarity
     * @dev Uses pseudo-random number generation based on block data
     * @param nonce Additional entropy for randomness
     * @return Node The node that was revealed from the pack
     */
    function _ripPack(uint256 nonce) internal view returns(LibAppStorage.Node memory) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        // Generate random number between 0-9999 (for 0.01% precision)
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            nonce,
            s.PlayerToNodePads[msg.sender].nodefolio.length
        ))) % 10000;
        
        // Tier distribution (cumulative percentages in basis points):
        // D_RANK: 0-4999 (50.00%)
        // C_RANK: 5000-7499 (25.00%)
        // B_RANK: 7500-8999 (15.00%)
        // A_RANK : 9000-9899 (9.00%)
        // S_RANK: 9900-9999 (1.00%)
        
        uint256 NodeId;
        
        if (randomNumber < 5000) {
            // 50% - D_RANK (id: 0)
            NodeId = 0;
        } else if (randomNumber < 7500) {
            // 25% - C_RANK (id: 1)
            NodeId = 1;
        } else if (randomNumber < 9000) {
            // 15% - B_RANK (id: 2)
            NodeId = 2;
        } else if (randomNumber < 9900) {
            // 9% - A_RANK (id: 3)
            NodeId = 3;
        } else {
            // 1% - S_RANK (id: 4)
            NodeId = 4;
        }
        
        return _getNode(uint8(NodeId));
    } 
    function _nodeClassToID(LibAppStorage.NodeClass _nodeClass) internal pure returns (uint256 nodeId){
        if(_nodeClass == LibAppStorage.NodeClass.D_RANK) return 0;
        if(_nodeClass == LibAppStorage.NodeClass.C_RANK) return 1;
        if(_nodeClass == LibAppStorage.NodeClass.B_RANK) return 2;
        if(_nodeClass == LibAppStorage.NodeClass.A_RANK) return 3;
        if(_nodeClass == LibAppStorage.NodeClass.S_RANK) return 4;
        if(_nodeClass == LibAppStorage.NodeClass.SS_RANK) return 5;
        if(_nodeClass == LibAppStorage.NodeClass.SSS_RANK) return 6;
    }
    function _getNode(uint8 id) public pure returns(LibAppStorage.Node memory){
        if(id == 0) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.D_RANK, hashPower:4, energy:2, isActive:false});
        if(id == 1) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.C_RANK, hashPower:12, energy:4, isActive:false});
        if(id == 2) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.B_RANK, hashPower:36, energy:8, isActive:false});
        if(id == 3) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.A_RANK, hashPower:108, energy:64, isActive:false});
        if(id == 4) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.S_RANK, hashPower:324, energy:128, isActive:false});
        if(id == 5) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.SS_RANK, hashPower:972, energy:384, isActive:false});
        if(id == 6) return LibAppStorage.Node({nodeOwner: address(0), nodeClass:LibAppStorage.NodeClass.SSS_RANK, hashPower:2916, energy:512, isActive:false});

        revert NodePad__InvalidNodeID(id,"Id must be between 0-6");
    }
    /**
     * @notice Internal helper to remove a node from player's inventory
     * @dev Uses swap-and-pop pattern for gas efficiency
     * @param _nodeKey The ID of the node to remove
     */
    function _removeNodeFromInventory(uint256 _nodeKey) internal returns(bool hasBeenRemoved){
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];
        
        for(uint256 i = 0; i < playerNodePad.nodefolio.length; i++){
            if(playerNodePad.nodefolio[i] == _nodeKey){
                // Move last element to this position and pop
                playerNodePad.nodefolio[i] = playerNodePad.nodefolio[playerNodePad.nodefolio.length - 1];
                playerNodePad.nodefolio.pop();
                hasBeenRemoved = true;
                break;
            }
        }
    }
}