// SPDX-License-Identifier: MIT
// Primordium Contracts
// Based on OpenZeppelin Contracts (last updated v4.8.0) (IGovernor.sol)

pragma solidity ^0.8.20;

import {IArrayLengthErrors} from "contracts/interfaces/IArrayLengthErrors.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IGovernorToken} from "contracts/governor/interfaces/IGovernorToken.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @dev Interface of the {GovernorBase} core.
 */
interface IGovernorBase is IArrayLengthErrors, IERC165, IERC6372 {

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    event GovernorBaseInitialized(
        string name,
        string version,
        address timelockAvatar,
        address token,
        uint256 governanceCanBeginAt,
        uint256 governanceThresholdBps,
        bool isFounded
    );

    /**
     * @dev Emitted when governance is initialized.
     */
    event GovernanceInitialized();

    /**
     * @dev Emitted when a proposal is created.
     */
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 voteStart,
        uint256 voteEnd,
        string description
    );

    /**
     * @dev Emitted when a proposal is queued.
     */
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);

    /**
     * @dev Emitted when a proposal is canceled.
     */
    event ProposalCanceled(uint256 indexed proposalId);

    /**
     * @dev Emitted when a proposal is executed.
     */
    event ProposalExecuted(uint256 indexed proposalId);

    /**
     * @dev Emitted when a vote is cast without params.
     *
     * Note: `support` values should be seen as buckets. Their interpretation depends on the voting module used.
     */
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight,
        string reason
    );

    /**
     * @dev Emitted when a vote is cast with params.
     *
     * Note: `support` values should be seen as buckets. Their interpretation depends on the voting module used.
     * `params` are additional encoded parameters. Their interpepretation also depends on the voting module used.
     */
    event VoteCastWithParams(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight,
        string reason,
        bytes params
    );

    /**
     * @dev The current state of a proposal is not the required for performing an operation.
     * The `expectedStates` is a bitmap with the bits enabled for each ProposalState enum position
     * counting from right to left.
     *
     * NOTE: If `expectedState` is `bytes32(0)`, the proposal is expected to not be in any state (i.e. not exist).
     * This is the case when a proposal that is expected to be unset is already initiated (the proposal is duplicated).
     *
     * See {GovernorBase-_encodeStateBitmap}.
     */
    error GovernorUnexpectedProposalState(uint256 proposalId, ProposalState current, bytes32 expectedStates);
    error GovernanceCannotInitializeYet(uint256 governanceCanBeginAt);
    error GovernanceThresholdIsNotMet(
        uint256 governanceThresholdBps,
        uint256 currentVoteSupply,
        uint256 currentRequiredVoteSupply
    );
    error GovernanceInitializationActionRequired();
    error UnknownProposalId(uint256 proposalId);
    error GovernorClockMustMatchTokenClock();
    error GovernorRestrictedProposer(address proposer);
    error UnauthorizedToSubmitProposal(address proposer);
    error UnauthorizedToCancelProposal();
    error NotReadyForGovernance();
    error InvalidActionSignature(uint256 index);
    error InvalidActionsForProposal();
    error TooLateToCancelProposal();
    error GovernorInvalidSignature(address voter);

    /**
     * @dev Name of the governor instance (used in building the ERC712 domain separator).
     */
    function name() external view returns (string memory);

    /**
     * @dev Version of the governor instance (used in building the ERC712 domain separator). Default: "1"
     */
    function version() external view returns (string memory);

    /**
     * @dev A description of the possible `support` values for {castVote} and the way these votes are counted, meant to
     * be consumed by UIs to show correct vote options and interpret the results. The string is a URL-encoded sequence
     * of key-value pairs that each describe one aspect, for example `support=bravo&quorum=for,abstain`.
     *
     * There are 2 standard keys: `support` and `quorum`.
     *
     * - `support=bravo` refers to the vote options 0 = Against, 1 = For, 2 = Abstain, as in `GovernorBravo`.
     * - `quorum=bravo` means that only For votes are counted towards quorum.
     * - `quorum=for,abstain` means that both For and Abstain votes are counted towards quorum.
     *
     * If a counting module makes use of encoded `params`, it should  include this under a `params` key with a unique
     * name that describes the behavior. For example:
     *
     * - `params=fractional` might refer to a scheme where votes are divided fractionally between for/against/abstain.
     * - `params=erc721` might refer to a scheme where specific NFTs are delegated to vote.
     *
     * NOTE: The string can be decoded by the standard
     * https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams[`URLSearchParams`]
     * JavaScript class.
     */
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external view returns (string memory);

    function token() external view returns (IGovernorToken);

    /**
     * Current state of a proposal, following Compound's convention.
     */
    function state(uint256 proposalId) external view returns (ProposalState);

    /**
     * Returns the total number of submitted proposals.
     */
    function proposalCount() external view returns (uint256 _proposalCount);

    /**
     * @dev Timepoint used to retrieve user's votes and quorum. If using block number (as per Compound's Comp), the
     * snapshot is performed at the end of this block. Hence, voting for this proposal starts at the beginning of the
     * following block.
     */
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);

    /**
     * @dev Timepoint at which votes close. If using block number, votes close at the end of this block, so it is
     * possible to cast a vote during this block.
     */
    function proposalDeadline(uint256 proposalId) external view returns (uint256);

    /**
     * @dev Returns the hash of the proposal actions
     */
    function proposalActionsHash(uint256 proposalId) external view returns (bytes32);

    /**
     * @dev Address of the proposer
     */
    function proposalProposer(uint256 proposalId) external view returns (address);

    /**
     * @dev The current number of votes that need to be delegated to the msg.sender in order to create a new proposal.
     */
    function proposalThreshold() external view returns (uint256);

    /**
     * @dev Delay, between the proposal is created and the vote starts. The unit this duration is expressed in depends
     * on the clock (see EIP-6372) this contract uses.
     *
     * This can be increased to leave time for users to buy voting power, or delegate it, before the voting of a
     * proposal starts.
     */
    function votingDelay() external view returns (uint256);

    /**
     * @dev Delay, between the vote start and vote ends. The unit this duration is expressed in depends on the clock
     * (see EIP-6372) this contract uses.
     *
     * NOTE: The {votingDelay} can delay the start of the vote. This must be considered when setting the voting
     * duration compared to the voting delay.
     */
    function votingPeriod() external view returns (uint256);

    /**
     * @dev Grace period after a proposal deadline passes in which a successful proposal must be queued for execution,
     * or else the proposal will expire. The unit this duration is expressed in depends on the clock (see EIP-6372) this
     * contract uses.
     */
    function proposalGracePeriod() external view returns (uint256);

    /**
     * @dev Minimum number of cast voted required for a proposal to be successful.
     *
     * NOTE: The `timepoint` parameter corresponds to the snapshot used for counting vote. This allows to scale the
     * quorum depending on values such as the totalSupply of a token at this timepoint (see {ERC20Votes}).
     */
    function quorum(uint256 timepoint) external view returns (uint256);

    /**
     * @dev Voting power of an `account` at a specific `timepoint`.
     */
    function getVotes(address account, uint256 timepoint) external view returns (uint256);

    /**
     * @dev Voting power of an `account` at a specific `timepoint` given additional encoded parameters.
     */
    function getVotesWithParams(
        address account,
        uint256 timepoint,
        bytes memory params
    ) external view returns (uint256);

    /**
     * @dev Returns whether `account` has cast a vote on `proposalId`.
     */
    function hasVoted(uint256 proposalId, address account) external view returns (bool);

    /**
     * Returns the timestamp that governance can be initiated after.
     */
    function governanceCanBeginAt() external view returns (uint256 _governanceCanBeginAt);

    /**
     * Returns the basis points amount of the governance token's max supply that needs to be in circulation before
     * governance can be initiated.
     */
    function governanceThresholdBps() external view returns (uint256 _governanceThresholdBps);

    /**
     * @dev Initializes governance. This function is the only allowable proposal action for the Governor until it has
     * been successfully executed through the proposal process.
     */
    function initializeGovernance() external;

    /**
     * @dev Returns true if the Governor has been initialized, meaning any proposal actions are available for
     * submission and execution.
     */
    function isGovernanceActive() external view returns (bool);

    /**
     * @dev Hashing function used to verify the proposal actions that were originally submitted.
     */
    function hashProposalActions(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external pure returns (bytes32);

    /**
     * Create a new proposal. Emits a {ProposalCreated} event.
     *
     * @notice Accounts with the PROPOSER_ROLE can submit proposals regardless of delegation.
     *
     * @param targets The execution targets.
     * @param values The execution values.
     * @param calldatas The execution calldatas.
     * @param signatures The human-readable signatures associated with the calldatas selectors. These are checked
     * against the selectors in the calldatas to ensure the provided actions line up with the human-readable signatures.
     * @param description The proposal description.
     * @dev If the proposal description ends with `#proposer=0x???`, where `0x???` is an address written as a hex string
     * (case insensitive), then the submission of this proposal will only be authorized to said address. This is used
     * as an opt-in protection against front-running.
     * @return proposalId Returns the ID of the newly created proposal.
     */
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string[] calldata signatures,
        string calldata description
    ) external returns (uint256 proposalId);

    /**
     * @dev Queue a proposal in the Executor for execution.
     *
     * Emits a {ProposalQueued} event.
     */
    function queue(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external returns (uint256 proposalId_);

    /**
     * @dev Execute a successful proposal. This requires the quorum to be reached, the vote to be successful, and the
     * deadline to be reached.
     *
     * Emits a {ProposalExecuted} event.
     *
     * Note: some module can modify the requirements for execution, for example by adding an additional timelock.
     */
    function execute(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external returns (uint256 proposalId_);

    /**
     * @dev Cancel a proposal. A proposal is cancellable by the proposer, but only while it is Pending state, i.e.
     * before the vote starts.
     *
     * Emits a {ProposalCanceled} event.
     *
     * Accounts with the CANCELER_ROLE can cancel the proposal anytime before execution.
     */
    function cancel(
        uint256 proposalId
    ) external returns (uint256 proposalId_);

    /**
     * @dev Public accessor to check the eta of a queued proposal.
     */
    function proposalEta(uint256 proposalId) external view returns (uint256);

    /**
     * @dev Cast a vote
     *
     * Emits a {VoteCast} event.
     */
    function castVote(uint256 proposalId, uint8 support) external returns (uint256 balance);

    /**
     * @dev Cast a vote with a reason
     *
     * Emits a {VoteCast} event.
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external returns (uint256 balance);

    /**
     * @dev Cast a vote with a reason and additional encoded parameters
     *
     * Emits a {VoteCast} or {VoteCastWithParams} event depending on the length of params.
     */
    function castVoteWithReasonAndParams(
        uint256 proposalId,
        uint8 support,
        string calldata reason,
        bytes memory params
    ) external returns (uint256 balance);

    /**
     * Cast a vote using the user's cryptographic signature.
     *
     * Emits a {VoteCast} event.
     *
     * @param signature The signature is a packed bytes encoding of the ECDSA r, s, and v signature values.
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        bytes memory signature
    ) external returns (uint256 balance);

    /**
     * @dev Cast a vote with a reason and additional encoded parameters using the user's cryptographic signature.
     *
     * Emits a {VoteCast} or {VoteCastWithParams} event depending on the length of params.
     *
     * @param signature The signature is a packed bytes encoding of the ECDSA r, s, and v signature values.
     */
    function castVoteWithReasonAndParamsBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        string calldata reason,
        bytes memory params,
        bytes memory signature
    ) external returns (uint256 balance);

}
