//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Libraries/LibNodeManagementSystem.sol";
import "../Libraries/LibReferralSystem.sol";
import "../Libraries/PriceConverter.sol";
import "../Libraries/LibAppStorage.sol";
import "./Modifiers.sol";

contract NodeManagementSystem is Modifiers{

    using PriceConverter for uint256;

    // =============================================================================
    // ============================== ERRORS =======================================
    // =============================================================================
    error NodeManagement__VPS_LevelSLotsCapReached(uint256 playerActiveNodesSlots, uint256 currentVPSLevelMaxSlots, string reason);
    error NodeManagement__NotEnoughEnergyCapacity(uint256 newNodenergyCost, uint256 currentVPSMaxEnergyCapacity, string reason);
    error NodeManagement__NodeIsNotActive(bool isNodeActive, string reason);
    error NodeManagement__CannotRecycle(string reason);
    error NodeManagement__AlreadyInPhase2(LibAppStorage.GameStatus _gameStatus, string reason);
    error NodeManagement__InsufficientPendingRewards(uint256 pending, uint256 _claimAmountEntered, uint256 minClaimAmount, string reason);
    error NodeManagement__InvalidPrice(uint256 price, string reason);

    // =============================================================================
    // ============================== EVENTS =======================================
    // =============================================================================
    event NewPackRipped(address buyer, LibAppStorage.NodeClass class);
    event NodeRecycledSuccess(address player, uint256 oldNodeId, bool hasBeenRemoved, LibAppStorage.NodeClass class);
    event NodeRecycledFail(address player, uint256 oldNodeId, bool hasBeenRemoved);
    event NodeActivated(address indexed player, uint256 NodeId);
    event NodeDeactivated(address indexed player, uint256 NodeId);
    event RewardsClaimed(address indexed player, uint256 amount);

    // ==============================================================================
    // ====================== NODE MANAGEMENT SYSTEM FUNCTIONS ======================
    // ==============================================================================

    /**
     * @notice Recycle an unused node for a 20% chance to upgrade to the next tier
     * @dev Node must be inactive and owned by the player. SSS_RANK cannot be recycled
     * @param _nodeKey The ID of the node to recycle
     * 
     * Example: Recycle D_RANK → 20% chance to get C_RANK, 80% chance node is destroyed
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must have joined
     * - Valid node ID
     * - Node must be inactive
     * - Player must own the node
     * - Cannot recycle SSS_RANK (max tier)
     */
    function recycleNode(uint256 _nodeKey) public isPhase1Ongoing hasPlayerJoined isNodeActiveInPlayerNodePad(_nodeKey) isNodeInPlayerInventory(_nodeKey){
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];
        
        // Get the Node being recycled
        LibAppStorage.Node memory currentNode =  s.IdToNodes[_nodeKey];
        
        // Can't recycle SSS_RANK (highest Tier)
        if(currentNode.nodeClass == LibAppStorage.NodeClass.SSS_RANK){
            revert NodeManagement__CannotRecycle("SSS_RANK Nodes can't be recycled ");
        }
        // Update global game stats
        s.gameGlobalAnalytics.totalNodesRecycled++;
        // Generate random number for 20% chance (1-5, where 1 = success)
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            _nodeKey
        ))) % 5;
        
        // Remove the old Node from player's inventory
        bool hasBeenRemoved = LibNodeManagementSystem._removeNodeFromInventory(_nodeKey);
        
        if(randomNumber == 0) {
            // Success! Upgrade to next Tier
            uint256 nextClassId = LibNodeManagementSystem._nodeClassToID(currentNode.nodeClass) + 1;

            LibAppStorage.Node memory node = LibNodeManagementSystem._getNode(uint8(nextClassId)); // Get the upgraded Node));
            node.nodeOwner = msg.sender;
            
            // Add upgraded Node to inventory
            s.IdToNodes[s.nodeCounter] = node;
            playerNodePad.nodefolio.push(s.nodeCounter);
            s.nodeCounter++;

            //Update global game stats
            s.gameGlobalAnalytics.totalSuccessfulRecycles++;
            
            emit NodeRecycledSuccess(msg.sender, _nodeKey, hasBeenRemoved, node.nodeClass);
        } else {
            // Failed - Node is destroyed
            emit NodeRecycledFail(msg.sender, _nodeKey, hasBeenRemoved );
        }
    }


    /**
     * @notice Activate a node to start earning rewards
     * @dev Node must have sufficient energy capacity and available slots
     * @param _nodeKey The ID of the node to activate
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must have joined
     * - Valid node ID
     * - Node must be inactive
     * - Player must own the node
     * - Must have available node slots
     * - Must have sufficient energy capacity
     * 
     * Effects:
     * - Node becomes active
     * - Increases player's total hashpower
     * - Increases global network hashpower
     * - Consumes energy capacity
     * - Uses one node slot
     */
    function activateNode(uint256 _nodeKey) public isPhase1Ongoing hasPlayerJoined isNodeActiveInPlayerNodePad(_nodeKey) isNodeInPlayerInventory(_nodeKey){
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];
        (uint256 playerActiveNodesSlots, uint256 currentEnergyInUseByActivesNodes)  = _getActiveNodeStats(msg.sender);
        (uint256 currentVPSLevelMaxSlots,uint256 currentVPSMaxEnergyCapacity,,) = LibAppStorage.getVPSLevelStats(playerNodePad.VPSLevel);
        // for(uint256 i=0; i< playerNodePad.nodefolio.length; i++){
        //     LibAppStorage.Node memory nd = s.IdToNodes[playerNodePad.nodefolio[i]];
        //     if (nd.isActive) {
        //         playerActiveNodesSlots++;
        //         currentEnergyInUseByActivesNodes += nd.energy;
        //     }
        // }

        //Distribute InGameTokenRewards
        LibNodeManagementSystem._distributeRewards();

        if(playerActiveNodesSlots >= currentVPSLevelMaxSlots){
            revert NodeManagement__VPS_LevelSLotsCapReached(playerActiveNodesSlots, currentVPSLevelMaxSlots,"No empty slot");
        }
        // 3. Get Node stats
        LibAppStorage.Node memory node = s.IdToNodes[_nodeKey];
        
        // 4. Check energy capacity
        if(currentEnergyInUseByActivesNodes + node.energy > currentVPSMaxEnergyCapacity){
            revert NodeManagement__NotEnoughEnergyCapacity(node.energy, currentVPSMaxEnergyCapacity, "Not Enough enrgy capacity left for this new node");
        }
        // 5. Activate Node and update stats
        s.IdToNodes[_nodeKey].isActive = true;
        s.totalNetworkHashPower+= node.hashPower;
        LibReferralSystem.updateGuildHashpower(msg.sender, node.hashPower, true);
        
        emit NodeActivated(msg.sender, _nodeKey);
    }

    /**
     * @notice Deactivate a node to stop earning rewards and free up resources
     * @dev Reduces hashpower and frees energy capacity
     * @param _nodeKey The ID of the node to deactivate
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must have joined
     * - Valid node ID
     * - Player must own the node
     * - Node must be currently active
     * 
     * Effects:
     * - Node becomes inactive
     * - Decreases player's total hashpower
     * - Decreases global network hashpower
     * - Frees energy capacity
     * - Frees one node slot
     */
    function deactivateNode(uint256 _nodeKey) public isPhase1Ongoing hasPlayerJoined isNodeInPlayerInventory(_nodeKey){
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        //Distribute InGameTokenRewards
        LibNodeManagementSystem._distributeRewards();

        if(!s.IdToNodes[_nodeKey].isActive){
            revert NodeManagement__NodeIsNotActive(s.IdToNodes[_nodeKey].isActive, "You can only deactivate active nodes");
        }
        s.IdToNodes[_nodeKey].isActive = false;
        s.totalNetworkHashPower -= s.IdToNodes[_nodeKey].hashPower;
        LibReferralSystem.updateGuildHashpower(msg.sender, s.IdToNodes[_nodeKey].hashPower, false);
        
        emit NodeDeactivated(msg.sender, _nodeKey);
    }

    function _getActiveNodeStats(address player) internal view returns (uint256 activeCount, uint256 energyUsed) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[player];
        
        for(uint256 i = 0; i < playerNodePad.nodefolio.length; i++){
            LibAppStorage.Node storage nd = s.IdToNodes[playerNodePad.nodefolio[i]];
            if (nd.isActive) {
                activeCount++;
                energyUsed += nd.energy;
            }
        }
    }

    // ==============================================================================
    // ==================== REWARD DISTRIBUTION SYSTEM FUNCTIONS ====================
    // ==============================================================================

    /**
     * @notice Claim accumulated in-game token rewards
     * @dev Burns in-game tokens and mints vault shares for Phase 2 redemption
     * 
     * Requirements:
     * - Phase 1 must be ongoing
     * - Player must have joined
     * - Pending rewards must be >= MIN_CLAIM_AMOUNT (0.0001 tokens)
     * 
     * Process:
     * 1. Distributes latest rewards
     * 2. Checks minimum claim threshold
     * 3. Burns in-game tokens
     * 4. Mints equivalent shares in reward vault
     * 5. Updates player statistics
     * 
     * @custom:security Burns tokens instead of transferring to prevent double-claiming
     */
    function claimRewards(bool _toBurn, uint256 _claimAmount) external hasPlayerJoined {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(s.gameStatus == LibAppStorage.GameStatus.PHASE_2){
            revert NodeManagement__AlreadyInPhase2(s.gameStatus, "Game already ");
        }

        LibAppStorage.NodePad storage playerNodePad = s.PlayerToNodePads[msg.sender];

        // Calculate latest rewards
        LibNodeManagementSystem._distributeRewards();
        
        uint256 pending = playerNodePad.totalInGameTokenRewardsEarned - playerNodePad.totalInGameTokenClaimedOrBurned;
        if (pending <= LibAppStorage.MIN_CLAIM_AMOUNT || pending < _claimAmount){
            revert NodeManagement__InsufficientPendingRewards(pending, _claimAmount,LibAppStorage.MIN_CLAIM_AMOUNT, "Insufficient pending rewards");
        }



        // Burn in-game tokens and mint vault shares
        if(_toBurn){
            // Reset pending rewards
            playerNodePad.totalInGameTokenClaimedOrBurned += pending;
            s.rewardVault.mintShares(msg.sender, pending);

             //Update global Analytics
             s.gameGlobalAnalytics.totalInGameTokenClaimed += pending;
            emit RewardsClaimed(msg.sender, pending);
        }else{
            playerNodePad.inGameTokenBalance += _claimAmount;
            playerNodePad.totalInGameTokenClaimedOrBurned += _claimAmount;
             //Update global Analytics
            s.gameGlobalAnalytics.totalInGameTokenClaimed += _claimAmount;
            emit RewardsClaimed(msg.sender, _claimAmount);
        }
       

    }

    // ==============================================================================================
    // ==================== REWARD DISTRIBUTION SYSTEM INTERNAL HELPER FUNCTIONS ====================
    // ==============================================================================================


    /**
     * @notice Get the current reward emission rate per second
     * @dev Rate halves after DURATION_BEFORE_HALVING (7 days)
     * @return uint256 Current emission rate in tokens per second (with 18 decimals)
     */
    function _getCurrentRewardRate() internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        return (block.timestamp - s.startTime < LibAppStorage.DURATION_BEFORE_HALVING)
            ? LibAppStorage.INITIAL_REWARD_RATE      // 100 tokens/second for first 7 days
            : LibAppStorage.REWARD_RATE_AFTER_HALVING; // 50 tokens/second after
    }

    /**
     * @notice Update node pack price
     * @param _newPrice New price (with decimals)
     */
    function setNodePackPrice(uint256 _newPrice, bool forInGameToken) external //onlyOwner 
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        if(_newPrice <= 0){
            revert NodeManagement__InvalidPrice(_newPrice, "Price must be greater than zero");
        }
        if(forInGameToken){
            s.PriceNodePackInGameToken = _newPrice;
        }else{
            s.PriceNodePackUSD = _newPrice;
        }
    }



}