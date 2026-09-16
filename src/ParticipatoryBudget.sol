// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Minimal view surface of CitizenshipSBT that this contract depends on.
/// @dev `balanceOf` gates the electorate: the citizenship token is soulbound and
///      issued one-per-resident, so `balanceOf(voter) > 0` is a sufficient
///      eligibility check and no vote-weight checkpointing (ERC721Votes) is needed.
///      `totalSupply` supplies the electorate size used for the quorum. NOTE:
///      CitizenshipSBT must expose `totalSupply` (via ERC721Enumerable or a small
///      internal minted-minus-burned counter) for the quorum check to work.
interface ICitizenshipSBT {
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title ParticipatoryBudget
/// @notice On-chain vote for the CivicDAO public flow (participatory budgeting).
///         This contract implements the single on-chain function of the public
///         flow described in thesis section 4.4.3: casting a Quadratic Voting
///         ballot over a fixed slate of already-eligible proposals.
///
///         Design boundary (Option A). The contract only *attests* facts: the
///         per-proposal scores expressed by the community and the outcome the
///         Municipality later records. It does NOT pick a winner and does NOT
///         allocate funds. Eligibility screening, appropriation and execution
///         remain off-chain procedures of the Municipality (section 4.2.3).
///
///         Only AccessControl is inherited. There is no reentrancy surface (no
///         value transfers, no calls into untrusted contracts) and no operation
///         that would need pausing, so ReentrancyGuard/Pausable are deliberately
///         omitted rather than added by reflex.
contract ParticipatoryBudget is AccessControl {
    // --- Roles ---------------------------------------------------------------

    /// @notice The Municipality: opens rounds, deposits the eligible slate, and
    ///         records the outcome. It is external to the DAO (section 4.3.2).
    bytes32 public constant MUNICIPALITY_ROLE = keccak256("MUNICIPALITY_ROLE");

    // --- Quorum --------------------------------------------------------------

    /// @notice Quorum expressed in basis points of the electorate snapshot (10%).
    ///         Kept as a constant for now; can be promoted to a per-round
    ///         parameter later without changing the voting logic.
    uint256 public constant QUORUM_BPS = 1_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // --- Types ---------------------------------------------------------------

    enum Status {
        Active, // round open, votes accepted until `end`
        Closed // voting window elapsed, quorum computed
    }

    enum Outcome {
        Pending, // no decision recorded yet
        Executed, // Municipality proceeded with the proposal
        NotExecuted // Municipality departed from the vote (reasons required)
    }

    struct Proposal {
        string cid; // IPFS CID of the proposal document
        uint256 score; // QV tally: sum of votes received
        Outcome outcome; // recorded by the Municipality after close
        string reasonsCid; // IPFS CID of the written reasons (see recordOutcome)
    }

    struct Round {
        uint256 creditsPerVoter; // QV credit budget C, equal for every citizen
        uint64 start;
        uint64 end; // inclusive deadline
        uint256 electorate; // CitizenshipSBT.totalSupply() snapshot at open
        uint256 voterCount; // distinct citizens who voted
        uint256 proposalCount;
        Status status;
        bool quorumReached; // computed at close
    }

    // --- Storage -------------------------------------------------------------

    ICitizenshipSBT public immutable citizenship;

    uint256 public roundCount;
    mapping(uint256 => Round) private _rounds;
    // roundId => proposalId => Proposal
    mapping(uint256 => mapping(uint256 => Proposal)) private _proposals;
    // roundId => voter => already voted (enforces one-shot voting)
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    // roundId => voter => credits actually spent
    mapping(uint256 => mapping(address => uint256)) public creditsSpent;

    // --- Events --------------------------------------------------------------

    event RoundOpened(
        uint256 indexed roundId,
        uint256 creditsPerVoter,
        uint256 proposalCount,
        uint256 electorate,
        uint64 start,
        uint64 end
    );
    event VotesCast(uint256 indexed roundId, address indexed voter, uint256 creditsSpent);
    event RoundClosed(uint256 indexed roundId, uint256 voterCount, bool quorumReached);
    event OutcomeRecorded(
        uint256 indexed roundId,
        uint256 indexed proposalId,
        Outcome outcome,
        string reasonsCid,
        uint256 timestamp,
        address recordedBy
    );

    // --- Errors --------------------------------------------------------------

    error InvalidCredits();
    error NoProposals();
    error InvalidRound();
    error RoundNotActive();
    error RoundStillOpen();
    error RoundNotClosed();
    error VotingWindowClosed();
    error NotCitizen();
    error AlreadyVoted();
    error LengthMismatch();
    error EmptyBallot();
    error ProposalsNotSorted();
    error InvalidProposal();
    error ZeroVotes();
    error BudgetExceeded();
    error InvalidOutcome();
    error OutcomeAlreadyRecorded();
    error ReasonsRequired();

    // --- Constructor ---------------------------------------------------------

    constructor(address citizenshipSBT, address municipality) {
        citizenship = ICitizenshipSBT(citizenshipSBT);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MUNICIPALITY_ROLE, municipality);
    }

