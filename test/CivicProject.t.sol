// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CivicProject} from "../src/CivicProject.sol";
import {
    MockCitizenshipSBT,
    MockCommunityCredit,
    MockProofOfParticipation,
    MockReputation,
    MockJury
} from "./mocks/CivicProjectMocks.sol";

/// @notice Full-suite tests of CivicProject, the private-flow state machine
///         (thesis sez. 4.4.2, Fig. 4.5): propose -> team consent -> vote ->
///         (Funded | Archived) -> submit evidence -> optimistic confirmation
///         or challenge -> jury verdict -> (Confirmed | Rejected) | Expired.
contract CivicProjectTest is Test {
    CivicProject internal cp;
    MockCitizenshipSBT internal sbt;
    MockCommunityCredit internal credit;
    MockProofOfParticipation internal pop;
    MockReputation internal rep;
    MockJury internal jury;

    address internal alice = makeAddr("alice"); // proposer
    address internal bob = makeAddr("bob"); // team member
    address internal carol = makeAddr("carol"); // team member
    address internal dave = makeAddr("dave"); // citizen, not on the team
    address internal elena = makeAddr("elena"); // citizen, not on the team
    address internal frank = makeAddr("frank"); // citizen, not on the team
    address internal juror1 = makeAddr("juror1");
    address internal stranger = makeAddr("stranger"); // holds no citizenship

    uint64 internal constant VWINDOW = 7 days;
    uint64 internal constant EWINDOW = 30 days;
    uint256 internal constant ALLOCATION = 1000;
    uint256 internal constant BUDGET_EURO = 5000;

    function setUp() public {
        vm.warp(1_700_000_000);

        sbt = new MockCitizenshipSBT();
        credit = new MockCommunityCredit();
        pop = new MockProofOfParticipation();
        rep = new MockReputation();
        jury = new MockJury();

        cp = new CivicProject(address(sbt), address(credit), address(pop), address(rep), address(jury));

        // Electorate: alice (proposer), bob+carol (team), dave/elena/frank
        // (voting citizens off the team). stranger deliberately not minted.
        sbt.mint(alice);
        sbt.mint(bob);
        sbt.mint(carol);
        sbt.mint(dave);
        sbt.mint(elena);
        sbt.mint(frank);

        jury.setJuror(juror1, true);
    }

    // ---- helpers --------------------------------------------------------

    function _team() internal view returns (address[] memory team) {
        team = new address[](2);
        team[0] = bob;
        team[1] = carol;
    }

    function _propose() internal returns (uint256 id) {
        vm.prank(alice);
        id = cp.propose("Pulizia del parco", _team(), ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);
    }

    function _proposeAndConsent() internal returns (uint256 id) {
        id = _propose();
        vm.prank(bob);
        cp.consentToTeam(id);
        vm.prank(carol);
        cp.consentToTeam(id);
    }

    /// @dev Mints `n` extra citizens (not used anywhere else in the suite) so
    ///      a test can inflate the electorate to a chosen size before the
    ///      snapshot is taken. Addresses are picked well outside the range
    ///      makeAddr() produces, so collisions are not a concern.
    function _mintDummyCitizens(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            sbt.mint(address(uint160(0xD00D0000 + i)));
        }
    }

    /// @dev Reaches Voting, then 3 citizens vote yes (quorum met, majority yes),
    ///      then closes the vote -> Funded.
    function _reachFunded() internal returns (uint256 id) {
        id = _proposeAndConsent();
        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(frank);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
    }

    function _reachSubmitted() internal returns (uint256 id, address[] memory performers) {
        id = _reachFunded();
        performers = new address[](2);
        performers[0] = bob;
        performers[1] = carol;
        vm.prank(bob);
        cp.submitEvidence(id, "ipfs://evidence", performers);
    }

    // ---- propose ----------------------------------------------------------

    function test_Propose_Success() public {
        uint256 id = _propose();
        CivicProject.Project memory p = cp.getProject(id);

        assertEq(p.proposer, alice);
        assertEq(p.description, "Pulizia del parco");
        assertEq(p.team.length, 2);
        assertEq(p.team[0], bob);
        assertEq(p.team[1], carol);
        assertEq(p.creditAllocation, ALLOCATION);
        assertEq(p.verificationWindow, VWINDOW);
        assertEq(p.executionWindow, EWINDOW);
        assertEq(uint256(p.status), uint256(CivicProject.Status.Proposed));
        assertTrue(cp.isTeamMember(id, bob));
        assertTrue(cp.isTeamMember(id, carol));
    }

    function test_Propose_DefaultsWindowsWhenZero() public {
        vm.prank(alice);
        uint256 id = cp.propose("Progetto", _team(), ALLOCATION, BUDGET_EURO, 0, 0);
        CivicProject.Project memory p = cp.getProject(id);
        assertEq(p.verificationWindow, cp.DEFAULT_VERIFICATION_WINDOW());
        assertEq(p.executionWindow, cp.DEFAULT_EXECUTION_WINDOW());
    }

    function test_Propose_RevertWhen_NotCitizen() public {
        vm.prank(stranger);
        vm.expectRevert(CivicProject.NotCitizen.selector);
        cp.propose("x", _team(), ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);
    }

    function test_Propose_RevertWhen_EmptyTeam() public {
        address[] memory empty = new address[](0);
        vm.prank(alice);
        vm.expectRevert(CivicProject.EmptyTeam.selector);
        cp.propose("x", empty, ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);
    }

    function test_Propose_RevertWhen_TeamMemberNotCitizen() public {
        address[] memory team = new address[](1);
        team[0] = stranger;
        vm.prank(alice);
        vm.expectRevert(CivicProject.TeamMemberNotCitizen.selector);
        cp.propose("x", team, ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);
    }

    function test_Propose_RevertWhen_DuplicateTeamMember() public {
        address[] memory team = new address[](2);
        team[0] = bob;
        team[1] = bob;
        vm.prank(alice);
        vm.expectRevert(CivicProject.DuplicateTeamMember.selector);
        cp.propose("x", team, ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);
    }

    // ---- consentToTeam ------------------------------------------------------

    function test_ConsentToTeam_PartialDoesNotOpenVoting() public {
        uint256 id = _propose();
        vm.prank(bob);
        cp.consentToTeam(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Proposed));
        assertEq(cp.getProject(id).consentCount, 1);
    }

    function test_ConsentToTeam_LastMemberOpensVoting() public {
        uint256 id = _proposeAndConsent();
        CivicProject.Project memory p = cp.getProject(id);
        assertEq(uint256(p.status), uint256(CivicProject.Status.Voting));
        assertEq(p.votingEnd, uint64(block.timestamp) + cp.VOTING_DURATION());
    }

    function test_ConsentToTeam_RevertWhen_NotTeamMember() public {
        uint256 id = _propose();
        vm.prank(dave);
        vm.expectRevert(CivicProject.NotTeamMember.selector);
        cp.consentToTeam(id);
    }

    function test_ConsentToTeam_RevertWhen_AlreadyConsented() public {
        uint256 id = _propose();
        vm.startPrank(bob);
        cp.consentToTeam(id);
        vm.expectRevert(CivicProject.AlreadyConsented.selector);
        cp.consentToTeam(id);
        vm.stopPrank();
    }

    function test_ConsentToTeam_RevertWhen_WrongStatus() public {
        // Once voting has opened, consent can no longer be given (or re-given).
        uint256 id = _proposeAndConsent();
        vm.prank(bob);
        vm.expectRevert(CivicProject.InvalidStatus.selector);
        cp.consentToTeam(id);
    }

    // ---- vote: gating on team consent --------------------------------------

    function test_Vote_RevertWhen_TeamHasNotFullyConsentedYet() public {
        uint256 id = _propose(); // no consent at all yet: still Proposed
        vm.prank(dave);
        vm.expectRevert(CivicProject.InvalidStatus.selector);
        cp.vote(id, true);
    }

    function test_Vote_Success_OnePersonOneVote() public {
        uint256 id = _proposeAndConsent();
        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, false);

        CivicProject.Project memory p = cp.getProject(id);
        assertEq(p.votesFor, 1);
        assertEq(p.votesAgainst, 1);
        assertEq(p.voterCount, 2);
        assertTrue(cp.hasVoted(id, dave));
    }

    function test_Vote_RevertWhen_NotCitizen() public {
        uint256 id = _proposeAndConsent();
        vm.prank(stranger);
        vm.expectRevert(CivicProject.NotCitizen.selector);
        cp.vote(id, true);
    }

    function test_Vote_RevertWhen_AlreadyVoted() public {
        uint256 id = _proposeAndConsent();
        vm.startPrank(dave);
        cp.vote(id, true);
        vm.expectRevert(CivicProject.AlreadyVoted.selector);
        cp.vote(id, true);
        vm.stopPrank();
    }

    function test_Vote_RevertWhen_WindowClosed() public {
        uint256 id = _proposeAndConsent();
        vm.warp(cp.getProject(id).votingEnd + 1);
        vm.prank(dave);
        vm.expectRevert(CivicProject.VotingWindowClosed.selector);
        cp.vote(id, true);
    }

    // ---- closeVoting: quorum + majority --------------------------------

    function test_CloseVoting_ApprovedGoesToFunded() public {
        uint256 id = _reachFunded();
        CivicProject.Project memory p = cp.getProject(id);
        assertEq(uint256(p.status), uint256(CivicProject.Status.Funded));
        assertEq(p.fundedAt, uint64(block.timestamp));
        assertEq(p.executionDeadline, uint64(block.timestamp) + EWINDOW);
    }

    function test_CloseVoting_QuorumNotMet_GoesToArchived() public {
        // Inflate the electorate to 21 (6 default citizens + 15 dummies)
        // before the snapshot, so 2 voters (9.5%) fall short of the 10%
        // quorum even though both vote yes (majority would otherwise pass).
        uint256 id = _propose();
        vm.prank(bob);
        cp.consentToTeam(id);
        _mintDummyCitizens(15);
        vm.prank(carol);
        cp.consentToTeam(id); // last consent: snapshot taken here, electorate = 21

        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Archived));
    }

    function test_CloseVoting_QuorumExactlyMet_GoesToFunded() public {
        // Electorate = 10 (6 default + 4 dummies), 1 voter: 1*10000 == 10*1000,
        // the boundary case for the inclusive `>=` comparison.
        uint256 id = _propose();
        vm.prank(bob);
        cp.consentToTeam(id);
        _mintDummyCitizens(4);
        vm.prank(carol);
        cp.consentToTeam(id); // electorate = 10

        assertEq(cp.getProject(id).electorate, 10);

        vm.prank(dave);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));
    }

    function test_CloseVoting_QuorumJustBelowThreshold_GoesToArchived() public {
        // Electorate = 11 (6 default + 5 dummies), 1 voter: 1*10000 < 11*1000,
        // one unit below the boundary tested above.
        uint256 id = _propose();
        vm.prank(bob);
        cp.consentToTeam(id);
        _mintDummyCitizens(5);
        vm.prank(carol);
        cp.consentToTeam(id); // electorate = 11

        assertEq(cp.getProject(id).electorate, 11);

        vm.prank(dave);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Archived));
    }

    function test_CloseVoting_ElectorateSnapshotUnaffectedByLaterMints() public {
        // Snapshot is 6 at Voting-open time. Afterwards, mint enough extra
        // citizens that the *live* totalSupply would fail quorum for 3
        // voters (3*10000 < 31*1000), then show the project is still Funded
        // because closeVoting reads the frozen snapshot, not totalSupply().
        uint256 id = _proposeAndConsent();
        assertEq(cp.getProject(id).electorate, 6);

        _mintDummyCitizens(25); // sbt.totalSupply() now 31
        assertEq(sbt.totalSupply(), 31);
        assertEq(cp.getProject(id).electorate, 6); // snapshot untouched

        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(frank);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);

        // 3 voters against the frozen electorate of 6 (50%) clears 10%;
        // against the live totalSupply of 31 (9.7%) it would not have.
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));
        assertEq(cp.getProject(id).electorate, 6);
    }

    function test_CloseVoting_MajorityAgainst_GoesToArchived() public {
        uint256 id = _proposeAndConsent();
        vm.prank(dave);
        cp.vote(id, false);
        vm.prank(elena);
        cp.vote(id, false);
        vm.prank(frank);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Archived));
    }

    function test_CloseVoting_RevertWhen_StillOpen() public {
        uint256 id = _proposeAndConsent();
        vm.expectRevert(CivicProject.VotingStillOpen.selector);
        cp.closeVoting(id);
    }

    function test_CloseVoting_Permissionless() public {
        uint256 id = _proposeAndConsent();
        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(frank);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        vm.prank(stranger); // anyone can close
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));
    }

    // ---- submitEvidence -------------------------------------------------

    function test_SubmitEvidence_Success() public {
        (uint256 id, address[] memory performers) = _reachSubmitted();
        CivicProject.Project memory p = cp.getProject(id);
        assertEq(uint256(p.status), uint256(CivicProject.Status.Submitted));
        assertEq(p.evidenceIpfsHash, "ipfs://evidence");
        assertEq(p.performers.length, performers.length);
        assertEq(p.verificationDeadline, uint64(block.timestamp) + VWINDOW);
    }

    function test_SubmitEvidence_RevertWhen_NotTeamMember() public {
        uint256 id = _reachFunded();
        address[] memory performers = new address[](1);
        performers[0] = bob;
        vm.prank(dave); // citizen but not on the team
        vm.expectRevert(CivicProject.NotTeamMember.selector);
        cp.submitEvidence(id, "ipfs://x", performers);
    }

    function test_SubmitEvidence_RevertWhen_PerformerNotInTeam() public {
        uint256 id = _reachFunded();
        address[] memory performers = new address[](1);
        performers[0] = dave; // citizen, but never joined this project's team
        vm.prank(bob);
        vm.expectRevert(CivicProject.PerformerNotInTeam.selector);
        cp.submitEvidence(id, "ipfs://x", performers);
    }

    function test_SubmitEvidence_RevertWhen_DuplicatePerformer() public {
        uint256 id = _reachFunded();
        address[] memory performers = new address[](2);
        performers[0] = bob;
        performers[1] = bob;
        vm.prank(bob);
        vm.expectRevert(CivicProject.DuplicatePerformer.selector);
        cp.submitEvidence(id, "ipfs://x", performers);
    }

    function test_SubmitEvidence_RevertWhen_EmptyPerformers() public {
        uint256 id = _reachFunded();
        address[] memory performers = new address[](0);
        vm.prank(bob);
        vm.expectRevert(CivicProject.EmptyPerformers.selector);
        cp.submitEvidence(id, "ipfs://x", performers);
    }

    function test_SubmitEvidence_RevertWhen_ExecutionWindowElapsed() public {
        uint256 id = _reachFunded();
        vm.warp(cp.getProject(id).executionDeadline + 1);
        address[] memory performers = new address[](1);
        performers[0] = bob;
        vm.prank(bob);
        vm.expectRevert(CivicProject.ExecutionWindowElapsed.selector);
        cp.submitEvidence(id, "ipfs://x", performers);
    }

    // ---- optimistic path: confirmOptimistic --------------------------------

    function test_ConfirmOptimistic_RevertWhen_WindowStillOpen() public {
        (uint256 id,) = _reachSubmitted();
        vm.expectRevert(CivicProject.VerificationWindowOpen.selector);
        cp.confirmOptimistic(id);
    }

    function test_ConfirmOptimistic_Success_MintsForEveryPerformer() public {
        (uint256 id, address[] memory performers) = _reachSubmitted();
        vm.warp(cp.getProject(id).verificationDeadline + 1);

        vm.prank(stranger); // permissionless
        cp.confirmOptimistic(id);

        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Confirmed));

        uint256 expectedQuota = ALLOCATION / performers.length;
        assertEq(credit.callCount(), performers.length);
        assertEq(pop.callCount(), performers.length);
        assertEq(rep.callCount(), performers.length);

        for (uint256 i = 0; i < performers.length; i++) {
            (address creditTo, uint256 amount) = credit.calls(i);
            assertEq(creditTo, performers[i]);
            assertEq(amount, expectedQuota);

            (address popTo, uint256 projectId) = pop.calls(i);
            assertEq(popTo, performers[i]);
            assertEq(projectId, id);

            (address repTo, uint256 repAmount) = rep.calls(i);
            assertEq(repTo, performers[i]);
            assertEq(repAmount, cp.REPUTATION_INCREMENT()); // same amount for every performer
        }
    }

    function test_ConfirmOptimistic_EmitsReimbursementDue() public {
        (uint256 id, address[] memory performers) = _reachSubmitted();
        vm.warp(cp.getProject(id).verificationDeadline + 1);

        vm.expectEmit(true, true, false, true, address(cp));
        emit CivicProject.ReimbursementDue(id, alice, performers.length, block.timestamp);
        cp.confirmOptimistic(id);
    }

    function test_ConfirmOptimistic_RevertWhen_WrongStatus() public {
        uint256 id = _reachFunded(); // not yet Submitted
        vm.expectRevert(CivicProject.InvalidStatus.selector);
        cp.confirmOptimistic(id);
    }

    // ---- withdrawal: a team member simply isn't listed as a performer ------

    function test_Withdrawal_ShareRedistributedNoPopForWithdrawn() public {
        // 3-person team: all 3 must consent to reach Voting, but only 2 are
        // submitted as performers -- the third effectively "withdrew".
        address[] memory team = new address[](3);
        team[0] = bob;
        team[1] = carol;
        team[2] = frank;
        vm.prank(alice);
        uint256 id = cp.propose("Progetto a 3", team, ALLOCATION, BUDGET_EURO, VWINDOW, EWINDOW);

        vm.prank(bob);
        cp.consentToTeam(id);
        vm.prank(carol);
        cp.consentToTeam(id);
        vm.prank(frank);
        cp.consentToTeam(id); // frank consents to the team, but will not perform

        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(alice); // the proposer is also a citizen and may vote
        cp.vote(id, true); // 3 voters: quorum met
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));

        // Only bob and carol are submitted as performers: frank withdrew.
        address[] memory performers = new address[](2);
        performers[0] = bob;
        performers[1] = carol;
        vm.prank(bob);
        cp.submitEvidence(id, "ipfs://evidence", performers);

        vm.warp(cp.getProject(id).verificationDeadline + 1);
        cp.confirmOptimistic(id);

        // Quota redistributed over 2 performers, not 3.
        uint256 expectedQuota = ALLOCATION / 2;
        assertEq(credit.callCount(), 2);
        (address to0, uint256 amount0) = credit.calls(0);
        (address to1, uint256 amount1) = credit.calls(1);
        assertEq(to0, bob);
        assertEq(amount0, expectedQuota);
        assertEq(to1, carol);
        assertEq(amount1, expectedQuota);

        // frank received no proof-of-participation and no reputation.
        assertEq(pop.callCount(), 2);
        assertEq(rep.callCount(), 2);
        for (uint256 i = 0; i < 2; i++) {
            (address popTo,) = pop.calls(i);
            assertTrue(popTo != frank);
        }
    }

    // ---- challenge -> jury -------------------------------------------------

    function test_Challenge_MovesToChallenged() public {
        (uint256 id,) = _reachSubmitted();
        vm.prank(dave);
        cp.challenge(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Challenged));
    }

    function test_Challenge_RevertWhen_NotCitizen() public {
        (uint256 id,) = _reachSubmitted();
        vm.prank(stranger);
        vm.expectRevert(CivicProject.NotCitizen.selector);
        cp.challenge(id);
    }

    function test_Challenge_RevertWhen_WindowClosed() public {
        (uint256 id,) = _reachSubmitted();
        vm.warp(cp.getProject(id).verificationDeadline + 1);
        vm.prank(dave);
        vm.expectRevert(CivicProject.VerificationWindowClosed.selector);
        cp.challenge(id);
    }

    function test_ResolveChallenge_Approve_ConfirmsAndMints() public {
        (uint256 id, address[] memory performers) = _reachSubmitted();
        vm.prank(dave);
        cp.challenge(id);

        vm.prank(juror1);
        cp.resolveChallenge(id, true);

        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Confirmed));
        assertEq(credit.callCount(), performers.length);
        assertEq(pop.callCount(), performers.length);
        assertEq(rep.callCount(), performers.length);
    }

    function test_ResolveChallenge_Reject_NothingMinted() public {
        (uint256 id,) = _reachSubmitted();
        vm.prank(dave);
        cp.challenge(id);

        vm.prank(juror1);
        cp.resolveChallenge(id, false);

        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Rejected));
        assertEq(credit.callCount(), 0);
        assertEq(pop.callCount(), 0);
        assertEq(rep.callCount(), 0);
    }

    function test_ResolveChallenge_RevertWhen_NotJuror() public {
        (uint256 id,) = _reachSubmitted();
        vm.prank(dave);
        cp.challenge(id);

        vm.prank(dave); // a citizen, but not a juror
        vm.expectRevert(CivicProject.NotJuror.selector);
        cp.resolveChallenge(id, true);
    }

    function test_ResolveChallenge_RevertWhen_NotChallenged() public {
        (uint256 id,) = _reachSubmitted(); // Submitted, not Challenged
        vm.prank(juror1);
        vm.expectRevert(CivicProject.InvalidStatus.selector);
        cp.resolveChallenge(id, true);
    }

    // ---- expire -------------------------------------------------------------

    function test_Expire_Success() public {
        uint256 id = _reachFunded();
        vm.warp(cp.getProject(id).executionDeadline + 1);
        vm.prank(stranger); // permissionless
        cp.expire(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Expired));
        assertEq(credit.callCount(), 0);
        assertEq(pop.callCount(), 0);
        assertEq(rep.callCount(), 0);
    }

    function test_Expire_RevertWhen_NotElapsed() public {
        uint256 id = _reachFunded();
        vm.expectRevert(CivicProject.ExecutionWindowNotElapsed.selector);
        cp.expire(id);
    }

    function test_Expire_RevertWhen_WrongStatus() public {
        uint256 id = _proposeAndConsent(); // still Voting, not Funded
        vm.expectRevert(CivicProject.InvalidStatus.selector);
        cp.expire(id);
    }

    // ---- invalid project id --------------------------------------------

    function test_RevertWhen_InvalidProject() public {
        vm.expectRevert(CivicProject.InvalidProject.selector);
        cp.getProject(999);
    }

    // ---- end-to-end: optimistic path ---------------------------------------

    function test_Demo_OptimisticPath_EndToEnd() public {
        uint256 id = _proposeAndConsent();
        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(frank);
        cp.vote(id, false);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));

        address[] memory performers = new address[](2);
        performers[0] = bob;
        performers[1] = carol;
        vm.prank(carol);
        cp.submitEvidence(id, "ipfs://parco-pulito", performers);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Submitted));

        vm.warp(cp.getProject(id).verificationDeadline + 1);
        cp.confirmOptimistic(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Confirmed));

        assertEq(credit.callCount(), 2);
        assertEq(pop.callCount(), 2);
        assertEq(rep.callCount(), 2);
    }

    // ---- end-to-end: challenged -> rejected path ---------------------------

    function test_Demo_ChallengedRejectedPath_EndToEnd() public {
        (uint256 id,) = _reachSubmitted();
        vm.prank(elena);
        cp.challenge(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Challenged));

        vm.prank(juror1);
        cp.resolveChallenge(id, false);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Rejected));
        assertEq(credit.callCount(), 0);
        assertEq(pop.callCount(), 0);
        assertEq(rep.callCount(), 0);
    }
}
