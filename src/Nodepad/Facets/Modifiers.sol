//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Libraries/LibAppStorage.sol";

contract Modifiers{
    // ==============================================================================
    // ==================== MODIFIERS ===============================================
    // ==============================================================================

    /**
     * @notice Ensures Phase 1 is currently active
     * @dev Reverts if game is not in PHASE_1 status
     * Requirements:
     * - Game must be in PHASE_1 (not Phase 2, not paused)
     */
    modifier isPhase1Ongoing(){
        if(LibAppStorage.getAppStorage().gameStatus != LibAppStorage.GameStatus.PHASE_1){
            revert NodePad__PHASE_1_NOT_OPEN(LibAppStorage.getAppStorage().gameStatus, "Phase 1 ended or on pause");
        }
        _;
    }

    /**
     * @notice Ensures the caller has joined the game
     * @dev Reverts if msg.sender hasn't called joinGame() yet
     * Requirements:
     * - Caller must have an initialized NodePad
     */
    modifier hasPlayerJoined(){
        if (!LibAppStorage.getAppStorage().hasJoined[msg.sender]) {
            revert NodePad__NOT_JOINED(msg.sender, "Player has not joined the game");
        }
        _;
    }

    /**
     * @notice Ensures a node is NOT currently active in the player's NodePad
     * @dev Used before recycling or other operations that require inactive nodes
     * @param _nodeKey The ID of the nodeInstance to check
     * Requirements:
     * - Node must not be in active state
     */
    modifier isNodeActiveInPlayerNodePad(uint256  _nodeKey) {
        LibAppStorage.NodePad storage playerNodePad = LibAppStorage.getAppStorage().PlayerToNodePads[msg.sender];
        
        for (uint256 i = 0; i < playerNodePad.nodefolio.length; i++) {
            bool isNodeActive = LibAppStorage.getAppStorage().IdToNodes[playerNodePad.nodefolio[i]].isActive;
            if (playerNodePad.nodefolio[i] == _nodeKey &&
                isNodeActive) {
                revert NodePad__NodeIsActive("This node is currently active, can't be recycled or Activated");
            }
        }
        _;
    }

    /**
     * @notice Verifies that the caller owns a specific node
     * @dev Iterates through player's NodeFolio to find the node
     * @param _nodeInstanceId The ID of the node to verify ownership
     * Requirements:
     * - _nodeInstanceId must exist in the player's NodeFolio array
     */
    modifier isNodeInPlayerInventory(uint256 _nodeInstanceId){
        LibAppStorage.NodePad storage playerNodePad = LibAppStorage.getAppStorage().PlayerToNodePads[msg.sender];
        bool ownsNode = false;
        for(uint256 i = 0; i < playerNodePad.nodefolio.length; i++){
            if(playerNodePad.nodefolio[i] == _nodeInstanceId){
                ownsNode = true;
                break;
            }
        }
        if(!ownsNode){
            revert NodePad__NodeNotFoundInPlayerInventory(_nodeInstanceId,"Node not found in player's inventory");
        }
        _;
    }

    // ==============================================================================
    // ==================== Errors ==================================================
    // ==============================================================================
    error NodePad__PHASE_1_NOT_OPEN(LibAppStorage.GameStatus currentGameStatus, string reason);
    error NodePad__NOT_JOINED(address player, string reason);
    error NodePad__NodeIsActive(string reason);
    error NodePad__NodeIsInactive(string reason);
    error NodePad__NodeNotFoundInPlayerInventory(uint256 _nodeId, string reason);
}