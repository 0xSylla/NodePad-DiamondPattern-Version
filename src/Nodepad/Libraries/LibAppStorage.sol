//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import {GameToken,RewardToken} from "src/RewardVault/gameToken.sol";
import{RewardVault} from "src/RewardVault/rewardVault.sol";
//import "./lib/PriceConverter.sol";
//import {VPSLib} from "./lib/VPSLib.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


library LibAppStorage {
    //================================================================================
    //================================= ENUMS ========================================
    //================================================================================

    enum GameStatus{ 
        PHASE_1,
        PHASE_2,
        PAUSED_DURING_PHASE_1,
        PAUSED_DURING_PHASE_2,
        PHASE_1_ENDED
    }

    enum NodeClass {
        D_RANK,
        C_RANK,
        B_RANK,
        A_RANK,
        S_RANK,
        SS_RANK,
        SSS_RANK
    }

    //===============================================================================
    //============================= STRUCTS =========================================
    //===============================================================================
    struct NodePad {
        uint256 VPSLevel;
        uint256[] nodefolio;
        uint256 totalInGameTokenRewardsEarned;// You can derive pending from this 2
        uint256 totalInGameTokenClaimedOrBurned;
        uint256 inGameTokenBalance;
        uint256 lastVPSUpgradeTime;
        uint256 currentVPSLevelCooldownTime;
    }

    struct Node {
        address nodeOwner;
        NodeClass nodeClass;
        uint256 hashPower;
        uint256 energy;
        bool isActive;
    }

    struct ReferralData {
        address referrer;          // Who referred this player
        string referralCode;       // Player's unique referral code
        bool isGenesisPlayer;
        uint256 totalReferralEarnings;     // Total unclaimed referral rewards
        uint256 claimedReferralEarnings;   // Total claimed referral rewards
        uint256 directReferees;         // Count of direct referees
        uint256 totalReferees;         // Count of direct referees
    }

    struct Guild {
        string name;
        address leader;
        uint256 totalHashpower;
        uint256 memberCount;
        bool exists;
    }

    struct GameAnalytics{
        uint256 totalPacksBought;
        uint256 totalPacksBoughtInGameToken;                      // Total packs purchased
        uint256 totalNodesRecycled;                    // Total nodes recycled (attempts)
        uint256 totalSuccessfulRecycles;              // Successful recycle upgrades
        uint256 totalInGameTokenRewardsDistributed;   // Total in-game tokens distributed  
        uint256[] playersPerVPSLevel;               // Player distribution by VPS level
        uint256 phase1EndTotalHashpower;           // Hashpower snapshot at Phase 1 end
        uint256 phase1Duration;                   // Actual Phase 1 duration
        mapping(uint256 level => uint256 count) totalUpgradesSold;
        uint256 totalInGameTokenClaimed;
        uint256 totalReferralRewardsDistributed;
        uint256 totalGuildsCreated;
    }

    // ==============================================================================
    // ==================== STATE VARIABLES =========================================
    // ==============================================================================

    //===================== REFERRAL SYSTEM CONSTANTS ===============================
    uint256 internal constant INITIAL_REFERRAL_CAP = 200;    // Max initial referrals
    uint256 internal constant INITIAL_REFERRAL_REWARD = 40;  // 40% for first 200
    uint256 internal constant NORMAL_REFERRAL_REWARD = 10;   // 10% for others
    
    //===================== INGAME TOKEN EMISSION CONSTANTS =========================
    uint256 public constant INITIAL_REWARD_RATE = 100 * 10**18;        // Initial emission rate per second
    uint256 public constant MIN_CLAIM_AMOUNT = 0.0001 * 10**18;        // Minimum claim threshold
    uint256 public constant DURATION_BEFORE_HALVING = 7 days;          // Duration before emission halves
    uint256 public constant REWARD_RATE_AFTER_HALVING = 50 * 10**18;   // Reduced emission rate

    //========================== GUILD BONUS CONSTANTS ==============================
    uint256 public constant LEADER_BONUS_SHARE = 10;
    uint256 public constant MEMBER_BONUS_SHARE = 80;
    uint256 public constant MAX_Guild_NAME_LENGTH = 32;

    //===================== APP STORAGE =============================================
    struct AppStorage {
        //======================= TOKEN STATE VARIABLES =================================
        uint256 totalInGameTokenBalance;
        uint256 guildsInGameTokenRewardPool;
        bool isGuildBonusesDistributed;

        //======================== PLAYER STATE VARIABLES ===============================
        address[] totalPlayersList;                               // List of all players
        mapping(address => bool) hasJoined;              // Track if address has joined
        mapping(address => NodePad) PlayerToNodePads;    // Player address to their NodePad
        uint256 nodeCounter;//To initialize in constructor
        mapping(uint256 => Node) IdToNodes; // Contains all created nodes with akey for the owner
        uint256 PriceNodePackUSD;
        uint256 PriceNodePackInGameToken;

        //==================== REFERRAL STATE VARIABLE ========================================
        string initialReferralCode;      //To initialize constructor Default code for first 200
        mapping(address => bool) isWhitelisted;
        uint256 initialReferralCount;                   // Track first 200 users
        mapping(address => ReferralData) referrals;     // Player => ReferralData
        mapping(string => address) referralCodesToAddress;       // Code => Player address
        mapping(address => address[]) referrerToReferees; // Player referees addresses

        //============================== GUILD STATE VARIABLE ============================

        mapping(address => uint256) playerToGuildId;
        mapping(uint256 => Guild) guilds;
        uint256 nextGuildId; //Neeed to be initialized to 1

        //======================= REWARD STATE VARIABLES =================================
        RewardVault rewardVault;                 // Phase 2 vault for reward distribution
        RewardToken rewardToken;

        // ==================== GAME STATE ==============================================

        GameStatus gameStatus;                   // Current game phase status
        uint256 startTime;                       // Game start timestamp
        uint256 lastDistributionTime;            // Last reward distribution timestamp
        uint256 totalNetworkHashPower;           // Sum of all active hashpower
        uint256 phase2StartTime;                 // Phase 2 start timestamp
        GameAnalytics gameGlobalAnalytics;
    }

    //===============================================================================
    //============================== Getters ========================================
    //===============================================================================

    bytes32 internal constant APP_STORAGE_SLOT = keccak256("nodepad.diamond.storage");

    function getAppStorage() internal pure returns (AppStorage storage s) {
        bytes32 slot = APP_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    //Let you not only get Player current VPS level infos but also the next upgrade
    function getVPSLevelStats(uint256 level) internal pure returns (
        uint256 availableSlots,
        uint256 energyCapacity,
        uint256 price,
        uint256 cooldownPeriod
    ) {
        // Slots progression
        if (level == 1) return (2, 6, 0, 10 minutes);
        if (level == 2) return (4, 12, 20 * 10**18, 0.5 hours);
        if (level == 3) return (7, 20, 30 * 10**18, 1 hours);
        if (level == 4) return (10, 40, 40 * 10**18, 2 hours);
        if (level == 5) return (13, 70, 50 * 10**18, 3 hours);
        if (level == 6) return (16, 110, 60 * 10**18, 4 hours);
        if (level == 7) return (19, 230, 70 * 10**18, 5 hours);
        if (level == 8) return (22, 420, 80 * 10**18, 6 hours);
        if (level == 9) return (24, 800, 90 * 10**18, 7 hours);
        if (level == 10) return (25, 2000, 100 * 10**18, 8 hours);
        
        revert NodePad__InvalidVPSLevel(level,"VPS Level must be beween 1-10");
    }

    function getNode(uint8 id) public pure returns(Node memory){
        if(id == 0) return Node({nodeOwner: address(0), nodeClass:NodeClass.D_RANK, hashPower:4, energy:2, isActive:false});
        if(id == 1) return Node({nodeOwner: address(0), nodeClass:NodeClass.C_RANK, hashPower:12, energy:4, isActive:false});
        if(id == 2) return Node({nodeOwner: address(0), nodeClass:NodeClass.B_RANK, hashPower:36, energy:8, isActive:false});
        if(id == 3) return Node({nodeOwner: address(0), nodeClass:NodeClass.A_RANK, hashPower:108, energy:64, isActive:false});
        if(id == 4) return Node({nodeOwner: address(0), nodeClass:NodeClass.S_RANK, hashPower:324, energy:128, isActive:false});
        if(id == 5) return Node({nodeOwner: address(0), nodeClass:NodeClass.SS_RANK, hashPower:972, energy:384, isActive:false});
        if(id == 6) return Node({nodeOwner: address(0), nodeClass:NodeClass.SSS_RANK, hashPower:2916, energy:512, isActive:false});

        revert NodePad__InvalidNodeID(id,"Id must be between 0-6");
    }

    //===============================================================================
    //================================ERRORS=========================================
    //===============================================================================
    error NodePad__InvalidVPSLevel(uint256 providedLevel, string reason);
    error NodePad__InvalidNodeID(uint256 providedId, string reason);
}
