// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICommunityCredit} from "./interfaces/ICommunityCredit.sol";
import {IProofOfParticipation} from "./interfaces/IProofOfParticipation.sol";
import {IReputation} from "./interfaces/IReputation.sol";
import {IJury} from "./interfaces/IJury.sol";

/// @notice Minimal view surface of CitizenshipSBT that this contract depends on.
/// @dev `balanceOf` is enough for eligibility: the citizenship token is
///      soulbound and issued one-per-resident, so `balanceOf(x) > 0` is a
///      sufficient check for proposers, team members and voters alike.
///      `totalSupply` supplies the electorate size for the quorum, exactly as
///      in ParticipatoryBudget: see QUORUM_BPS.
interface ICitizenshipSBTView {
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title CivicProject
/// @notice On-chain state machine governing the full lifecycle of a civic
///         project in the CivicDAO private flow (thesis sez. 4.4.2, Fig. 4.5).
///
///         Design boundary. CivicProject depends on the concrete economy only
///         through four frontier interfaces (ICommunityCredit,
///         IProofOfParticipation, IReputation, IJury) and on CitizenshipSBT
///         only in read-only fashion (balanceOf). It never imports a concrete
///         implementation: governance (this contract) commands, economy
///         executes. It also never touches or custodies ether or any other
///         on-chain value: no euro ever moves through this contract. The
///         proposer's declared `budgetEuro` (see `propose`) is recorded
///         on-chain, but only as a NUMBER for voters to judge the proposal
///         by -- it is never paid, reconciled, or enforced here, and it is
///         NOT what actually gets reimbursed: the real reimbursed amount
///         comes from the receipts in the evidence submitted at
///         `submitEvidence` (verified off-chain, optimistically or by the
///         jury), which is why `ReimbursementDue` deliberately carries no
///         amount at all. "Funded" is only a flag that authorizes the team
///         to start work and starts the 30-day execution timer; a "refund"
///         on Rejected/Expired is purely conceptual (no on-chain money ever
///         moved, so nothing is "returned" beyond the credit allocation
///         simply never being minted).
///
///         State machine (sez. 4.4.2):
///           Proposed -> Voting -> (Funded | Archived)
///           Funded -> Submitted -> (Confirmed | Challenged -> Confirmed/Rejected) | Expired
///         There is no on-chain Discussion/TeamFormation phase: the first
///         on-chain step after `propose` is collecting the team's binding
///         consent (still gating `Proposed -> Voting`), then the vote itself.
///
///         No AccessControl/roles are needed: every transition is either
///         citizen-gated (via balanceOf), team-gated, jury-gated (via
///         IJury.isJuror) or fully permissionless once its time window has
///         elapsed -- mirroring ParticipatoryBudget.closeRound's rationale
///         that a permissionless closer prevents any single actor from
///         stalling the flow. `_settle` flips `status` to Confirmed BEFORE
///         making any external call (mint/increase), so the checks-effects-
///         interactions pattern alone rules out reentrancy; ReentrancyGuard
///         is deliberately omitted rather than added by reflex.
contract CivicProject {
    // --- Types -----------------------------------------------------------

    enum Status {
        Proposed, // created; team consent being collected
        Voting, // full team consent reached; citizens voting
        Funded, // approved by vote; team authorized to execute (off-chain money starts moving)
        Archived, // rejected by vote or quorum not met; nothing minted
        Submitted, // evidence uploaded; optimistic verification window running
        Challenged, // a citizen contested within the verification window; awaiting jury
        Confirmed, // verified (optimistically or by jury); credit/PoP/reputation minted
        Rejected, // jury ruled against the submission; nothing minted
        Expired // no evidence submitted within the execution window; nothing minted
    }

    struct Project {
        address proposer;
        string description;
        address[] team;
        uint256 creditAllocation; // community-credit units earmarked for performers
        uint256 budgetEuro; // proposer's declared cost estimate, whole euro, informational
        // only (see the contract-level @notice): never paid or enforced on-chain, and NOT
        // the amount actually reimbursed -- that comes from the receipts in the evidence.
        uint64 verificationWindow; // seconds, from submitEvidence to the optimistic deadline
        uint64 executionWindow; // seconds, from Funded to the execution deadline
        Status status;
        uint256 consentCount;
        uint64 votingEnd;
        uint256 electorate; // CitizenshipSBT.totalSupply() snapshot taken when voting opens
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 voterCount;
        uint64 fundedAt;
        uint64 executionDeadline;
        string evidenceIpfsHash;
        address[] performers; // subset of team submitted as having actually done the work
        uint64 verificationDeadline;
    }

    // --- Constants ---------------------------------------------------------

    /// @notice Default verification window if `propose` is called with 0.
    uint64 public constant DEFAULT_VERIFICATION_WINDOW = 7 days;
    /// @notice Default execution window if `propose` is called with 0.
    uint64 public constant DEFAULT_EXECUTION_WINDOW = 30 days;
    /// @notice Fixed voting window: unlike the verification/execution windows,
    ///         the vote's own duration is not a per-proposal parameter.
    uint64 public constant VOTING_DURATION = 3 days;
    /// @notice Quorum expressed in basis points of the electorate snapshot
    ///         (10%), identical to ParticipatoryBudget.QUORUM_BPS. Design
    ///         choice: this replaces the previous low absolute-voter quorum
    ///         with a percentage threshold, for consistency with the public
    ///         flow's quorum metric.
    uint256 public constant QUORUM_BPS = 1_000;
    /// @notice Basis-point denominator, identical to
    ///         ParticipatoryBudget.BPS_DENOMINATOR.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Reputation increment granted to every confirmed performer,
    ///         identical regardless of the project's credit allocation.
    /// @dev Calibrated against Reputation's lazy linear decay, not chosen in
    ///      isolation: a single increment fully decays in
    ///      REPUTATION_INCREMENT / decayRatePerDay days. At a reference
    ///      decayRatePerDay of 1 point/day, 120 gives a ~4-month (120-day)
    ///      memory window -- long enough that a citizen confirming roughly
    ///      one project a month keeps most of their standing between
    ///      confirmations, instead of decaying back to 0 every cycle.
    ///      (demo-privato.sh currently deploys Reputation with
    ///      decayRatePerDay = 0, i.e. no decay at all, for demo stability --
    ///      this constant's calibration target is independent of that and
    ///      matters again as soon as Reputation is deployed with nonzero
    ///      decay.) Redeploying Reputation with a different decayRatePerDay
    ///      changes this window; keep the two in step.
    uint256 public constant REPUTATION_INCREMENT = 120;

    // --- Immutable dependencies ---------------------------------------------

    ICitizenshipSBTView public immutable citizenship;
    ICommunityCredit public immutable communityCredit;
    IProofOfParticipation public immutable proofOfParticipation;
    IReputation public immutable reputation;
    IJury public immutable jury;

    // --- Storage -------------------------------------------------------------

    uint256 public projectCount;
    mapping(uint256 => Project) private _projects;

    // projectId => address => is a member of the proposed team
    mapping(uint256 => mapping(address => bool)) public isTeamMember;
    // projectId => address => has given binding on-chain consent
    mapping(uint256 => mapping(address => bool)) public hasConsented;
    // projectId => address => has already cast a vote
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    // projectId => address => was submitted as an actual performer
    mapping(uint256 => mapping(address => bool)) public isPerformer;

    // --- Events --------------------------------------------------------------

    event ProjectProposed(
        uint256 indexed projectId,
        address indexed proposer,
        string description,
        address[] team,
        uint256 creditAllocation,
        uint256 budgetEuro,
        uint64 verificationWindow,
        uint64 executionWindow
    );
    event TeamConsentGiven(uint256 indexed projectId, address indexed member);
    event VotingOpened(uint256 indexed projectId, uint64 votingEnd);
    event VoteCast(uint256 indexed projectId, address indexed voter, bool support);
    event ProjectFunded(uint256 indexed projectId, uint64 executionDeadline);
    event ProjectArchived(uint256 indexed projectId);
    event EvidenceSubmitted(
        uint256 indexed projectId,
        address indexed submitter,
        string ipfsHash,
        address[] performers,
        uint64 verificationDeadline
    );
    event ProjectChallenged(uint256 indexed projectId, address indexed challenger);
    event ProjectConfirmed(uint256 indexed projectId);
    /// @notice Accounting base for the off-chain legal interface: the euro
    ///         amount itself was never on-chain, so this event carries only
    ///         what is needed to look it up off-chain (project, proposer,
    ///         how many performers it must be apportioned to, and when).
    event ReimbursementDue(
        uint256 indexed projectId, address indexed proposer, uint256 performerCount, uint256 timestamp
    );
    event ProjectRejected(uint256 indexed projectId, address indexed juror);
    event ProjectExpired(uint256 indexed projectId);

    // --- Errors --------------------------------------------------------------

    error NotCitizen();
    error EmptyTeam();
    error DuplicateTeamMember();
    error TeamMemberNotCitizen();
    error InvalidProject();
    error InvalidStatus();
    error NotTeamMember();
    error AlreadyConsented();
    error VotingWindowClosed();
    error VotingStillOpen();
    error AlreadyVoted();
    error ExecutionWindowElapsed();
    error ExecutionWindowNotElapsed();
    error EmptyPerformers();
    error PerformerNotInTeam();
    error DuplicatePerformer();
    error VerificationWindowClosed();
    error VerificationWindowOpen();
    error NotJuror();

    // --- Constructor -----------------------------------------------------

    constructor(
        address citizenshipSBT,
        address communityCredit_,
        address proofOfParticipation_,
        address reputation_,
        address jury_
    ) {
        citizenship = ICitizenshipSBTView(citizenshipSBT);
        communityCredit = ICommunityCredit(communityCredit_);
        proofOfParticipation = IProofOfParticipation(proofOfParticipation_);
        reputation = IReputation(reputation_);
        jury = IJury(jury_);
    }

    // --- Citizen: propose a project ---------------------------------------

    /// @notice Proposes a civic project together with its team, the community
    ///         credit earmarked for it, a declared euro cost estimate, and
    ///         the two time windows.
    /// @dev The team is fixed at proposal time; membership cannot be edited
    ///      afterwards. Every team member must already be a citizen (same
    ///      eligibility bar as the proposer and as voters).
    /// @param budgetEuro Whole-euro cost estimate declared by the proposer,
    ///        for voters to judge the proposal by. Purely informational: not
    ///        paid, not enforced, not reconciled against anything on-chain --
    ///        the actual reimbursed amount comes from the receipts in the
    ///        evidence submitted later, not from this figure (see the
    ///        contract-level notice above).
    /// @param verificationWindow Seconds; 0 selects DEFAULT_VERIFICATION_WINDOW.
    /// @param executionWindow Seconds; 0 selects DEFAULT_EXECUTION_WINDOW.
    function propose(
        string calldata description,
        address[] calldata team,
        uint256 creditAllocation,
        uint256 budgetEuro,
        uint64 verificationWindow,
        uint64 executionWindow
    ) external returns (uint256 projectId) {
        if (citizenship.balanceOf(msg.sender) == 0) revert NotCitizen();
        if (team.length == 0) revert EmptyTeam();

        projectId = projectCount++;
        Project storage p = _projects[projectId];
        p.proposer = msg.sender;
        p.description = description;
        p.creditAllocation = creditAllocation;
        p.budgetEuro = budgetEuro;
        p.verificationWindow = verificationWindow == 0 ? DEFAULT_VERIFICATION_WINDOW : verificationWindow;
        p.executionWindow = executionWindow == 0 ? DEFAULT_EXECUTION_WINDOW : executionWindow;
        p.status = Status.Proposed;

        for (uint256 i = 0; i < team.length; i++) {
            address member = team[i];
            if (citizenship.balanceOf(member) == 0) revert TeamMemberNotCitizen();
            if (isTeamMember[projectId][member]) revert DuplicateTeamMember();
            isTeamMember[projectId][member] = true;
            p.team.push(member);
        }

        emit ProjectProposed(
            projectId,
            msg.sender,
            description,
            team,
            creditAllocation,
            budgetEuro,
            p.verificationWindow,
            p.executionWindow
        );
    }

    // --- Team: binding on-chain consent, required before the vote --------

    /// @notice A team member commits on-chain to the project. Voting can only
    ///         start once every team member has consented: the community
    ///         votes on a team that is real and already committed, never on
    ///         a merely aspirational one.
    /// @dev Auto-advances Proposed -> Voting the moment the last member
    ///      consents, opening the fixed-length voting window right then.
    function consentToTeam(uint256 projectId) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Proposed) revert InvalidStatus();
        if (!isTeamMember[projectId][msg.sender]) revert NotTeamMember();
        if (hasConsented[projectId][msg.sender]) revert AlreadyConsented();