    // --- Municipality: open a round -----------------------------------------

    /// @notice Opens a voting round over a fixed, already-eligible slate.
    /// @dev Atomic registration: the whole slate is passed here in one call, so
    ///      the proposal set is frozen the instant voting starts and no proposal
    ///      can be added mid-vote (steps 1-2 of section 4.4.3 happen off-chain).
    ///      The electorate size is snapshotted now for the quorum.
    /// @param creditsPerVoter QV credit budget C. Choosing a perfect square (e.g.
    ///        100) is recommended so the max votes on a single proposal is a round
    ///        number (sqrt(C)); it is not enforced on-chain.
    /// @param proposalCids IPFS CIDs of the eligible proposals; index == proposalId.
    /// @param votingDuration Length of the voting window in seconds.
    function openRound(uint256 creditsPerVoter, string[] calldata proposalCids, uint64 votingDuration)
        external
        onlyRole(MUNICIPALITY_ROLE)
        returns (uint256 roundId)
    {
        if (creditsPerVoter == 0) revert InvalidCredits();
        if (proposalCids.length == 0) revert NoProposals();

        roundId = roundCount++;
        Round storage r = _rounds[roundId];
        r.creditsPerVoter = creditsPerVoter;
        r.start = uint64(block.timestamp);
        r.end = uint64(block.timestamp) + votingDuration;
        r.electorate = citizenship.totalSupply();
        r.proposalCount = proposalCids.length;
        r.status = Status.Active;

        for (uint256 i = 0; i < proposalCids.length; i++) {
            _proposals[roundId][i].cid = proposalCids[i];
        }

        emit RoundOpened(roundId, creditsPerVoter, proposalCids.length, r.electorate, r.start, r.end);
    }

    // --- Citizen: cast a Quadratic Voting ballot ----------------------------

    /// @notice Casts a one-shot QV ballot. Spending `v` votes on a proposal costs
    ///         `v*v` credits; the sum of costs must not exceed `creditsPerVoter`.
    /// @dev `proposalIds` must be strictly increasing. This both bounds each id
    ///      and forbids duplicates: without dedup a voter could list the same
    ///      proposal twice to split n votes into two entries and pay
    ///      2*(n/2)^2 < n^2, defeating the quadratic cost. Scores are accumulated
    ///      on write so closing the round is O(1) and never iterates over voters.
    function castVotes(uint256 roundId, uint256[] calldata proposalIds, uint256[] calldata votes) external {
        if (roundId >= roundCount) revert InvalidRound();
        Round storage r = _rounds[roundId];

        if (r.status != Status.Active) revert RoundNotActive();
        if (block.timestamp > r.end) revert VotingWindowClosed(); // `end` is inclusive
        if (citizenship.balanceOf(msg.sender) == 0) revert NotCitizen();
        if (hasVoted[roundId][msg.sender]) revert AlreadyVoted();
        if (proposalIds.length != votes.length) revert LengthMismatch();
        if (proposalIds.length == 0) revert EmptyBallot();

        uint256 cost;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 pid = proposalIds[i];
            if (i != 0 && pid <= proposalIds[i - 1]) revert ProposalsNotSorted();
            if (pid >= r.proposalCount) revert InvalidProposal();

            uint256 v = votes[i];
            if (v == 0) revert ZeroVotes();

            cost += v * v; // quadratic cost
            _proposals[roundId][pid].score += v; // running tally
        }

