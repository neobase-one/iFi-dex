// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.28;

import "./mixins/StorageLayout.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* @title Althea Dex Continuous Concentrated liquidity Multi Token Incentives contract
 * @notice This contract provides incentives for concentrated liquidity on the Althea Dex using the externally accessible liquidity counters
 *         
 *         When a user provides liquidity to or removes liquidity from a pool liquidity added and removed accumulators are increemented. This
 *         contract allows users to claim rewards based on the amount of liquidity they have provided and how long it has been provided.
 *         
 *         User Flow:
 *         1. User provides liquidity to a pool
 *         2. User calls register for rewards to start tracking their rewards
 *         3. After some time has pased the user calls claim rewards. This will calculate their rewards based on the number of blocks that have elapsed, 
 *            the amount of liquidity and the rewards ratio for the pool and token type. Then store the amount of reward tokens owed to that user.
 *         4. User can call withdraw rewards to withdraw the rewards owed to them. Separating (3) and (4) allows the user to accumulate rewards even if
 *            the contract does not have the sufficient reward tokens to pay them out at that moment. A convience function is provided to do both at once.
 *         5. Once the user has called claim rewards they can either make no changes to their liquidity. If no changes are made they can call claim rewards
 *            again after some time. If they have added or removed liquidity they will need to call register for rewards again before they can claim rewards.
 * 
 *         An important design decision is that if the user has added/removed liquidity ince the last time they claimed rewards they will
 *         not be able to claim rewards until the next time they have added/removed liquidity. Becuase this is an external contract reading
 *         dex values it can only snapshot the accumulator values at the time of the call. If there has been no change to the liquidity added
 *         or removed accumulators between their register and claim calls we can be sure that they have supplied that amount of liquidity for
 *         the duration between the calls. If there has been a change we can't be sure how much liquidity they have supplied for the duration
 *         between the calls. The user could for example add liquidity, register, remove liquidity, add liquidity, and then claim rewards.
 * 
 *         So the optimal behavior for the user, especially with concentrated liquidity where they may want to change their position often is
 *         to register for rewards, add liquidity, claim rewards, remove liquidty, and repeat for each position rebalancing. 
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

    address public altheaDexAddress; // The StorageLayout-based Dex contract

    struct RewardProgram {
        IERC20 rewardToken;
        // Store ratio
        uint256 rewardRateNumerator;
        uint256 rewardRateDenominator;
        bool active;
    }

    struct UserRewardInfo {
        uint256 lastLiqAddedSnapshot;
        uint256 lastLiqRemovedSnapshot; 
        uint256 pendingRewards;
        uint256 lastRegisterBlock;
    }

    mapping(bytes32 => mapping(address => RewardProgram)) public rewardPrograms;
    mapping(address => mapping(bytes32 => mapping(address => UserRewardInfo))) public userRewardInfo;

    event RewardsProgramCreatedOrModified(bytes32 indexed poolId, address indexed rewardToken, uint256 numerator, uint256 denominator);
    event RegisteredForRewards(address indexed user, bytes32 indexed poolId, address indexed rewardToken);
    event ClaimedRewards(address indexed user, bytes32 indexed poolId, address indexed rewardToken, uint256 amount);
    event WithdrawnRewards(address indexed user, address indexed rewardToken, uint256 amount);

    // Track all users in an array for demonstration in totalOwed
    address[] public allUsers;

    function createOrModifyRewardsProgram(
        bytes32 poolId,
        address rewardToken,
        uint256 rewardRateNumerator,
        uint256 rewardRateDenominator
    ) external onlyOwner {
        require(rewardRateDenominator != 0, "Zero denominator");
        rewardPrograms[poolId][rewardToken] = RewardProgram({
            rewardToken: IERC20(rewardToken),
            rewardRateNumerator: rewardRateNumerator,
            rewardRateDenominator: rewardRateDenominator,
            active: true
        });
        emit RewardsProgramCreatedOrModified(poolId, rewardToken, rewardRateNumerator, rewardRateDenominator);
    }

    function deactivateRewardsProgram(bytes32 poolId, address rewardToken) external onlyOwner {
        rewardPrograms[poolId][rewardToken].active = false;
    }

    function registerForRewards(bytes32 poolId, address rewardToken) external nonReentrant {
        RewardProgram storage program = rewardPrograms[poolId][rewardToken];
        require(program.active, "Program inactive");

        if (!_isKnownUser(msg.sender)) {
            allUsers.push(msg.sender);
        }

        (uint256 userAdded, uint256 userRemoved) = _getUserLiqSnapshots(poolId, msg.sender);
        UserRewardInfo storage info = userRewardInfo[msg.sender][poolId][rewardToken];
        info.lastLiqAddedSnapshot = userAdded;
        info.lastLiqRemovedSnapshot = userRemoved;
        info.lastRegisterBlock = block.number;

        emit RegisteredForRewards(msg.sender, poolId, rewardToken);
    }

    function claimRewards(bytes32 poolId, address rewardToken) public nonReentrant {
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

    function withdrawRewards(bytes32 poolId, address rewardToken) external nonReentrant {
        // First run claim logic (even if program is inactive, let them withdraw pending)
        claimRewards(poolId, rewardToken);

        UserRewardInfo storage info = userRewardInfo[msg.sender][poolId][rewardToken];
        uint256 amount = info.pendingRewards;
        require(amount > 0, "No rewards");

        info.pendingRewards = 0;
        rewardPrograms[poolId][rewardToken].rewardToken.safeTransfer(msg.sender, amount);

        emit WithdrawnRewards(msg.sender, rewardToken, amount);
    }

    // View for a user's pending rewards
    function getPendingRewards(bytes32 poolId, address user, address rewardToken) external view returns (uint256) {
        RewardProgram memory program = rewardPrograms[poolId][rewardToken];
        UserRewardInfo memory info = userRewardInfo[user][poolId][rewardToken];
        return info.pendingRewards + _simulateRewards(program, info, poolId, user);
    }

    // Summation over known users (demonstration: not recommended for on-chain usage)
    function totalOwed(bytes32 poolId, address rewardToken) external view returns (uint256 total) {
        RewardProgram memory program = rewardPrograms[poolId][rewardToken];
        for (uint256 i = 0; i < allUsers.length; i++) {
            address u = allUsers[i];
            UserRewardInfo memory info = userRewardInfo[u][poolId][rewardToken];
            // Sum claimable + pending
            uint256 claimable = _simulateRewards(program, info, poolId, u);
            total += (info.pendingRewards + claimable);
        }
    }

    // Rewards calculation (returns zero if the user’s liquidity has changed since register)
    function _computeRewards(
        RewardProgram storage program,
        UserRewardInfo storage info,
        bytes32 poolId,
        address user
    ) private view returns (uint256) {
        if (!program.active) {
            // If program is not active, no new rewards are accrued, but user can withdraw any existing
            return 0;
        }

        // Check if user’s liquidity changed
        (uint256 curAdded, uint256 curRemoved) = _getUserLiqSnapshots(poolId, user);
        bool changed = (curAdded != info.lastLiqAddedSnapshot || curRemoved != info.lastLiqRemovedSnapshot);
        if (changed) {
            return 0;
        }

        // No change => net liquidity is (lastLiqAddedSnapshot - lastLiqRemovedSnapshot)
        uint256 netLiq = info.lastLiqAddedSnapshot > info.lastLiqRemovedSnapshot
            ? info.lastLiqAddedSnapshot - info.lastLiqRemovedSnapshot
            : 0;
        uint256 blockDelta = block.number - info.lastRegisterBlock;

        return
            (netLiq * blockDelta * program.rewardRateNumerator) /
            program.rewardRateDenominator;
    }

    // Purely for read usage in getPendingRewards
    function _simulateRewards(
        RewardProgram memory program,
        UserRewardInfo memory info,
        bytes32 poolId,
        address user
    ) private view returns (uint256) {
        if (!program.active) {
            return 0;
        }
        // Compare current accumulators with stored snapshots
        (uint256 curAdded, uint256 curRemoved) = _getUserLiqSnapshots(poolId, user);
        bool changed = (curAdded != info.lastLiqAddedSnapshot || curRemoved != info.lastLiqRemovedSnapshot);
        if (changed) {
            return 0;
        }

        uint256 netLiq = (info.lastLiqAddedSnapshot > info.lastLiqRemovedSnapshot)
            ? (info.lastLiqAddedSnapshot - info.lastLiqRemovedSnapshot)
            : 0;
        uint256 blockDelta = block.number - info.lastRegisterBlock;
        return
            (netLiq * blockDelta * program.rewardRateNumerator) /
            program.rewardRateDenominator;
    }

    // Helper: returns user’s added & removed concentrated liquidity from storage
    function _getUserLiqSnapshots(bytes32 poolId, address user) internal view returns (uint256 added, uint256 removed) {
        added = _currentUserLiqAdded(poolId, user);
        removed = _currentUserLiqRemoved(poolId, user);
    }

    // Replace stubs with actual StorageLayout calls for concentrated liquidity
    function _currentUserLiqAdded(bytes32 poolId, address user) internal view returns (uint256) {
        // Example usage:
        // return StorageLayout(altheaDexAddress).incentiveUserPoolConcLiqAddedAccumulators_(user, poolId);
        return 0; // Stub
    }

    function _currentUserLiqRemoved(bytes32 poolId, address user) internal view returns (uint256) {
        // Example usage:
        // return StorageLayout(altheaDexAddress).incentiveUserPoolConcLiqRemovedAccumulators_(user, poolId);
        return 0; // Stub
    }

    // Mark user as known
    function _isKnownUser(address user) private view returns (bool) {
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (allUsers[i] == user) {
                return true;
            }
        }
        return false;
    }
}