        hasConsented[projectId][msg.sender] = true;
        p.consentCount++;
        emit TeamConsentGiven(projectId, msg.sender);

        if (p.consentCount == p.team.length) {
            p.status = Status.Voting;
            p.votingEnd = uint64(block.timestamp) + VOTING_DURATION;
            p.electorate = citizenship.totalSupply(); // snapshot, as in ParticipatoryBudget.openRound
            emit VotingOpened(projectId, p.votingEnd);
        }
    }

    // --- Citizen: binding vote ---------------------------------------------

    /// @notice Casts a one-person-one-vote, one-shot ballot (yes/no) on a
    ///         project whose team has already fully consented.
    function vote(uint256 projectId, bool support) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Voting) revert InvalidStatus();
        if (block.timestamp > p.votingEnd) revert VotingWindowClosed();
        if (citizenship.balanceOf(msg.sender) == 0) revert NotCitizen();
        if (hasVoted[projectId][msg.sender]) revert AlreadyVoted();

        hasVoted[projectId][msg.sender] = true;
        if (support) {
            p.votesFor++;
        } else {
            p.votesAgainst++;
        }
        p.voterCount++;

        emit VoteCast(projectId, msg.sender, support);
    }

    // --- Anyone: close the vote once its window has elapsed -----------------

    /// @notice Closes the vote and moves the project to Funded (quorum met and
    ///         a simple majority in favor) or Archived (otherwise). No money
    ///         moves on-chain either way: Funded is only the authorization
    ///         flag that starts the execution timer.
    /// @dev Permissionless, like ParticipatoryBudget.closeRound, so no single
    ///      actor can stall the flow by refusing to close it. The quorum
    ///      check itself mirrors ParticipatoryBudget.closeRound (same
    ///      basis-point formula, written without division to avoid
    ///      rounding), but unlike the public flow the outcome is binding
    ///      here: failing quorum sends the project to Archived rather than
    ///      merely being attested alongside an unconditional close.
    function closeVoting(uint256 projectId) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Voting) revert InvalidStatus();
        if (block.timestamp <= p.votingEnd) revert VotingStillOpen();

        bool quorumReached = p.voterCount * BPS_DENOMINATOR >= p.electorate * QUORUM_BPS;
        bool approved = quorumReached && p.votesFor > p.votesAgainst;
        if (approved) {
            p.status = Status.Funded;
            p.fundedAt = uint64(block.timestamp);
            p.executionDeadline = p.fundedAt + p.executionWindow;
            emit ProjectFunded(projectId, p.executionDeadline);
        } else {
            p.status = Status.Archived;
            emit ProjectArchived(projectId);
        }
    }

    // --- Team: submit evidence of execution ---------------------------------

    /// @notice Submits proof of completion (an IPFS hash) together with the
    ///         list of team members who actually performed the work.
    /// @dev `performers` must be a subset of the team (which, by construction,
    ///      already fully consented -- see `consentToTeam`). A member who
    ///      withdrew simply is not listed here: there is no separate withdraw
    ///      function, because `_settle` divides `creditAllocation` equally
    ///      among `performers.length`, not `team.length`, so an absent member
    ///      automatically redistributes their share to those who did perform
    ///      and mints no proof-of-participation for themselves.
    function submitEvidence(uint256 projectId, string calldata ipfsHash, address[] calldata performers) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Funded) revert InvalidStatus();
        if (!isTeamMember[projectId][msg.sender]) revert NotTeamMember();
        if (block.timestamp > p.executionDeadline) revert ExecutionWindowElapsed();
        if (performers.length == 0) revert EmptyPerformers();

        for (uint256 i = 0; i < performers.length; i++) {
            address performer = performers[i];
            if (!isTeamMember[projectId][performer]) revert PerformerNotInTeam();
            if (isPerformer[projectId][performer]) revert DuplicatePerformer();
            isPerformer[projectId][performer] = true;
            p.performers.push(performer);
        }

        p.evidenceIpfsHash = ipfsHash;
        p.status = Status.Submitted;
        p.verificationDeadline = uint64(block.timestamp) + p.verificationWindow;

        emit EvidenceSubmitted(projectId, msg.sender, ipfsHash, performers, p.verificationDeadline);
    }

    // --- Citizen: challenge within the verification window ------------------

    /// @notice Contests a submission. Resolution is handed to the jury.
    function challenge(uint256 projectId) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Submitted) revert InvalidStatus();
        if (citizenship.balanceOf(msg.sender) == 0) revert NotCitizen();
        if (block.timestamp > p.verificationDeadline) revert VerificationWindowClosed();

        p.status = Status.Challenged;
        emit ProjectChallenged(projectId, msg.sender);
    }

    // --- Anyone: optimistic confirmation --------------------------------

    /// @notice If nobody challenges within the verification window, anyone can
    ///         carry the project to Confirmed and trigger the mint effects.
    function confirmOptimistic(uint256 projectId) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp <= p.verificationDeadline) revert VerificationWindowOpen();

        _settle(projectId, p);
    }

    // --- Jury: resolve a challenge -------------------------------------------

    /// @notice Delivers the jury's verdict on a challenged submission.
    /// @param approve true -> Confirmed (mint effects run); false -> Rejected
    ///        (nothing is minted).
    function resolveChallenge(uint256 projectId, bool approve) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Challenged) revert InvalidStatus();
        if (!jury.isJuror(msg.sender)) revert NotJuror();

        if (approve) {
            _settle(projectId, p);
        } else {
            p.status = Status.Rejected;
            emit ProjectRejected(projectId, msg.sender);
        }
    }

    // --- Anyone: expire a funded project with no evidence --------------------

    /// @notice If the team never submits evidence within the execution
    ///         window, anyone can carry the project to Expired. Nothing is
    ///         minted; the (off-chain) reimbursement simply never fires.
    function expire(uint256 projectId) external {
        Project storage p = _getProject(projectId);
        if (p.status != Status.Funded) revert InvalidStatus();
        if (block.timestamp <= p.executionDeadline) revert ExecutionWindowNotElapsed();

        p.status = Status.Expired;
        emit ProjectExpired(projectId);
    }

    // --- Internal: confirmation effects (sez. 4.4.2 punto 8) -----------------

    /// @dev Status flips to Confirmed BEFORE any external call (checks-
    ///      effects-interactions), so a malicious mint/increase implementation
    ///      re-entering this contract finds every guarded function already
    ///      past this project's Submitted/Challenged status and reverting.
    ///      For each performer, three separate external calls are made (one
    ///      per interface) rather than any batch call, per the per-performer
    ///      / per-call design chosen for this flow.
    function _settle(uint256 projectId, Project storage p) internal {
        p.status = Status.Confirmed;

        uint256 n = p.performers.length; // > 0: enforced at submitEvidence
        // Equal split (sez. 4.7.2). Integer division: any remainder from a
        // non-exact division simply stays unminted (dust), not held anywhere.
        uint256 quota = p.creditAllocation / n;

        for (uint256 i = 0; i < n; i++) {
            address performer = p.performers[i];
            communityCredit.mint(performer, quota);
            proofOfParticipation.mint(performer, projectId);
            reputation.increase(performer, REPUTATION_INCREMENT);
        }

        emit ProjectConfirmed(projectId);
        emit ReimbursementDue(projectId, p.proposer, n, block.timestamp);
    }

    // --- Internal helper -------------------------------------------------

    function _getProject(uint256 projectId) internal view returns (Project storage) {
        if (projectId >= projectCount) revert InvalidProject();
        return _projects[projectId];
    }

    // --- Views -----------------------------------------------------------

    function getProject(uint256 projectId) external view returns (Project memory) {
        if (projectId >= projectCount) revert InvalidProject();
        return _projects[projectId];
    }

    /// @notice Convenience accessor returning only the status enum, so callers
    ///         (e.g. the demo script, via `cast call`) don't need to decode the
    ///         full `Project` tuple just to check where a project stands.
    function getStatus(uint256 projectId) external view returns (Status) {
        if (projectId >= projectCount) revert InvalidProject();
        return _projects[projectId].status;
    }
}
