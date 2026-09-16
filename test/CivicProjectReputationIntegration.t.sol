// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CivicProject} from "../src/CivicProject.sol";
import {Reputation} from "../src/Reputation.sol";
import {MockCitizenshipSBT, MockCommunityCredit, MockProofOfParticipation, MockJury} from "./mocks/CivicProjectMocks.sol";

/// @notice Integration test: CivicProject wired to the REAL Reputation
///         contract (not MockReputation). CommunityCredit, ProofOfParticipation
///         and Jury stay on the trivial call-recording mocks here on purpose,
///         to isolate what is under test: that CivicProject's confirmation
///         effects (`_settle`) actually reach a real, standalone Reputation
///         contract and produce the expected on-chain score.
///
///         This does NOT replace CivicProjectEconomyIntegration.t.sol (real
///         economy, mocked Reputation) or CivicProject.t.sol (everything
///         mocked): both continue to use MockReputation unchanged, per the
///         thesis instructions -- existing CivicProject unit tests must keep
///         isolating the state machine, not be migrated onto the real
///         contract.
contract CivicProjectReputationIntegrationTest is Test {
    CivicProject internal cp;
    Reputation internal rep;
    MockCitizenshipSBT internal sbt;
    MockCommunityCredit internal credit;
    MockProofOfParticipation internal pop;
    MockJury internal jury;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // proposer
    address internal bob = makeAddr("bob"); // team + performer
    address internal carol = makeAddr("carol"); // team + performer
    address internal dave = makeAddr("dave"); // voter
    address internal elena = makeAddr("elena"); // voter

    uint256 internal constant ALLOCATION = 200;
    uint256 internal constant BUDGET_EURO = 800;
    uint256 internal constant DECAY_RATE_PER_DAY = 1;

    function setUp() public {
        vm.warp(1_700_000_000);

        sbt = new MockCitizenshipSBT();
        credit = new MockCommunityCredit();
        pop = new MockProofOfParticipation();
        jury = new MockJury();

        // The REAL Reputation contract, reading citizenship from the same
        // MockCitizenshipSBT used everywhere else in this test.
        rep = new Reputation(admin, address(sbt), DECAY_RATE_PER_DAY);

        cp = new CivicProject(address(sbt), address(credit), address(pop), address(rep), address(jury));

        // The role grant CivicProject needs to be allowed to call increase()
        // -- SCORER_ROLE, mirroring MINTER_ROLE on the economy contracts.
        // It is the DAO (governance, via CivicProject) that writes
        // reputation, never the admin/Comune directly.
        bytes32 scorerRole = rep.SCORER_ROLE();
        vm.prank(admin);
        rep.grantRole(scorerRole, address(cp));

        sbt.mint(alice);
        sbt.mint(bob);
        sbt.mint(carol);
        sbt.mint(dave);
        sbt.mint(elena);
    }

    function test_ConfirmedProject_IncreasesRealReputationForPerformers() public {
        address[] memory team = new address[](2);
        team[0] = bob;
        team[1] = carol;

        vm.prank(alice);
        uint256 id = cp.propose("Pulizia del parco", team, ALLOCATION, BUDGET_EURO, 0, 0);

        vm.prank(bob);
        cp.consentToTeam(id);
        vm.prank(carol);
        cp.consentToTeam(id);

        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(alice);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);

        address[] memory performers = new address[](2);
        performers[0] = bob;
        performers[1] = carol;
        vm.prank(bob);
        cp.submitEvidence(id, "ipfs://parco-pulito", performers);

        vm.warp(cp.getProject(id).verificationDeadline + 1);

        assertEq(rep.reputationOf(bob), 0);
        assertEq(rep.reputationOf(carol), 0);

        cp.confirmOptimistic(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Confirmed));

        uint256 increment = cp.REPUTATION_INCREMENT();
        assertEq(rep.reputationOf(bob), increment);
        assertEq(rep.reputationOf(carol), increment);
    }
}
