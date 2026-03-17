//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Libraries/LibReferralSystem.sol";
import "../Libraries/LibAppStorage.sol";
import "../Libraries/LibNodeManagementSystem.sol";
import "./Modifiers.sol";

contract ReferralSystemFacet is Modifiers{

    // =============================================================================
    // ================================= ERRORS ====================================
    // =============================================================================

    error ReferralSystem__NoEarnings(uint256 amountAvailable, string reason);
    error ReferralSystem__InvalidAddress(address _addressConcerned, string reason);
    error ReferralSystem__PaymentFailed(uint256 senderClaimableRefEarnings, uint256 balanceContract, string reason);
    error Guild__NotInitialReferrer();
    error Guild__GuildAlreadyCreated();
    error Guild__GuildNameTooLong();
    

    // =============================================================================
    // ================================= EVENTS ====================================
    // =============================================================================

    event GuildCreated(uint256 indexed GuildId, address indexed leader, string GuildName, uint256 memberCount);
    event ReferralRewardClaimed(address sender, uint256 claimable);
    event WhitelistUpdated(address indexed account, bool whitelisted);

    // =============================================================================
    // ==================== REFERRAL SYSTEM FUNCTIONS ==============================
    // =============================================================================

    /**
     * @notice Allows players to claim their accumulated referral rewards
     * @dev Only players who have joined can claim. Transfers payment tokens to claimer.
     */
    function claimReferralRewards() external hasPlayerJoined {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.ReferralData storage referral = s.referrals[msg.sender];
        
        // Calculate claimable amount
        uint256 claimable = referral.totalReferralEarnings - referral.claimedReferralEarnings;
        if(claimable <= 0){
            revert ReferralSystem__NoEarnings(claimable, "Not enough Earning To Claim");
        }

        // Update claimed amount
        referral.claimedReferralEarnings += claimable;
        
        // Transfer payment tokens to claimer
        //s_paymentToken.safeTransfer(msg.sender, claimable);
        (bool success,) = payable(msg.sender).call{value: claimable}("");
        if(!success){
            revert ReferralSystem__PaymentFailed(claimable, address(this).balance, "Payment failed");
        }

        emit ReferralRewardClaimed(msg.sender, claimable);
    }

    // =============================================================================
    // ==================== Guild CREATION ==========================================
    // =============================================================================
    
    /**
     * @notice Create a Guild (only for initial 200 referrers)
     * @param _guildName Name for the Guild (max 32 chars)
     */
    function createGuild(string calldata _guildName) external hasPlayerJoined{
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        // Get referral data from main contract
        (,,bool isGenesisPlayer,,,) = getPlayerReferralStats(msg.sender);
        
        // Must be initial referrer
        if (!isGenesisPlayer) {
            revert Guild__NotInitialReferrer();
        }
        
        // Can only create one Guild
        if (s.playerToGuildId[msg.sender] != 0) {
            revert Guild__GuildAlreadyCreated();
        }
        
        // Validate name length
        if (bytes(_guildName).length > LibAppStorage.MAX_Guild_NAME_LENGTH) {
            revert Guild__GuildNameTooLong();
        }
        
        uint256 guildId = s.nextGuildId++;
        
        // Calculate Guild stats (leader + all referees in tree)
        uint256 totalHashpower = LibNodeManagementSystem._getPlayerTotalHashRate(msg.sender);
        uint256 memberCount = 1;
        
        // Add entire referral tree
        (uint256 treeHashpower, uint256 treeMembers) = _addReferralTreeToGuild(msg.sender, guildId);
        totalHashpower += treeHashpower;
        memberCount += treeMembers;
        
        // Create Guild
        s.guilds[guildId] = LibAppStorage.Guild({
            name: _guildName,
            leader: msg.sender,
            totalHashpower: totalHashpower,
            memberCount: memberCount,
            exists: true
        });
        
        s.playerToGuildId[msg.sender] = guildId;
        s.gameGlobalAnalytics.totalGuildsCreated++;
        
        emit GuildCreated(guildId, msg.sender, _guildName, memberCount);
    }
    
    
    // =============================================================================
    // ==================== INTERNAL HELPERS =======================================
    // =============================================================================
    
    function _addReferralTreeToGuild(address referrer, uint256 guildId) 
        internal 
        returns (uint256 totalHashpower, uint256 totalMembers) 
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        (address[] memory directReferees,) = LibReferralSystem.getReferees(referrer);
        
        for (uint256 i = 0; i < directReferees.length; i++) {
            address referee = directReferees[i];
            uint256 totalHashpowerReferree = LibNodeManagementSystem._getPlayerTotalHashRate(msg.sender);
            
            // Add this referee to Guild
            s.playerToGuildId[referee] = guildId;
            totalHashpower += totalHashpowerReferree;
            totalMembers++;
            
            // Recursively add their referees
            (uint256 subTreeHashpower, uint256 subTreeMembers) = _addReferralTreeToGuild(referee, guildId);
            totalHashpower += subTreeHashpower;
            totalMembers += subTreeMembers;
        }
        
        return (totalHashpower, totalMembers);
    }

    //================================================================================
    //=================================== GETTERS ====================================
    //================================================================================
    function getPlayerReferralStats(address _player) public view returns (string memory, address, bool, uint256, uint256, uint256){
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        return (
            s.referrals[_player].referralCode,
            s.referrals[_player].referrer,
            s.referrals[_player].isGenesisPlayer,
            s.referrals[_player].totalReferralEarnings,
            s.referrals[_player].totalReferralEarnings - s.referrals[_player].claimedReferralEarnings, // Unclaimed Referral Rewards
            s.referrals[_player].directReferees
            //s.referrals[_player].totalReferees
        );
    }


    /**
     * @notice Check if user is in whitelist
     * @param user - User address
     */
    function isWhitelistedForGenesis(address user) external view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        return s.isWhitelisted[user];
    }

    /**
     * @notice Add or Remove addresses from whitelist
     * @param addrs List of addresses
     * @param status True to whitelist, false to remove from whitelist
     */
    function setWhitelist(address[] calldata addrs, bool status) external //onlyOwner 
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        uint256 len = addrs.length;
        for (uint256 i = 0; i < len; i++) {  // Safe increment
            address a = addrs[i];
            if (a == address(0)) revert ReferralSystem__InvalidAddress(a, "Invalide address to whitelist");
            s.isWhitelisted[a] = status;
            emit WhitelistUpdated(a, status);
        }
    }

    // =============================================================================
    // ==================== VIEW FUNCTIONS =========================================
    // =============================================================================
    
    function getGuild(uint256 _guildId) external view returns (
        string memory name,
        address leader,
        uint256 totalHashpower,
        uint256 memberCount,
        bool exists
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        LibAppStorage.Guild memory guild = s.guilds[_guildId];
        return (guild.name, guild.leader, guild.totalHashpower, guild.memberCount, guild.exists);
    }
    
    function getPlayerGuildId(address player) external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        return s.playerToGuildId[player];
    }
    
    function getTopGuilds() external view returns (
        uint256[10] memory _guildIds,
        uint256[10] memory hashpowers,
        string[10] memory names
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        for (uint256 guildId = 1; guildId < s.nextGuildId; guildId++) {
            if (!s.guilds[guildId].exists) continue;
            
            uint256 hp = s.guilds[guildId].totalHashpower;
            
            for (uint256 i = 0; i < 10; i++) {
                if (hp > hashpowers[i]) {
                    for (uint256 j = 9; j > i; j--) {
                        _guildIds[j] = _guildIds[j-1];
                        hashpowers[j] = hashpowers[j-1];
                        names[j] = names[j-1];
                    }
                    _guildIds[i] = guildId;
                    hashpowers[i] = hp;
                    names[i] = s.guilds[guildId].name;
                    break;
                }
            }
        }
        
        return (_guildIds, hashpowers, names);
    }
}