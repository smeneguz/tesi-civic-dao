// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ParticipatoryBudget} from "../src/ParticipatoryBudget.sol";

/// @notice Minimal stand-in for CitizenshipSBT: only the two views the contract
///         under test depends on, plus mint/burn to shape the electorate.
contract MockCitizenshipSBT {
    mapping(address => uint256) private _balances;
    uint256 private _supply;

    function mint(address to) external {
        require(_balances[to] == 0, "already citizen");
        _balances[to] = 1;
        _supply += 1;
    }

    function burn(address from) external {
        require(_balances[from] == 1, "not a citizen");
        _balances[from] = 0;
        _supply -= 1;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function totalSupply() external view returns (uint256) {
        return _supply;
    }
}

contract ParticipatoryBudgetTest is Test {
    ParticipatoryBudget internal pb;
    MockCitizenshipSBT internal sc;

    address internal municipality = makeAddr("municipality");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger"); // holds no citizenship token

    uint64 internal constant DURATION = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000); // start from a realistic timestamp
        sc = new MockCitizenshipSBT();
        sc.mint(alice);
        sc.mint(bob);
        sc.mint(carol);
        pb = new ParticipatoryBudget(address(sc), municipality); // test contract is admin
    }

    // ---- helpers ------------------------------------------------------------

    function _threeCids() internal pure returns (string[] memory cids) {
        cids = new string[](3);
        cids[0] = "ipfs://p0";
        cids[1] = "ipfs://p1";
        cids[2] = "ipfs://p2";
    }

    function _openRound() internal returns (uint256 id) {
        vm.prank(municipality);
        id = pb.openRound(100, _threeCids(), DURATION);
    }

    function _single(uint256 pid, uint256 v)
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory vs)
    {
        ids = new uint256[](1);
        vs = new uint256[](1);
        ids[0] = pid;
        vs[0] = v;
    }

    function _pair(uint256 pid0, uint256 v0, uint256 pid1, uint256 v1)
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory vs)
    {
        ids = new uint256[](2);
        vs = new uint256[](2);
        ids[0] = pid0;
        vs[0] = v0;
        ids[1] = pid1;
        vs[1] = v1;
    }

    function _castSingle(address voter, uint256 id, uint256 pid, uint256 v) internal {
        (uint256[] memory ids, uint256[] memory vs) = _single(pid, v);
        vm.prank(voter);
        pb.castVotes(id, ids, vs);
    }

    /// @dev Fresh deployment with an electorate of exactly `n` citizens, used to
    ///      exercise the quorum arithmetic in isolation.
    function _freshWithElectorate(uint256 n)
        internal
        returns (ParticipatoryBudget pbx, address[] memory citizens)
    {
        MockCitizenshipSBT scx = new MockCitizenshipSBT();
        citizens = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address c = address(uint160(0xC0FFEE00 + i));
            scx.mint(c);
            citizens[i] = c;
        }
        pbx = new ParticipatoryBudget(address(scx), municipality);
    }

    function _openVoteClose() internal returns (uint256 id) {
        id = _openRound();
        _castSingle(alice, id, 0, 5);
        vm.warp(block.timestamp + DURATION + 1);
        pb.closeRound(id);
    }

    // ---- openRound ----------------------------------------------------------

    function test_OpenRound_Success() public {
        uint256 id = _openRound();
        ParticipatoryBudget.Round memory r = pb.getRound(id);

        assertEq(r.creditsPerVoter, 100);
        assertEq(r.proposalCount, 3);
        assertEq(r.electorate, 3); // snapshot of totalSupply at open
        assertEq(r.voterCount, 0);
        assertEq(uint256(r.status), uint256(ParticipatoryBudget.Status.Active));
        assertEq(r.start, uint64(block.timestamp));
        assertEq(r.end, uint64(block.timestamp) + DURATION);
        assertEq(pb.getProposal(id, 2).cid, "ipfs://p2");
    }

    function test_OpenRound_RevertWhen_NotMunicipality() public {
        // Fetch the role BEFORE pranking: vm.prank overrides the sender of only
        // the very next external call, and pb.MUNICIPALITY_ROLE() would otherwise
        // consume it itself, leaving openRound() to run as the test contract.
        bytes32 role = pb.MUNICIPALITY_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        pb.openRound(100, _threeCids(), DURATION);
    }

    function test_OpenRound_RevertWhen_ZeroCredits() public {
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.InvalidCredits.selector);
        pb.openRound(0, _threeCids(), DURATION);
    }

    function test_OpenRound_RevertWhen_NoProposals() public {
        string[] memory empty = new string[](0);
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.NoProposals.selector);
        pb.openRound(100, empty, DURATION);
    }

    // ---- castVotes: happy paths ---------------------------------------------

    function test_CastVotes_Success() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _pair(0, 6, 1, 8); // 36 + 64 = 100

        vm.prank(alice);
        pb.castVotes(id, ids, vs);

        assertEq(pb.getScore(id, 0), 6);
        assertEq(pb.getScore(id, 1), 8);
        assertEq(pb.creditsSpent(id, alice), 100);
        assertTrue(pb.hasVoted(id, alice));
        assertEq(pb.getRound(id).voterCount, 1);
    }

    function test_CastVotes_MaxConcentration() public {
        // sqrt(100) = 10 is the most votes a citizen can put on a single proposal
        uint256 id = _openRound();
        _castSingle(alice, id, 0, 10);
        assertEq(pb.getScore(id, 0), 10);
        assertEq(pb.creditsSpent(id, alice), 100);
    }

    function test_CastVotes_MultipleCitizens_ScoresAggregate() public {
        uint256 id = _openRound();
        _castSingle(alice, id, 0, 5);
        _castSingle(bob, id, 0, 3);
        assertEq(pb.getScore(id, 0), 8);
        assertEq(pb.getRound(id).voterCount, 2);
    }

    function test_CastVotes_AtDeadline_Succeeds() public {
        uint256 id = _openRound();
        vm.warp(pb.getRound(id).end); // exactly on the inclusive deadline
        _castSingle(alice, id, 0, 4);
        assertEq(pb.getScore(id, 0), 4);
    }

    // ---- castVotes: reverts -------------------------------------------------

    function test_CastVotes_RevertWhen_BudgetExceeded() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _pair(0, 7, 1, 8); // 49 + 64 = 113 > 100
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.BudgetExceeded.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_NotCitizen() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 1);
        vm.prank(stranger);
        vm.expectRevert(ParticipatoryBudget.NotCitizen.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_AlreadyVoted() public {
        uint256 id = _openRound();
        _castSingle(alice, id, 0, 3);
        (uint256[] memory ids, uint256[] memory vs) = _single(1, 3);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.AlreadyVoted.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_LengthMismatch() public {
        uint256 id = _openRound();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        uint256[] memory vs = new uint256[](1);
        vs[0] = 3;
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.LengthMismatch.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_EmptyBallot() public {
        uint256 id = _openRound();
        uint256[] memory ids = new uint256[](0);
        uint256[] memory vs = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.EmptyBallot.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_ProposalsNotSorted() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _pair(1, 3, 0, 3); // descending
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.ProposalsNotSorted.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_DuplicateProposal() public {
        // The anti-gaming case: listing the same proposal twice would let a voter
        // split n votes and pay less than n^2. The strictly-increasing rule blocks it.
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _pair(1, 3, 1, 3);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.ProposalsNotSorted.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_InvalidProposal() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _single(3, 1); // only ids 0..2 exist
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.InvalidProposal.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_ZeroVotes() public {
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 0);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.ZeroVotes.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_WindowClosed() public {
        uint256 id = _openRound();
        vm.warp(pb.getRound(id).end + 1);
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 1);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.VotingWindowClosed.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_RoundClosed() public {
        uint256 id = _openRound();
        vm.warp(block.timestamp + DURATION + 1);
        pb.closeRound(id);
        // status check fires before the window check
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 1);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.RoundNotActive.selector);
        pb.castVotes(id, ids, vs);
    }

    function test_CastVotes_RevertWhen_InvalidRound() public {
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 1);
        vm.prank(alice);
        vm.expectRevert(ParticipatoryBudget.InvalidRound.selector);
        pb.castVotes(999, ids, vs);
    }

    // ---- closeRound + quorum ------------------------------------------------

    function test_CloseRound_QuorumReached_AtBoundary() public {
        // electorate 10, 1 voter => 1*10000 >= 10*1000 (10000 == 10000) => reached
        (ParticipatoryBudget pbx, address[] memory cs) = _freshWithElectorate(10);
        vm.prank(municipality);
        uint256 id = pbx.openRound(100, _threeCids(), DURATION);
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 4);
        vm.prank(cs[0]);
        pbx.castVotes(id, ids, vs);

        vm.warp(block.timestamp + DURATION + 1);
        pbx.closeRound(id);
        assertTrue(pbx.getRound(id).quorumReached);
    }

    function test_CloseRound_QuorumNotReached() public {
        // electorate 20, 1 voter => 10000 < 20000 => not reached
        (ParticipatoryBudget pbx, address[] memory cs) = _freshWithElectorate(20);
        vm.prank(municipality);
        uint256 id = pbx.openRound(100, _threeCids(), DURATION);
        (uint256[] memory ids, uint256[] memory vs) = _single(0, 4);
        vm.prank(cs[0]);
        pbx.castVotes(id, ids, vs);

        vm.warp(block.timestamp + DURATION + 1);
        pbx.closeRound(id);
        assertFalse(pbx.getRound(id).quorumReached);
    }

    function test_CloseRound_Permissionless() public {
        uint256 id = _openRound();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(stranger); // anyone can close once the window elapsed
        pb.closeRound(id);
        assertEq(uint256(pb.getRound(id).status), uint256(ParticipatoryBudget.Status.Closed));
    }

    function test_CloseRound_RevertWhen_StillOpen() public {
        uint256 id = _openRound();
        vm.expectRevert(ParticipatoryBudget.RoundStillOpen.selector);
        pb.closeRound(id);
    }

    function test_CloseRound_RevertWhen_AlreadyClosed() public {
        uint256 id = _openRound();
        vm.warp(block.timestamp + DURATION + 1);
        pb.closeRound(id);
        vm.expectRevert(ParticipatoryBudget.RoundNotActive.selector);
        pb.closeRound(id);
    }

    function test_CloseRound_RevertWhen_InvalidRound() public {
        vm.expectRevert(ParticipatoryBudget.InvalidRound.selector);
        pb.closeRound(999);
    }

    // ---- recordOutcome: duty to give reasons --------------------------------

    function test_RecordOutcome_Executed_NoReasonsNeeded() public {
        uint256 id = _openVoteClose();
        vm.prank(municipality);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.Executed, "");
        assertEq(uint256(pb.getProposal(id, 0).outcome), uint256(ParticipatoryBudget.Outcome.Executed));
    }

    function test_RecordOutcome_NotExecuted_WithReasons() public {
        uint256 id = _openVoteClose();
        vm.prank(municipality);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.NotExecuted, "ipfs://reasons");
        ParticipatoryBudget.Proposal memory p = pb.getProposal(id, 0);
        assertEq(uint256(p.outcome), uint256(ParticipatoryBudget.Outcome.NotExecuted));
        assertEq(p.reasonsCid, "ipfs://reasons");
    }

    function test_RecordOutcome_RevertWhen_NotExecutedWithoutReasons() public {
        // the codified duty to give reasons: NotExecuted without a CID reverts
        uint256 id = _openVoteClose();
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.ReasonsRequired.selector);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.NotExecuted, "");
    }

    function test_RecordOutcome_RevertWhen_NotMunicipality() public {
        uint256 id = _openVoteClose();
        // Same reasoning as test_OpenRound_RevertWhen_NotMunicipality: read the
        // role before pranking so the prank isn't consumed by this view call.
        bytes32 role = pb.MUNICIPALITY_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.Executed, "");
    }

    function test_RecordOutcome_RevertWhen_RoundNotClosed() public {
        uint256 id = _openRound(); // still active
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.RoundNotClosed.selector);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.Executed, "");
    }

    function test_RecordOutcome_RevertWhen_PendingOutcome() public {
        uint256 id = _openVoteClose();
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.InvalidOutcome.selector);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.Pending, "");
    }

    function test_RecordOutcome_RevertWhen_AlreadyRecorded() public {
        uint256 id = _openVoteClose();
        vm.startPrank(municipality);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.Executed, "");
        vm.expectRevert(ParticipatoryBudget.OutcomeAlreadyRecorded.selector);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.NotExecuted, "ipfs://x");
        vm.stopPrank();
    }

    function test_RecordOutcome_RevertWhen_InvalidProposal() public {
        uint256 id = _openVoteClose();
        vm.prank(municipality);
        vm.expectRevert(ParticipatoryBudget.InvalidProposal.selector);
        pb.recordOutcome(id, 3, ParticipatoryBudget.Outcome.Executed, "");
    }

    // ---- fuzz: quadratic budget invariant -----------------------------------

    function testFuzz_QuadraticBudget(uint256 v0, uint256 v1) public {
        v0 = bound(v0, 1, 300);
        v1 = bound(v1, 1, 300);
        uint256 id = _openRound();
        (uint256[] memory ids, uint256[] memory vs) = _pair(0, v0, 1, v1);
        uint256 cost = v0 * v0 + v1 * v1;

        vm.prank(alice);
        if (cost > 100) {
            vm.expectRevert(ParticipatoryBudget.BudgetExceeded.selector);
            pb.castVotes(id, ids, vs);
        } else {
            pb.castVotes(id, ids, vs);
            assertEq(pb.creditsSpent(id, alice), cost);
        }
    }

    // ---- end-to-end: the Wednesday demo -------------------------------------

    function test_Demo_EndToEnd() public {
        uint256 id = _openRound();

        // three citizens vote; P0 comes out on top
        _castSingle(alice, id, 0, 10); // all-in on P0: 100 credits
        {
            (uint256[] memory ids, uint256[] memory vs) = _pair(0, 6, 1, 8); // P0 +6, P1 +8
            vm.prank(bob);
            pb.castVotes(id, ids, vs);
        }
        {
            (uint256[] memory ids, uint256[] memory vs) = _pair(1, 4, 2, 6); // P1 +4, P2 +6
            vm.prank(carol);
            pb.castVotes(id, ids, vs);
        }

        vm.warp(block.timestamp + DURATION + 1);
        pb.closeRound(id);

        // scores: P0 = 16, P1 = 12, P2 = 6 -> P0 is the community's choice
        assertEq(pb.getScore(id, 0), 16);
        assertEq(pb.getScore(id, 1), 12);
        assertEq(pb.getScore(id, 2), 6);

        // electorate 3, 3 voters -> quorum comfortably reached
        assertTrue(pb.getRound(id).quorumReached);

        // the Municipality departs from the vote on P0, attaching written reasons
        vm.prank(municipality);
        pb.recordOutcome(id, 0, ParticipatoryBudget.Outcome.NotExecuted, "ipfs://reasons-P0");
        assertEq(uint256(pb.getProposal(id, 0).outcome), uint256(ParticipatoryBudget.Outcome.NotExecuted));
    }
}
