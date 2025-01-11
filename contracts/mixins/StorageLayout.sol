// SPDX-License-Identifier: GPL-3                                                          
pragma solidity 0.8.28;
pragma experimental ABIEncoderV2;

import '../libraries/Directives.sol';
import '../libraries/PoolSpecs.sol';
import '../libraries/PriceGrid.sol';
import '../libraries/KnockoutLiq.sol';

/* @title Storage layout base layer
 * 
 * @notice Only exists to enforce a single consistent storage layout. Not
 *    designed to be externally used. All storage in any CrocSwap contract
 *    is defined here. That allows easy use of delegatecall() to move code
 *    over the 24kb into proxy contracts.
 *
 * @dev Any contract or mixin with local defined storage variables *must*
 *    define those storage variables here and inherit this mixin. Failure
 *    to do this may lead to storage layout inconsistencies between proxy
 *    contracts. */
contract StorageLayout {

    // Re-entrant lock. Should always be reset to 0x0 after the end of every
    // top-level call. Any top-level call should fail on if this value is non-
    // zero.
    //
    // Inside a call this address is always set to the beneficial owner that
    // the call is being made on behalf of. Therefore any positions, tokens,
    // or liquidity can only be accessed if and only if they're owned by the
    // value lockHolder_ is currently set to.
    //
    // In the case of third party relayer or router calls, this value should
    // always be set to the *client* that the call is being made for, and never
    // the msg.sender caller that is acting on the client behalf's. (Of course
    // for security, third party calls made on a client's behalf must always
    // be authorized by the client either by pre-approval or signature.)
    address internal lockHolder_;

    // Indicates whether a given protocolCmd() call is operating in escalated
    // privileged mode. *Must* always be reset to false after every call.
    bool internal sudoMode_;

    bool internal msgValSpent_;

    // If set to false, then the embedded hot-path (swap()) is not enabled and
    // users must use the hot proxy for the hot-path. By default set to true.
    bool internal hotPathOpen_;
    
    bool internal inSafeMode_;

    function safeMode() public view returns (bool) {
        return inSafeMode_;
    }

    // The protocol take rate for relayer tips. Represented in 1/256 fractions
    uint8 internal relayerTakeRate_;

    // Slots for sidecar proxy contracts
    address[65536] internal proxyPaths_;
        
    // Address of the current dex protocol authority. Can be transferred
    address internal authority_;

    function authority() public view returns (address) {
        return authority_;
    }
    /**************************************************************/
    // LevelBook
    /**************************************************************/
    struct BookLevel {
        uint96 bidLots_;
        uint96 askLots_;
        uint64 feeOdometer_;
    }
    mapping(bytes32 => BookLevel) internal levels_;
    /**************************************************************/

    
    /**************************************************************/
    // Knockout Counters
    /**************************************************************/
    mapping(bytes32 => KnockoutLiq.KnockoutPivot) internal knockoutPivots_;
    mapping(bytes32 => KnockoutLiq.KnockoutMerkle) internal knockoutMerkles_;
    mapping(bytes32 => KnockoutLiq.KnockoutPos) internal knockoutPos_;
    /**************************************************************/

    
    /**************************************************************/
    // TickCensus
    /**************************************************************/
    mapping(bytes32 => uint256) internal mezzanine_;
    mapping(bytes32 => uint256) internal terminus_;
    /**************************************************************/
    

    /**************************************************************/
    // PoolRegistry
    /**************************************************************/
    mapping(uint256 => PoolSpecs.Pool) internal templates_;
    mapping(bytes32 => PoolSpecs.Pool) internal pools_;
    mapping(address => PriceGrid.ImproveSettings) internal improves_;
    uint128 internal newPoolLiq_;
    uint8 internal protocolTakeRate_;
    /**************************************************************/

    
    /**************************************************************/
    // ProtocolAccount
    /**************************************************************/
    mapping(address => uint128) internal feesAccum_;
    /**************************************************************/


    /**************************************************************/
    // PositionRegistrar
    /**************************************************************/
    struct RangePosition {
        uint128 liquidity_;
        uint64 feeMileage_;
        uint32 timestamp_;
        bool atomicLiq_;
    }

    struct AmbientPosition {
        uint128 seeds_;
        uint32 timestamp_;
    }
    
    mapping(bytes32 => RangePosition) internal positions_;
    mapping(bytes32 => AmbientPosition) internal ambPositions_;
    /**************************************************************/


    /**************************************************************/
    // LiquidityCurve
    /**************************************************************/
    mapping(bytes32 => CurveMath.CurveState) internal curves_;
    /**************************************************************/

    
    /**************************************************************/
    // UserBalance settings
    /**************************************************************/
    struct UserBalance {
        // Multiple loosely related fields are grouped together to allow
        // off-chain users to optimize calls to minimize cold SLOADS by
        // hashing needed data to the same slots.
        uint128 surplusCollateral_;
        uint32 nonce_;
        uint32 agentCallsLeft_;
    }
    
    mapping(bytes32 => UserBalance) internal userBals_;
    /**************************************************************/

    /**************************************************************/
    //  Incentive counters
    //  This data is not used by the dex internally, but is made available for external
    //  contracts to incentivize users and pools based on the fees generated by the dex
    //  or the amount of liquidity provided by users.
    //
    //  Data Collected:
    //  * Total fees generated per pool
    //  * Total fees generated per user per pool
    //  * Total concentrated liquidity added per pool
    //  * Total concentrated liquidity added per user per pool
    //  * Total concentrated liquidity removed per pool
    //  * Total concentrated liquidity removed per user per pool   
    /**************************************************************/
    // This accumulator represents the total amount of fees generated by a pool and can be compared to the per LP total of
    // fees generated in order to determine the LP's share of the fees. This is just a sum of all base token fees generated by the pool.
    // @note this value is updated continuously as fees are collected and does not include ambient liquidity fees.
    // @note this value is normalized as the geometric mean of the two fee values, this helps make the value more stable and reduces the need
    //       for the downstream incentives contract to do price calculations or take into account the current pool price.
    mapping(bytes32 => uint256) incentivePoolFeeAccumulators_;

    /**
     * @dev Returns the total fee counter for this pool, representing the sum of all concentrated liquidity fees ever collected in this pool.
     *      Note this value is updated continuously as fees are collected.
     * @param pool The pool who's fee value will be returned.
     */
    function incentivePoolFeeAccumulators(bytes32 pool) public view returns (uint256) {
        return incentivePoolFeeAccumulators_[pool];
    }

    /* @notice Commits the pool fees accumulator to storage, normalizing the base and quote values 
       @dev     This is used to keep track of all rewards paid out by a pool so that they can
                be incentivized by an external rewards contract
    */
    function updateIncentivePoolFeeAccumulator(int128 paidInBase, int128 paidInQuote, bytes32 poolId) internal {
        incentivePoolFeeAccumulators_[poolId] += normalizeFees(paidInBase, paidInQuote);
    }

    // The total amount of concentrated liquidity added to a pool. This value is incremented any time concentrated liquidity is added to a pool
    // @note this value is denominated normalized liquidity units using the sizeAddLiq function 
    mapping(bytes32 => uint256) incentivePoolConcLiqAddedAccumulators_;
    // The total amount of liquidity removed from a pool. This value is incremented any time concentrated liquidity is removed from a pool
    // @note since fees are collected as ambient liquidity removed must always be less than or equal to added.
    // @note this value is denominated normalized liquidity units using the sizeAddLiq function 
    mapping(bytes32 => uint256) incentivePoolConcLiqRemovedAccumulators_;

    /**
     * @dev Returns the total liquidity added to a pool, representing the sum of all concentrated liquidity added to the pool, in normalized liquidity units.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentivePoolConcLiqAddedAccumulators(bytes32 pool) public view returns (uint256) {
        return incentivePoolConcLiqAddedAccumulators_[pool];
    }

    /**
     * @dev Returns the total liquidity removed from a pool, representing the sum of all concentrated liquidity removed from the pool.
     *      Note this value is updated continuously as liquidity is removed.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentivePoolConcLiqRemovedAccumulators(bytes32 pool) public view returns (uint256) {
        return incentivePoolConcLiqRemovedAccumulators_[pool];
    }

    /**
     * @dev Commits the pool liquidity added accumulator to storage.
     * @param normalizedLiq The amount of liquidity added to the pool in normalized units.
     * @param poolId The pool who's liquidity value will be updated.
     */
    function updateIncentivePoolConcLiqAddedAccumulator(uint128 normalizedLiq, bytes32 poolId) internal {
        incentivePoolConcLiqAddedAccumulators_[poolId] += normalizedLiq;
    }
    /**
     * @dev Commits the pool liquidity removed accumulator to storage.
     * @param normalizedLiq The amount of liquidity removed from the pool in normalized units.
     * @param poolId The pool who's liquidity value will be updated.
     */
    function updateIncentivePoolConcLiqRemovedAccumulator(uint128 normalizedLiq, bytes32 poolId) internal {
        incentivePoolConcLiqRemovedAccumulators_[poolId] += normalizedLiq;
    }

    // The total amount of ambient liquidity added to a pool. This value is incremented any time ambient liquidity is added to a pool
    // @note this value is denominated normalized liquidity units
    mapping(bytes32 => uint256) incentivePoolAmbLiqAddedAccumulators_;
    // The total amount of liquidity removed from a pool. This value is incremented any time concentrated liquidity is removed from a pool
    // @note since fees are collected as ambient liquidity removed must always be less than or equal to added.
    // @note this value is denominated normalized liquidity units
    mapping(bytes32 => uint256) incentivePoolAmbLiqRemovedAccumulators_;

    /**
     * @dev Returns the total liquidity added to a pool, representing the sum of all concentrated liquidity added to the pool, in normalized liquidity units.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentivePoolAmbLiqAddedAccumulators(bytes32 pool) public view returns (uint256) {
        return incentivePoolAmbLiqAddedAccumulators_[pool];
    }

    /**
     * @dev Returns the total liquidity removed from a pool, representing the sum of all concentrated liquidity removed from the pool.
     *      Note this value is updated continuously as liquidity is removed.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentivePoolAmbLiqRemovedAccumulators(bytes32 pool) public view returns (uint256) {
        return incentivePoolAmbLiqRemovedAccumulators_[pool];
    }

    /**
     * @dev Commits the pool liquidity added accumulator to storage.
     * @param normalizedLiq The amount of liquidity added to the pool in normalized units.
     * @param poolId The pool who's liquidity value will be updated.
     */
    function updateIncentivePoolAmbLiqAddedAccumulator(uint128 normalizedLiq, bytes32 poolId) internal {
        incentivePoolAmbLiqAddedAccumulators_[poolId] += normalizedLiq;
    }
    /**
     * @dev Commits the pool liquidity removed accumulator to storage.
     * @param normalizedLiq The amount of liquidity removed from the pool in normalized units.
     * @param poolId The pool who's liquidity value will be updated.
     */
    function updateIncentivePoolAmbLiqRemovedAccumulator(uint128 normalizedLiq, bytes32 poolId) internal {
        incentivePoolAmbLiqRemovedAccumulators_[poolId] += normalizedLiq;
    }

    // This accumulator represents the total amount of fees generated by a specific LP owner in a pool and can be compared to the
    // total fees generated by the pool.
    // @note this value is updated only when the user claims their fees and does not include ambient liquidity fees.
    // @note this value is normalized as the geometric mean of the two fee values
    mapping(address => mapping(bytes32 => uint256)) incentiveUserPoolFeeAccumulators_;

    /**
     * @dev Returns the total fee counter for this pool and user, representing the sum of all concentrated liquidity fees ever collected by this user in this pool.
     *      Note this value is only updated when the user claims their fees.
     *      Note this value is normalized as the geometric mean of the two fee values.
     * @param pool The pool who's fee value will be returned.
     */
    function incentiveUserPoolFeeAccumulators(address user, bytes32 pool) public view returns (uint256) {
        return incentiveUserPoolFeeAccumulators_[user][pool];
    }

    /**
       @notice Commits the pool per user fees accumulator to storage. 
       @dev     This is used to keep track of all rewards paid out to a user so that they can
                be incentivized by an external rewards contract
       @param paidInBase The amount of fees paid in base tokens
       @param paidInQuote The amount of fees paid in quote tokens
       @param poolId The pool who's fee value will be updated.
       @param user The user who's fee value will be updated.
    */
    function updateIncentiveUserPoolFeeAccumulator(address user, int128 paidInBase, int128 paidInQuote, bytes32 poolId) internal {
        incentiveUserPoolFeeAccumulators_[user][poolId] += normalizeFees(paidInBase, paidInQuote);
    }

    // The total amount of concentrated liquidity added to a pool by a specific user. This value is incremented any time the user adds concentrated liquidity to the pool
    // note this value is denominated in normalized liquidity units using the sizeAddLiq function
    mapping(address => mapping(bytes32 => uint256)) incentiveUserPoolConcLiqAddedAccumulators_;
    // The total amount of concentrated liquidity removed from a pool by a specific user. This value is incremented any time the user removes concentrated liquidity from the pool
    // note since fees are collected as ambient liquidity removed must always be less than or equal to added.
    mapping(address => mapping(bytes32 => uint256)) incentiveUserPoolConcLiqRemovedAccumulators_;

    /**
     * @dev Returns the total liquidity added to a pool by a specific user, representing the sum of all concentrated liquidity added to the pool by the user in normalized liquidtiy units.
     * @param user The user who's liquidity value will be returned.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentiveUserPoolConcLiqAddedAccumulators(address user, bytes32 pool) public view returns (uint256) {
        return incentiveUserPoolConcLiqAddedAccumulators_[user][pool];
    }

    /**
     * @dev Returns the total liquidity removed from a pool by a specific user, representing the sum of all concentrated liquidity removed from the pool by the user in normalized liquidity units
     *      Note that since fees accure as ambient not concentrated liquidity removed must always be less than or equal to added.
     * @param user The user who's liquidity value will be returned.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentiveUserPoolConcLiqRemovedAccumulators(address user, bytes32 pool) public view returns (uint256) {
        return incentiveUserPoolConcLiqRemovedAccumulators_[user][pool];
    }

    /**
     * @dev Commits the user pool liquidity added accumulator to storage.
     * @param normalizedLiq The amount of liquidity added to the pool, in normalized liquidity units.
     * @param poolId The pool who's liquidity value will be updated.
     * @param user The user who's liquidity value will be updated.
     */
    function updateIncentiveUserPoolConcLiqAddedAccumulator(address user, uint128 normalizedLiq, bytes32 poolId) internal {
        incentiveUserPoolConcLiqAddedAccumulators_[user][poolId] += normalizedLiq;
    }
    /**
     * @dev Commits the user pool liquidity removed accumulator to storage.
     * @param normalizedLiq The amount of ambient liquidity removed from the pool, in normalized liquidity units.
     * @param poolId The pool who's liquidity value will be updated.
     * @param user The user who's liquidity value will be updated.
     */
    function updateIncentiveUserPoolConcLiqRemovedAccumulator(address user, uint128 normalizedLiq, bytes32 poolId) internal {
        incentiveUserPoolConcLiqRemovedAccumulators_[user][poolId] += normalizedLiq;
    }

    // The total amount of ambient liquidity added to a pool by a specific user. This value is incremented any time the user adds ambient liquidity to the pool
    // note this value is denominated in normalized liquidity units using the sizeAddLiq function
    mapping(address => mapping(bytes32 => uint256)) incentiveUserPoolAmbLiqAddedAccumulators_;
    // The total amount of ambient liquidity removed from a pool by a specific user. This value is incremented any time the user removes ambient liquidity from the pool
    // note since fees are collected as ambient liquidity removed must always be less than or equal to added.
    mapping(address => mapping(bytes32 => uint256)) incentiveUserPoolAmbLiqRemovedAccumulators_;

    /**
     * @dev Returns the total ambient liquidity added to a pool by a specific user, representing the sum of all ambient liquidity added to the pool by the user in normalized liquidity units.
     * @param user The user who's liquidity value will be returned.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentiveUserPoolAmbLiqAddedAccumulators(address user, bytes32 pool) public view returns (uint256) {
        return incentiveUserPoolAmbLiqAddedAccumulators_[user][pool];
    }

    /**
     * @dev Returns the total ambient liquidity removed from a pool by a specific user, representing the sum of all ambient liquidity removed from the pool by the user in normalized liquidity units
     *      Note that since fees accure as ambient not concentrated liquidity removed may not always be less than or equal to added if this user has accured
     *      fees in the form of ambient liquidity removed.
     * @param user The user who's liquidity value will be returned.
     * @param pool The pool who's liquidity value will be returned.
     */
    function incentiveUserPoolAmbLiqRemovedAccumulators(address user, bytes32 pool) public view returns (uint256) {
        return incentiveUserPoolAmbLiqRemovedAccumulators_[user][pool];
    }

    /**
     * @dev Commits the user pool ambient liquidity added accumulator to storage.
     * @param normalizedLiq The amount of ambient liquidity added to the pool, in normalized liquidity units.
     * @param poolId The pool who's liquidity value will be updated.
     * @param user The user who's liquidity value will be updated.
     */
    function updateIncentiveUserPoolAmbLiqAddedAccumulator(address user, uint128 normalizedLiq, bytes32 poolId) internal {
        incentiveUserPoolAmbLiqAddedAccumulators_[user][poolId] += normalizedLiq;
    }
    /**
     * @dev Commits the user pool ambient liquidity removed accumulator to storage.
     * @param normalizedLiq The amount of ambient liquidity removed from the pool, in normalized liquidity units.
     * @param poolId The pool who's liquidity value will be updated.
     * @param user The user who's liquidity value will be updated.
     */
    function updateIncentiveUserPoolAmbLiqRemovedAccumulator(address user, uint128 normalizedLiq, bytes32 poolId) internal {
        incentiveUserPoolAmbLiqRemovedAccumulators_[user][poolId] += normalizedLiq;
    }


    /**
     * @dev Normalizes the amount of fees paid as the srt(base*quote) (geometric mean) of the two amounts
     * @param paidInBase The amount of fees paid in base tokens
     * @param paidInQuote The amount of fees paid in quote tokens
     */
    function normalizeFees(int128 paidInBase, int128 paidInQuote) private pure returns (uint256) {
        return sqrt(uint256(abs(paidInBase)) * uint256(abs(paidInQuote)));
    }

    // sourced from https://github.com/Uniswap/v2-core/blob/v1.0.1/contracts/libraries/Math.sol
    function sqrt(uint y) private pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function abs(int x) private pure returns (int) {
        return x >= 0 ? x : -x;
    }
    /**************************************************************/

    address treasury_;
    uint64 treasuryStartTime_;
}

