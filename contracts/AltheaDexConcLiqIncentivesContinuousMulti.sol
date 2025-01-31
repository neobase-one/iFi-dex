// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.28;

import "./mixins/StorageLayout.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/* @title Althea Dex Continuous Concentrated Liquidity Multi Token Incentives contract
 * @notice This contract provides incentives for concentrated liquidity on the Althea Dex using the externally accessible liquidity counters
 *         
 *         When a user provides liquidity to or removes liquidity from a pool, liquidity added and removed accumulators are incremented. This
 *         contract allows users to claim rewards based on the amount of liquidity they have provided and how long it has been provided.
 *         
 *         User Flow:
 *         1. User provides liquidity to a pool
 *         2. User calls register for rewards to start tracking their rewards
 *         3. After some time has passed, the user calls claim rewards. This will calculate and store the reward tokens owed to the user according to
 *            `LiquidityProvided * Blocks * RewardsRate`.
 *         4. User calls withdraw rewards to withdraw the rewards owed to them. 
 *         5. Once the user has called claim rewards, they do not need to call register for rewards unless they make changes to their liquidity position.
 *            Before they update liquidity, the user needs to claim rewards. After they update liquidity, they must register for rewards again so they
 *            accrue more rewards.
 *
 *         Note that by separating (3) and (4), user can accumulate rewards even if this contract does not have the sufficient reward tokens to pay them out
 *         at that moment. A convenience function is provided to do both at once.
 * 
 *         An important design decision is that if the user has added/removed liquidity since the last time they claimed rewards, they will
 *         not be able to claim rewards until the next time they have added/removed liquidity. Because this is an external contract reading
 *         dex values, it can only snapshot the accumulator values at the time of the call. If there has been no change to the liquidity added
 *         or removed accumulators between their register and claim calls, we can be sure that they have supplied that amount of liquidity for
 *         the duration between the calls. If there has been a change, we can't be sure how much liquidity they have supplied for the duration
 *         between the calls. The user could, for example, add liquidity, register, remove liquidity, add liquidity, and then claim rewards.
 * 
 *         So the optimal behavior for the user, especially with concentrated liquidity where they may want to change their position often, is
 *         to register for rewards, add liquidity, claim rewards, remove liquidity, and repeat for each position rebalancing. 
 *         This way they will get the maximum rewards for the liquidity they have provided.
 * 
 *         Admin Flow:
 *            Admin creates a rewards program by calling createOrModifyRewardsProgram. This defines the rewards ratio for a given pool and token
 *            combination. There can only be one program per pool per token type, but a single pool can have rewards programs for multiple token types.
 *            The rewards ratio represents the amount of rewards distributed per unit of liquidity provided. The rewards ratio can be changed at any time
 *            by calling createOrModifyRewardsProgram again and will need to be adjusted to account for changes in the rewards token value or the desired
 *            amount of liquidity. The ratio represents the amount of reward token per liquidity unit per block.
 * 
 *
 *
 *    */
