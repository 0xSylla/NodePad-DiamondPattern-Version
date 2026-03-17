//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LibAppStorage.sol";

library LibReferralSystem {
    // ===================================================================================
    // ==================================== ERRORS =======================================
    // ===================================================================================

    error ReferralSystem__AddressNotWhitelistedForGenesisPlayer(address sender, string reason);
    error ReferralSystem__GenesisPlayerCapReached(uint256 currentReferralCount, string reason);
    error ReferralSystem__NoReferrerForThisCode(string refCode, string reason);
    error ReferralSystem__CannotReferYourself(address sender, string reason);
    error ReferralSystem__FailedToGenerateUniqueCode(string refCode, string reason);

    // ===================================================================================
    // ==================================== ERRORS =======================================
    // ===================================================================================

    event PlayerAddedToGuild(address referree, uint256 guildID);
    event NewReferee(address indexed referrer, address indexed referee, uint256 refereeCount);

    // ===================================================================================
    // ==================== REFERRAL SYSTEM INTERNAL HELPER FUNCTIONS ====================
    // ===================================================================================

    /**
     * @notice Generates a unique 8-character alphanumeric referral code for a player
     * @dev Uses block.timestamp, block.prevrandao, and player address for randomness
     * @param _player Address of the player to generate code for
     * @return code Generated referral code (8 characters, 0-9 and A-Z)
     */
    function _generateReferralCode(address _player) internal view returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(
            _player,
            block.timestamp,
            block.prevrandao
        ));
        
        string memory code = "";
        
        // Generate 8 alphanumeric characters
        for (uint256 i = 0; i < 8; i++) {
            uint256 rand = uint256(hash) % 36; // 0-35 (10 digits + 26 letters)
            
            if (rand < 10) {
                // 0-9: ASCII 48-57
                code = string(abi.encodePacked(code, bytes1(uint8(48 + rand))));
            } else {
                // A-Z: ASCII 65-90
                code = string(abi.encodePacked(code, bytes1(uint8(65 + rand - 10))));
            }
            
            // Rotate hash for next character
            hash = keccak256(abi.encodePacked(hash, i));
        }
        
        return code;
    }
     /**
     * @notice Processes referral logic when a new player joins
     * @dev Validates referral code, creates new code for player, updates referrer stats
     * @param _referralCode The referral code used by the joining player
     * @return _referrer Address of the referrer (address(0) if using initial code)
     * @return _isInitialReferral True if player used the initial referral code
     * @return _newReferralCode The newly generated code for the joining player
     */
    function _processReferral(string memory _referralCode) 
        internal 
        returns (
            address _referrer, 
            bool _isInitialReferral, 
            string memory _newReferralCode
        ) 
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        // Check if using the initial promotional code (first 200 players)
        if (keccak256(bytes(_referralCode)) == keccak256(bytes(s.initialReferralCode))) {
            if(!s.isWhitelisted[msg.sender]){
                revert  ReferralSystem__AddressNotWhitelistedForGenesisPlayer(msg.sender,"This address is not whitelisted");
            }
            if(s.initialReferralCount >= LibAppStorage.INITIAL_REFERRAL_CAP){
                revert ReferralSystem__GenesisPlayerCapReached(s.initialReferralCount, "Genesis player Cap Reached");
            }
            s.initialReferralCount = s.initialReferralCount + 1;  // Explicit (safer than ++)
            _isInitialReferral = true;
            _referrer = address(0); // No specific referrer for initial code
        } 
        // Using a player's referral code
        else {
            _referrer = s.referralCodesToAddress[_referralCode];
            if(_referrer == address(0)){
                revert ReferralSystem__NoReferrerForThisCode(_referralCode,"No referrer associated with this code");
            }
            if(_referrer == msg.sender){
                revert ReferralSystem__CannotReferYourself(msg.sender, "you cannot refer yourself");
            }
            _isInitialReferral = false;
        }

        // Generate unique referral code for the new player
        _newReferralCode = _generateReferralCode(msg.sender);
        
        // Ensure code is unique (very unlikely collision, but safety check)
        uint256 attempts = 0;
        while (s.referralCodesToAddress[_newReferralCode] != address(0) && attempts < 10) {
            _newReferralCode = _generateReferralCode(address(uint160(uint256(keccak256(abi.encodePacked(msg.sender, attempts))))));
            attempts++;
        }
        if(s.referralCodesToAddress[_newReferralCode] != address(0)){
            revert ReferralSystem__FailedToGenerateUniqueCode(_newReferralCode, "New code generated is not unique");
        }

        // Initialize referral data for new player
        s.referrals[msg.sender] = LibAppStorage.ReferralData({
            referrer: _referrer,
            referralCode: _newReferralCode,
            isGenesisPlayer: _isInitialReferral,
            totalReferralEarnings: 0,
            claimedReferralEarnings: 0,
            directReferees: 0,
            totalReferees: 0
        });
        
        // Register the code
        s.referralCodesToAddress[_newReferralCode] = msg.sender;

        // Update referrer's statistics (if not using initial code)
        if (_referrer != address(0)) {
            s.referrals[_referrer].directReferees++;
            s.referrals[_referrer].totalReferees++;
            s.referrerToReferees[_referrer].push(msg.sender);
            uint256 referrerGuildId = s.playerToGuildId[_referrer];
            if (referrerGuildId != 0) {
                addPlayerToReferrerGuild(msg.sender, referrerGuildId);
            }
            
            emit NewReferee(_referrer, msg.sender, s.referrals[_referrer].totalReferees);
        }

        return (_referrer, _isInitialReferral, _newReferralCode);
    }
    /**
     * @notice Adds referral reward to the referrer when referee makes a purchase
     * @dev Called internally when player buys packs or makes other purchases
     * @param _amount The purchase amount to calculate referral reward from
     */
    function _addReferralReward(uint256 _amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        address referrer = s.referrals[msg.sender].referrer;
        
        // Only add reward if player has a referrer
        if (referrer != address(0)) {
            // Determine reward percentage based on referrer type
            uint256 rewardPercent = s.referrals[referrer].isGenesisPlayer
                ? LibAppStorage.INITIAL_REFERRAL_REWARD  // 40% for initial referrers
                : LibAppStorage.NORMAL_REFERRAL_REWARD;   // 10% for normal referrers
            
            // Calculate reward amount
            uint256 referralReward = (_amount * rewardPercent) / 100;
            
            // Add to referrer's unclaimed earnings
            s.referrals[referrer].totalReferralEarnings += referralReward;
        }
    } 

    function getReferees(address _referrer)public view returns(address[] memory directRefs, address[] memory indirectRefs) {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        address[] memory directReferees = s.referrerToReferees[_referrer];
        
        uint256 totalSize = 0;
        for (uint256 i = 0; i < directReferees.length; i++) {
            totalSize += s.referrerToReferees[directReferees[i]].length;
        }
        
        address[] memory totalIndirectReferrees = new address[](totalSize);
        uint256 index = 0;
        
        for (uint256 i = 0; i < directReferees.length; i++) {
            address referee = directReferees[i];
            address[] memory indirectReferees = s.referrerToReferees[referee];
            for (uint256 j = 0; j < indirectReferees.length; j++) {
                totalIndirectReferrees[index] = indirectReferees[j];
                index++;
            }
        }
        
        return (directReferees, totalIndirectReferrees);
    }

    /**
     * @notice Update Guild hashpower when nodes are activated/deactivated
     * @param player Player whose hashpower changed
     * @param hashpowerDelta Change in hashpower (can be positive or negative)
     * @param isIncrease True if increasing, false if decreasing
     */
    function updateGuildHashpower(address player, uint256 hashpowerDelta, bool isIncrease) public {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        uint256 GuildId = s.playerToGuildId[player];
        if (GuildId != 0) {
            if (isIncrease) {
                s.guilds[GuildId].totalHashpower += hashpowerDelta;
            } else {
                s.guilds[GuildId].totalHashpower -= hashpowerDelta;
            }
        }
    }

    function addPlayerToReferrerGuild(address referree, uint256 guildID) public {
        LibAppStorage.AppStorage storage s = LibAppStorage.getAppStorage();
        s.playerToGuildId[referree] = guildID;
        s.guilds[guildID].memberCount++;
        //(,, uint256 totalHashpowerReferree,,) = gameContract.getPlayernNodePadVPSGeneralData(referree);
        s.guilds[guildID].totalHashpower += 4;
        emit PlayerAddedToGuild(referree, guildID);

    }
}