/* @notice Contains the storage or storage hash offsets of the fields and sidecars
 *         in StorageLayer.
 *
 * @dev Note that if the struct of StorageLayer changes, these slot locations *will*
 *      change, and the values below will have to be manually updated. */
library CrocSlots {

    // Slot location of storage slots and/or hash map storage slot offsets. Values below
    // can be used to directly read state in CrocSwapDex by other contracts.
    uint constant public AUTHORITY_SLOT = 0;
    uint constant public LVL_MAP_SLOT = 65538;
    uint constant public KO_PIVOT_SLOT = 65539;
    uint constant public KO_MERKLE_SLOT = 65540;
    uint constant public KO_POS_SLOT = 65541;
    uint constant public MEZZ_TICK_SLOT = 65542;
    uint constant public TERMINUS_TICK_SLOT = 65543;
    uint constant public POOL_TEMPL_SLOT = 65544;
    uint constant public POOL_PARAM_SLOT = 65545;
    uint constant public FEE_MAP_SLOT = 65548;
    uint constant public POS_MAP_SLOT = 65549;
    uint constant public AMB_MAP_SLOT = 65550;
    uint constant public CURVE_MAP_SLOT = 65551;
    uint constant public BAL_MAP_SLOT = 65552;

        
    // The slots of the currently attached sidecar proxy contracts. These are set by
    // covention and should be expanded over time as more sidecars are installed. For
    // backwards compatibility, upgraders should never break existing interface on
    // a pre-existing proxy sidecar.
    uint16 constant BOOT_PROXY_IDX = 0;
    uint16 constant SWAP_PROXY_IDX = 1;
    uint16 constant LP_PROXY_IDX = 2;
    uint16 constant COLD_PROXY_IDX = 3;
    uint16 constant LONG_PROXY_IDX = 4;
    uint16 constant MICRO_PROXY_IDX = 5;
    uint16 constant MULTICALL_PROXY_IDX = 6;
    uint16 constant KNOCKOUT_LP_PROXY_IDX = 7;
    uint16 constant FLAG_CROSS_PROXY_IDX = 3500;
    uint16 constant SAFE_MODE_PROXY_PATH = 9999;
}

// Not used in production. Just used so we can easily check struct size in hardhat.
contract StoragePrototypes is StorageLayout {
    UserBalance bal_;
    CurveMath.CurveState curve_;
    RangePosition pos_;
    AmbientPosition amb_;
    BookLevel lvl_;
}
