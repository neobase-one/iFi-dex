// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import "./mixins/StorageLayout.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* @title Althea Dex Incentives Epoch contract
 * @notice This contract is one possible rewards implementation based on the AltheaDex fee counter rewards system
 *         When a swap occurs the accumulated fees for that pool are totaled into an accumulator for that pool, likewise
 *         when that LP claims their portion of those fees an accumulator for that user is incremented.
 *         
 *         This contract implements an Epoch based fee system. Where users claim rewards after a specific number of blocks
 *         has elapsed. This is useful for a number of reasons, doing the rewards calculation in retrospect allows a fixed
 *         amount of rewards to be distributed pro-rata between all LP who generated fees during the epoch.
 * 
 *         An Example flow is
 *         (1) rewards are deposited and a specific epoch length is set by the rewards program creator, anyone can create a program
 *         (2) users must register for the next epoch before it starts, users must only register once ever, after that they are
 *             pre-registered for all epochs going forward
 *         (3) once the epoch has ended users can claim their rewards
 * 
 *         The Algorithm is
 *         (1) at the end of an epoch, or when users pre-register their fee counters are snapshotted along
 *         (2) at the end of the next epoch the total value of all registered users fee counters is summed, each users rewards
 *             are a ratio of their fees to the total fees for all registered users that epoch
 * 
 *         This means that we must do O(n) state updates where n is the number of registered users, every epoch. In order to distribute
 *         this expense the person to call endEpoch will recievee a portion of the rewards for their trouble. Defined as the rewardProcessorTip
 * 
 *         The rewardProcessorTip is given to the person who *finishes* the endEpcoh call, in the edgecase where the call is so large it must
 *         go over multiple transactions.
 *
 *         user_rewards = (user fees during this epoch * total epoch incentives) / sum(pool fees by registered users in this epoch)
 * 
 *         Events are emitted on new program creation, epoch progression, program completion, and when a user claims rewards
 *    */