        if (cost > r.creditsPerVoter) revert BudgetExceeded();

        hasVoted[roundId][msg.sender] = true;
        creditsSpent[roundId][msg.sender] = cost;
        r.voterCount += 1;

        emit VotesCast(roundId, msg.sender, cost);
    }

    // --- Anyone: close a round after its window ------------------------------

    /// @notice Closes a round once its window has elapsed and computes the quorum.
    /// @dev Permissionless so the Municipality cannot stall closure. The quorum is
    ///      `voterCount >= electorate * QUORUM_BPS / BPS_DENOMINATOR`, written
    ///      without division to avoid rounding. `quorumReached` is only attested,
    ///      never enforced: binding force comes from the Municipality's regulation
    ///      (section 4.4.3), not from this flag.
    function closeRound(uint256 roundId) external {
        if (roundId >= roundCount) revert InvalidRound();
        Round storage r = _rounds[roundId];
        if (r.status != Status.Active) revert RoundNotActive();
        if (block.timestamp <= r.end) revert RoundStillOpen();

        r.status = Status.Closed;
        r.quorumReached = r.voterCount * BPS_DENOMINATOR >= r.electorate * QUORUM_BPS;

        emit RoundClosed(roundId, r.voterCount, r.quorumReached);
    }

    // --- Municipality: record the outcome (duty to give reasons) -------------

    /// @notice Records the Municipality's decision on a proposal after the round
    ///         closes, together with the CID of any written justification.
    /// @dev The duty to give reasons, codified (section 4.4.3, step 5): a proposal
    ///      cannot be marked NotExecuted without attaching the IPFS CID of the
    ///      written reasons. The chain does not store the reasons text, only its
    ///      CID: this makes the justification immutable (any edit changes the CID),
    ///      attributable (MUNICIPALITY_ROLE), and time-stamped. 
    function recordOutcome(uint256 roundId, uint256 proposalId, Outcome outcome, string calldata reasonsCid)
        external
        onlyRole(MUNICIPALITY_ROLE)
    {
        if (roundId >= roundCount) revert InvalidRound();
        Round storage r = _rounds[roundId];
        if (r.status != Status.Closed) revert RoundNotClosed();
        if (proposalId >= r.proposalCount) revert InvalidProposal();
        if (outcome == Outcome.Pending) revert InvalidOutcome(); // only terminal outcomes

        Proposal storage p = _proposals[roundId][proposalId];
        if (p.outcome != Outcome.Pending) revert OutcomeAlreadyRecorded();
        if (outcome == Outcome.NotExecuted && bytes(reasonsCid).length == 0) revert ReasonsRequired();

        p.outcome = outcome;
        p.reasonsCid = reasonsCid;

        emit OutcomeRecorded(roundId, proposalId, outcome, reasonsCid, block.timestamp, msg.sender);
    }

    // --- Views ---------------------------------------------------------------

    function getRound(uint256 roundId) external view returns (Round memory) {
        if (roundId >= roundCount) revert InvalidRound();
        return _rounds[roundId];
    }

    function getProposal(uint256 roundId, uint256 proposalId) external view returns (Proposal memory) {
        if (roundId >= roundCount) revert InvalidRound();
        if (proposalId >= _rounds[roundId].proposalCount) revert InvalidProposal();
        return _proposals[roundId][proposalId];
    }

    function getScore(uint256 roundId, uint256 proposalId) external view returns (uint256) {
        if (roundId >= roundCount) revert InvalidRound();
        if (proposalId >= _rounds[roundId].proposalCount) revert InvalidProposal();
        return _proposals[roundId][proposalId].score;
    }
}