contract AltheaDexConcLiqContinuousMultiTokenIncentives is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    StorageLayout public altheaDexAddress; // The StorageLayout-based Dex contract

    /* @notice A reward program represents the incentives defined for a particular pool on the Althea-DEX.
     *         The rewardToken is the ERC20 held by this contract which users may earn as rewards for providing concentrated liquidity.
     *         The reward rate defines the amount of rewardToken distributed to users according to the equation
     *         `LiquidityProvided * Blocks * RewardsRate`.
     *         For example, if a program should distribute 10^18 rewardToken wei per 10000 blocks per 5000 liquidity units, the rewardRateNumerator
     *         should be set to 10^18 and the rewardRateDenominator should be set to 10000 * 5000 = 50000000.
     *
     *         RewardPrograms can be initialized in a batch in the constructor or individually using createOrModifyRewardsProgram().
     */
    struct RewardProgram {
        IERC20 rewardToken;
        uint256 rewardRateNumerator;
        uint256 rewardRateDenominator;
        bool active;
    }

    /// @notice Assigns the altheaDexAddress and initializes all the reward programs provided.
    constructor(address _altheaDexAddress, address _owner, RewardProgram[] memory initialPrograms, bytes32[] memory programPools) {
        require(initialPrograms.length == programPools.length, "Mismatched program and pool lengths");

        // Save the DEX address
        altheaDexAddress = StorageLayout(_altheaDexAddress);

        // Create initial programs (if there are any)
        for (uint256 i = 0; i < initialPrograms.length; i++) {
            RewardProgram memory program = initialPrograms[i];
            bytes32 pool = programPools[i];
            _createOrModifyRewardsProgram(pool, address(program.rewardToken), program.rewardRateNumerator, program.rewardRateDenominator);
        }

        // Set the owner if desired
        if (_owner != address(0)) {
            transferOwnership(_owner);
        }
    }

    /// @dev Tracks user liquidity snapshots from the DEX at registration and claim time, which populates the pendingRewards to be paid out to the user
    ///      when this contract holds enough of the reward token to pay them out.
    struct UserRewardInfo {
        uint256 lastLiqAddedSnapshot;
        uint256 lastLiqRemovedSnapshot; 
        uint256 pendingRewards;
        uint256 lastRegisterBlock;
    }

    // Mapping of poolId => rewardToken => RewardProgram
    mapping(bytes32 => mapping(address => RewardProgram)) public rewardPrograms;
    // Mapping of user => poolId => rewardToken => UserRewardInfo
    mapping(address => mapping(bytes32 => mapping(address => UserRewardInfo))) public userRewardInfo;

    event RewardsProgramCreatedOrModified(bytes32 indexed poolId, address indexed rewardToken, uint256 numerator, uint256 denominator);
    event RegisteredForRewards(address indexed user, bytes32 indexed poolId, address indexed rewardToken);
    event ClaimedRewards(address indexed user, bytes32 indexed poolId, address indexed rewardToken, uint256 amount);
    event WithdrawnRewards(address indexed user, address indexed rewardToken, uint256 amount);

    /// @notice Track all users in an EnumerableSet for demonstration in totalOwed
    /// @dev We track users like this for O(1) insert and O(n) iteration, however efficiency of iteration is not critical
    EnumerableSet.AddressSet private allUsers;

    // Admin function - creates/updates a reward program for a pool and a rewards token
    function createOrModifyRewardsProgram(
        bytes32 poolId,
        address rewardToken,
        uint256 rewardRateNumerator,
        uint256 rewardRateDenominator
    ) external onlyOwner {
        _createOrModifyRewardsProgram(poolId, rewardToken, rewardRateNumerator, rewardRateDenominator);
    }

    function _createOrModifyRewardsProgram(
        bytes32 poolId,
        address rewardToken,
        uint256 rewardRateNumerator,
        uint256 rewardRateDenominator
    ) internal {
        require(rewardRateDenominator != 0, "Zero denominator");
        rewardPrograms[poolId][rewardToken] = RewardProgram({
            rewardToken: IERC20(rewardToken),
            rewardRateNumerator: rewardRateNumerator,
            rewardRateDenominator: rewardRateDenominator,
            active: true
        });
        emit RewardsProgramCreatedOrModified(poolId, rewardToken, rewardRateNumerator, rewardRateDenominator);
    }

    /// @notice Admin-only: Deactivates a rewards program so that new rewards cannot be accrued, but existing rewards can still be withdrawn.
    function deactivateRewardsProgram(bytes32 poolId, address rewardToken) external onlyOwner {
        rewardPrograms[poolId][rewardToken].active = false;
    }

    /* @notice Users must call this function after providing liquidity to a pool on the DEX to begin tracking their liquidity rewards.
     *         IMPORTANT: Do not modify any liquidity positions in the pool after calling this function without first calling claimRewards/withdrawRewards or your rewards will be lost.
     *         If you want to update a liquidity position, call claimRewards or withdrawRewards, update your liquidity, and then call registerForRewards again to accrue future rewards.
     * @dev    This function tracks user liquidity accumulator values in the DEX and the registration block for later use in calculating rewards.
     *         Rewards will only be tracked for users who have called this function after creating a liquidity position.
     */
    function registerForRewards(bytes32 poolId, address rewardToken) external nonReentrant {
        RewardProgram storage program = rewardPrograms[poolId][rewardToken];
        require(program.active, "Program inactive");

        // We could check that allUsers doesn't contain the user, but the add implementation will do that for us already.
        allUsers.add(msg.sender);

        (uint256 userAdded, uint256 userRemoved) = _getUserLiqSnapshots(poolId, msg.sender);
        UserRewardInfo storage info = userRewardInfo[msg.sender][poolId][rewardToken];
        info.lastLiqAddedSnapshot = userAdded;
        info.lastLiqRemovedSnapshot = userRemoved;
        info.lastRegisterBlock = block.number;

        emit RegisteredForRewards(msg.sender, poolId, rewardToken);
    }

    /* @notice Calculates the rewards earned after registering for rewards and tracks this in the user's pendingRewards for the pool.
     *         IMPORTANT: Do not modify any liquidity positons in the pool after registering for rewards without first calling this function or your rewards will be lost.
     *         This function merely tracks rewards, to receive the rewards owed to you, call withdrawRewards().
     *         Users should typically call this function when withdrawRewards() has failed due to a transfer failure and they want to modify a liquidity position in the pool.
     *         By calling this function, rewards are locked in and can be withdrawn later when the contract has been funded by calling withdrawRewards()
     *         Call this function often, because rewards are only tracked for active programs. If you register for rewards and fail to claim them before the program ends,
     *         you will lose any potential rewards owed.
     * @dev    This function updates the user's pendingRewards for the pool but does not pay out rewards.
     */
    function claimRewards(bytes32 poolId, address rewardToken) external nonReentrant {
        _claimRewards(poolId, rewardToken);
    }

    function _claimRewards(bytes32 poolId, address rewardToken) internal {
        RewardProgram storage program = rewardPrograms[poolId][rewardToken];
        UserRewardInfo storage info = userRewardInfo[msg.sender][poolId][rewardToken];

        // Compute rewards (zero if program inactive or user’s liquidity changed)
        uint256 newlyEarned = _computeRewards(program, info, poolId, msg.sender);
        if (newlyEarned > 0 && program.active) {
            info.pendingRewards += newlyEarned;
        }

        // Update user snapshots
        (uint256 curAdded, uint256 curRemoved) = _getUserLiqSnapshots(poolId, msg.sender);
        info.lastLiqAddedSnapshot = curAdded;
        info.lastLiqRemovedSnapshot = curRemoved;
        info.lastRegisterBlock = block.number;

        emit ClaimedRewards(msg.sender, poolId, rewardToken, newlyEarned);
    }

    /* @notice Calculates the rewards earned after registering for rewards and pays them out.
     *         IMPORTANT: Do not modify any liquidity positons in the pool after registering for rewards without first calling this function or your rewards will be lost.
     *         If this function call fails due to a transfer failure, you can call claimRewards instead to lock in rewards and claim later with this function once the
     *         contract has been funded.
     *         Call this function often, because rewards are only tracked for active programs. If you register for rewards and fail to withdraw/claim them before the program ends,
     *         you will lose any potential rewards owed.
     * @dev    This function calls claimRewards at the start and pays out the pendingRewards to the user.
     */
    function withdrawRewards(bytes32 poolId, address rewardToken) external nonReentrant {
        // First run claim logic (even if program is inactive, let them withdraw pending)
        _claimRewards(poolId, rewardToken);

        UserRewardInfo storage info = userRewardInfo[msg.sender][poolId][rewardToken];
        uint256 amount = info.pendingRewards;
        require(amount > 0, "No rewards");

        info.pendingRewards = 0;
        rewardPrograms[poolId][rewardToken].rewardToken.safeTransfer(msg.sender, amount); // c(°o°)o

        emit WithdrawnRewards(msg.sender, rewardToken, amount);
    }

    /* @notice View function which calculates the amount of reward tokens a user is entitled to if they claim now.
     *         This function does not update the user's pendingRewards, it only calculates the rewards owed to the user.
     *         This function is useful for users who want to call off-chain to know how much they will earn before calling claimRewards.
    */
    function getPendingRewards(bytes32 poolId, address user, address rewardToken) external view returns (uint256) {
        RewardProgram memory program = rewardPrograms[poolId][rewardToken];
        UserRewardInfo memory info = userRewardInfo[user][poolId][rewardToken];
        return info.pendingRewards + _computeRewards(program, info, poolId, user);
    }

    /* @notice View function which calculates the total amount of reward tokens owed to all users in a pool.
     *         This function is useful for the admin to call off-chain to know how much the contract currently owes users.
     */
    function totalOwed(bytes32 poolId, address rewardToken) external view returns (uint256 total) {
        RewardProgram memory program = rewardPrograms[poolId][rewardToken];
        address[] memory users = allUsers.values();
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            UserRewardInfo memory info = userRewardInfo[u][poolId][rewardToken];
            // Sum claimable + pending
            uint256 claimable = _computeRewards(program, info, poolId, u);
            total += (info.pendingRewards + claimable);
        }
    }

    /// @dev Rewards calculation (returns zero if the user’s liquidity has changed since register)
    function _computeRewards(
        RewardProgram memory program,
        UserRewardInfo memory info,
        bytes32 poolId,
        address user
    ) private view returns (uint256) {
        if (!program.active) {
            // If program is not active, no new rewards are accrued, but user can withdraw any existing
            return 0;
        }

        // If user’s liquidity has changed, they accrue no new rewards
        (uint256 curAdded, uint256 curRemoved) = _getUserLiqSnapshots(poolId, user);
        bool changed = (curAdded != info.lastLiqAddedSnapshot || curRemoved != info.lastLiqRemovedSnapshot);
        if (changed) {
            return 0;
        }

        return _rewardsEntitlement(program, info, block.number);
    }

    /// @dev Returns user’s added & removed concentrated liquidity from storage
    function _getUserLiqSnapshots(bytes32 poolId, address user) internal view returns (uint256 added, uint256 removed) {
        added = _currentUserLiqAdded(poolId, user);
        removed = _currentUserLiqRemoved(poolId, user);
    }

    /// @dev Returns a users accumulated liquidity added to a pool
    function _currentUserLiqAdded(bytes32 poolId, address user) internal view returns (uint256) {
        return altheaDexAddress.incentiveUserPoolConcLiqAddedAccumulators(user, poolId);
    }

    /// @dev Returns a users accumulated liquidity removed from a pool
    function _currentUserLiqRemoved(bytes32 poolId, address user) internal view returns (uint256) {
        return altheaDexAddress.incentiveUserPoolConcLiqRemovedAccumulators(user, poolId);
    }

    /// @dev Calculate rewards entitlement: NetLiquidity * NumBlocks * RateNumerator / RateDenominator
    function _rewardsEntitlement(RewardProgram memory program, UserRewardInfo memory info, uint256 currBlock) internal pure returns (uint256) {
        uint256 netLiq = (info.lastLiqAddedSnapshot > info.lastLiqRemovedSnapshot)
            ? (info.lastLiqAddedSnapshot - info.lastLiqRemovedSnapshot)
            : 0;
        uint256 blockDelta = currBlock - info.lastRegisterBlock;
        return
            (netLiq * blockDelta * program.rewardRateNumerator) /
            program.rewardRateDenominator;
    }
}