contract AltheaDexIncentivesEpoch is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @dev The AltheaDex contract address. It must provide
     *      `liquidityIncentiveUserAndPoolAccumulators(user, poolId)`.
     *      Set once via the constructor and never changed thereafter.
     */
    address public immutable altheaDexAddress;

    /**
     * @dev Tracks how much each user can claim for a given token,
     *      aggregated across all programs (since a program is deleted when exhausted).
     *      Keyed by (userAddress => (tokenAddress => amount)).
     */
    mapping(address => mapping(address => uint256)) public claimable;

    /**
     * @notice The data for each incentive program.
     */
    struct Program {
        // Reward token for this program
        address rewardToken;
        // How many tokens are distributed to LPs each epoch
        uint256 epochRewardAmount;
        // Tip (in the same rewardToken) for whoever calls endEpoch()
        uint256 rewardProcessorTip;
        // Number of blocks per epoch
        uint256 epochLength;
        // Total tokens allocated for the entire program (initial supply)
        // Decreases by (epochRewardAmount + rewardProcessorTip) each epoch
        uint256 totalProgramRewards;
        // The block at which the current epoch started
        uint256 epochStartBlock;
        // The pool ID (bytes32)
        bytes32 poolId;
        // All participants who have called register. We loop over them in endEpoch.
        address[] participants;
        // Each participant's last known DEX fee accumulator
        // Nonzero means "registered."
        mapping(address => uint256) lastUserAccumulator;
    }

    /// @dev All active programs are stored in this array. Index = programId.
    Program[] public programs;

    /// @notice Emitted when a new program is created.
    event ProgramCreated(
        uint256 indexed programId,
        address indexed rewardToken,
        uint256 epochRewardAmount,
        uint256 rewardProcessorTip,
        uint256 epochLength,
        uint256 totalProgramRewards,
        bytes32 poolId
    );

    /// @notice Emitted when a user registers for a program.
    event UserRegistered(uint256 indexed programId, address indexed user);

    /// @notice Emitted each time an epoch distribution finishes.
    event EpochEnded(
        uint256 indexed programId,
        uint256 totalFees,
        uint256 epochReward,
        address indexed tipPaidTo,
        uint256 tipAmount
    );

    /// @notice Emitted when a program is exhausted and removed.
    event ProgramEnded(uint256 indexed programId);

    /// @notice Emitted when a user claims any reward token from their account.
    event RewardsClaimed(
        address indexed user,
        IERC20 indexed token,
        uint256 amount
    );

    /**
     * @dev Our trusted DEX must have the function:
     *      `liquidityIncentiveUserAndPoolAccumulators(address user, bytes32 poolId) external view returns (uint256)`
     */
    constructor(address _altheaDexAddress) {
        require(_altheaDexAddress != address(0), "INV");
        altheaDexAddress = _altheaDexAddress;
    }

    /**
     * @dev Creates a new rewards program.
     *      - Pulls `_initialFunds` from the caller into this contract
     *      - Checks that `_initialFunds` is divisible by `(epochRewardAmount + rewardProcessorTip)`
     *      - Starts the first epoch immediately (at `block.number`)
     *
     * @param _rewardToken          The ERC20 token used for rewards
     * @param _epochRewardAmount    How many tokens are distributed to LPs each epoch
     * @param _rewardProcessorTip   Tip (in the same token) paid to the endEpoch() caller
     * @param _epochLength          Number of blocks per epoch
     * @param _initialFunds         Total tokens allocated for the entire program
     * @param _poolId               The pool identifier (bytes32) for DEX accumulators
     */
    function createProgram(
        address _rewardToken,
        uint256 _epochRewardAmount,
        uint256 _rewardProcessorTip,
        uint256 _epochLength,
        uint256 _initialFunds,
        bytes32 _poolId
    ) external returns (uint256) {
        require(_rewardToken != address(0), "INV");
        require(_epochRewardAmount > 0, "ZR");
        require(_epochLength > 0, "ZEL");
        require(_initialFunds > 0, "NIF");

        // Must be an integer multiple of (epochReward + tip).
        uint256 totalPerEpoch = _epochRewardAmount + _rewardProcessorTip;
        require(totalPerEpoch > 0, "IED");
        require(
            _initialFunds % totalPerEpoch == 0,
            "ND"
        );

        // Pull tokens from the creator into this contract.
        IERC20(_rewardToken).safeTransferFrom(msg.sender, address(this), _initialFunds);

        // Create the program
        programs.push();
        uint256 programId = programs.length - 1;
        Program storage p = programs[programId];

        p.rewardToken = _rewardToken;
        p.epochRewardAmount = _epochRewardAmount;
        p.rewardProcessorTip = _rewardProcessorTip;
        p.epochLength = _epochLength;
        p.totalProgramRewards = _initialFunds;
        p.epochStartBlock = block.number;
        p.poolId = _poolId;

        emit ProgramCreated(
            programId,
            address(_rewardToken),
            _epochRewardAmount,
            _rewardProcessorTip,
            _epochLength,
            _initialFunds,
            _poolId
        );

        return programId;
    }

    /**
     * @dev Registers the caller for the given program if they haven't registered yet.
     *      We consider someone "registered" if their `lastUserAccumulator` is nonzero.
     *
     * @param programId The ID of the program in `programs` array
     */
    function registerForProgram(uint256 programId) external {
        Program storage p = programs[programId];
        // If totalProgramRewards == 0, it's exhausted or doesn't exist (deleted).
        require(p.totalProgramRewards > 0, "INID");

        // If lastUserAccumulator is nonzero, user is already registered.
        require(p.lastUserAccumulator[msg.sender] == 0, "AR");

        // Read current accumulator from DEX
        uint256 currentAcc = getDexAccumulator(msg.sender, p.poolId);

        // If the DEX value is 0, we require them to come back later
        // this pool may not exist, or the user may not have provided liquidity yet
        // since a potential attack is spamming user creation we want to ensure
        // the user has actually supplied liquidity
        require(currentAcc != 0, "AR");

        // the user should pay for all storage slot creation to reduce spam
        // viability
        p.participants.push(msg.sender);
        p.lastUserAccumulator[msg.sender] = currentAcc;
        claimable[msg.sender][p.rewardToken] = 0;

        emit UserRegistered(programId, msg.sender);
    }

    /**
     * @dev Ends the current epoch for a program, distributing rewards pro-rata
     *      based on each participant's fee accumulator difference. Pays out the
     *      tip to the caller. Moves on to the next epoch if there are enough
     *      tokens left; otherwise, ends the program.
     *
     * @param programId The ID of the program
     */
    function endEpoch(uint256 programId) external nonReentrant {
        Program storage p = programs[programId];
        require(p.totalProgramRewards > 0, "Program ended or invalid ID");

        // Must have waited for the epoch length to pass
        require(
            block.number >= p.epochStartBlock + p.epochLength,
            "Epoch not over yet"
        );

        // Distribute epochRewardAmount among participants
        uint256 totalFees = 0;
        address[] storage participants = p.participants;
        uint256 len = participants.length;

        // We'll store each user's feeDelta here to avoid repeated full/partial loops
        uint256[] memory feeDeltas = new uint256[](len);

        // 1) Calculate total fees by reading each participant's DEX accumulator difference
        for (uint256 i = 0; i < len; i++) {
            address user = participants[i];
            uint256 lastAcc = p.lastUserAccumulator[user];
            if (lastAcc == 0) {
                // Not truly registered, skip
                continue;
            }

            uint256 currentAcc = getDexAccumulator(user, p.poolId);
            uint256 feeDelta = 0;
            // If the DEX reading is higher than our stored snapshot, this user has new fees
            if (currentAcc > lastAcc) {
                feeDelta = currentAcc - lastAcc;
            }
            feeDeltas[i] = feeDelta;
            totalFees += feeDelta;
        }

        // 2) If totalFees > 0, do a pro-rata distribution of p.epochRewardAmount
        if (totalFees > 0) {
            uint256 rewardPerEpoch = p.epochRewardAmount;
            for (uint256 i = 0; i < len; i++) {
                uint256 delta = feeDeltas[i];
                if (delta == 0) continue;
                address user = participants[i];

                // userShare = (delta / totalFees) * rewardPerEpoch
                // For integer math, multiply first, then divide
                uint256 userShare = (delta * rewardPerEpoch) / totalFees;

                // Increase that user's global claimable balance
                claimable[user][address(p.rewardToken)] += userShare;
            }
        }

        // 3) Pay tip to endEpoch caller
        uint256 tip = p.rewardProcessorTip;
        if (tip > 0) {
            IERC20(p.rewardToken).safeTransfer(msg.sender, tip);
        }

        emit EpochEnded(
            programId,
            totalFees,
            p.epochRewardAmount,
            msg.sender,
            tip
        );

        // 4) Update each participant's snapshot to the latest DEX accumulator
        //    so next epoch only accounts for new fees after this block.
        for (uint256 i = 0; i < len; i++) {
            address user = participants[i];
            if (p.lastUserAccumulator[user] != 0) {
                // Save current DEX reading
                p.lastUserAccumulator[user] = getDexAccumulator(user, p.poolId);
            }
        }

        // 5) Move to the next epoch: reduce total rewards by (epochReward + tip).
        uint256 totalCost = p.epochRewardAmount + tip;
        p.totalProgramRewards -= totalCost;

        // If exhausted, end the program entirely
        if (p.totalProgramRewards == 0) {
            emit ProgramEnded(programId);
            delete programs[programId]; // Freed from storage
        } else {
            // Otherwise, reset the epochStartBlock
            p.epochStartBlock = block.number;
        }
    }

    /**
     * @dev Users call this to claim all the tokens they've accrued (across all programs)
     *      for the specified reward token. They do NOT specify a program ID, because
     *      the aggregator tracks everything by (user, token).
     *
     * @param token The ERC20 token the user wants to claim
     */
    function claimRewards(IERC20 token) external nonReentrant {
        uint256 amount = claimable[msg.sender][address(token)];
        require(amount > 0, "No rewards to claim");

        // Reset claimable to zero
        claimable[msg.sender][address(token)] = 0;

        // Transfer to user
        token.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, token, amount);
    }

    /**
     * @dev Returns how many programs exist in `programs` array.
     *      Some may have been deleted if they ended, so not all indices are valid.
     */
    function getProgramCount() external view returns (uint256) {
        return programs.length;
    }

    /**
     * @dev Returns a program’s basic info as a tuple, useful for off-chain queries.
     *
     * @param programId The ID of the program
     */
    function getProgramInfo(
        uint256 programId
    )
        external
        view
        returns (
            address rewardToken,
            uint256 epochRewardAmount,
            uint256 rewardProcessorTip,
            uint256 epochLength,
            uint256 totalProgramRewards,
            uint256 epochStartBlock,
            bytes32 poolId,
            uint256 participantCount
        )
    {
        Program storage p = programs[programId];
        rewardToken = address(p.rewardToken);
        epochRewardAmount = p.epochRewardAmount;
        rewardProcessorTip = p.rewardProcessorTip;
        epochLength = p.epochLength;
        totalProgramRewards = p.totalProgramRewards;
        epochStartBlock = p.epochStartBlock;
        poolId = p.poolId;
        participantCount = p.participants.length;
    }

    /**
     * @dev Returns the participant array for a given program.
     *      Some entries may have `lastUserAccumulator == 0` if they were never fully registered.
     */
    function getParticipants(
        uint256 programId
    ) external view returns (address[] memory) {
        return programs[programId].participants;
    }

    /**
     * @dev Helper: returns whether a user is "registered" in the program by
     *      checking if `lastUserAccumulator[user] != 0`.
     */
    function isRegistered(
        uint256 programId,
        address user
    ) external view returns (bool) {
        return programs[programId].lastUserAccumulator[user] != 0;
    }

    /**
     * @dev Internal helper to read the DEX accumulators.
     *      We assume the contract at `altheaDexAddress` has:
     *
     *        function incentiveUserPoolFeeAccumulators(address user, bytes32 poolId)
     *          external
     *          view
     *          returns (uint256);
     */
    function getDexAccumulator(
        address user,
        bytes32 poolId
    ) internal view returns (uint256) {
        StorageLayout storageLayout = StorageLayout(altheaDexAddress);

        return
            storageLayout.incentiveUserPoolFeeAccumulators(
                user,
                poolId
            );
    }
}
