// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CivicProject} from "../src/CivicProject.sol";
import {CommunityCredit} from "../src/CommunityCredit.sol";
import {ProofOfParticipation} from "../src/ProofOfParticipation.sol";
import {MerchantMembership} from "../src/MerchantMembership.sol";
import {MockCitizenshipSBT, MockReputation, MockJury} from "./mocks/CivicProjectMocks.sol";

/// @notice Integration test: CivicProject wired to the REAL economy contracts
///         (CommunityCredit, ProofOfParticipation, MerchantMembership),
///         carrying one project to Confirmed and checking the performers
///         actually hold the right credit balance and PoP badge -- as opposed
///         to CivicProject.t.sol, which stays on the trivial call-recording
///         mocks on purpose, to isolate the state machine from the economy.
///         Reputation and IJury remain mocked here too: they are not yet
///         implemented (only CommunityCredit and ProofOfParticipation are).
contract CivicProjectEconomyIntegrationTest is Test {
    CivicProject internal cp;
    CommunityCredit internal credit;
    ProofOfParticipation internal pop;
    MerchantMembership internal mm;
    MockCitizenshipSBT internal sbt;
    MockReputation internal rep;
    MockJury internal jury;

    address internal admin = makeAddr("admin");
    address internal ets = makeAddr("ets");
    address internal alice = makeAddr("alice"); // proposer
    address internal bob = makeAddr("bob"); // team + performer
    address internal carol = makeAddr("carol"); // team + performer
    address internal dave = makeAddr("dave"); // voter
    address internal elena = makeAddr("elena"); // voter
    address internal bar = makeAddr("bar"); // active merchant

    uint256 internal constant ALLOCATION = 200;
    uint256 internal constant BUDGET_EURO = 800;

    function setUp() public {
        vm.warp(1_700_000_000);

        // Real economy: MerchantMembership underlies CommunityCredit's
        // transfer restriction; both CommunityCredit and ProofOfParticipation
        // are the real contracts under test here.
        mm = new MerchantMembership(admin, ets);
        credit = new CommunityCredit(admin, address(mm));
        pop = new ProofOfParticipation(admin);

        // Reputation and Jury are not yet implemented: still mocks.
        sbt = new MockCitizenshipSBT();
        rep = new MockReputation();
        jury = new MockJury();

        cp = new CivicProject(address(sbt), address(credit), address(pop), address(rep), address(jury));

        // Grant CivicProject minting rights on both real economy contracts --
        // exactly the role-grant step the deploy script performs, done here
        // directly against the already-deployed contracts.
        vm.startPrank(admin);
        credit.grantRole(credit.MINTER_ROLE(), address(cp));
        pop.grantRole(pop.MINTER_ROLE(), address(cp));
        vm.stopPrank();

        sbt.mint(alice);
        sbt.mint(bob);
        sbt.mint(carol);
        sbt.mint(dave);
        sbt.mint(elena);

        vm.prank(ets);
        mm.mint(bar); // an active merchant, for the post-confirmation spend check
    }

    function test_ConfirmedProject_MintsRealCreditAndPoP() public {
        address[] memory team = new address[](2);
        team[0] = bob;
        team[1] = carol;

        vm.prank(alice);
        uint256 id = cp.propose("Pulizia del parco", team, ALLOCATION, BUDGET_EURO, 0, 0);

        vm.prank(bob);
        cp.consentToTeam(id);
        vm.prank(carol);
        cp.consentToTeam(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Voting));

        vm.prank(dave);
        cp.vote(id, true);
        vm.prank(elena);
        cp.vote(id, true);
        vm.prank(alice);
        cp.vote(id, true);
        vm.warp(block.timestamp + cp.VOTING_DURATION() + 1);
        cp.closeVoting(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Funded));

        address[] memory performers = new address[](2);
        performers[0] = bob;
        performers[1] = carol;
        vm.prank(bob);
        cp.submitEvidence(id, "ipfs://parco-pulito", performers);

        vm.warp(cp.getProject(id).verificationDeadline + 1);

        assertEq(credit.balanceOf(bob), 0);
        assertEq(credit.balanceOf(carol), 0);
        assertEq(pop.balanceOf(bob), 0);
        assertEq(pop.balanceOf(carol), 0);

        cp.confirmOptimistic(id);
        assertEq(uint256(cp.getProject(id).status), uint256(CivicProject.Status.Confirmed));

        // Real credit balances: equal split, ALLOCATION / performers.length.
        uint256 quota = ALLOCATION / performers.length;
        assertEq(credit.balanceOf(bob), quota);
        assertEq(credit.balanceOf(carol), quota);
        assertEq(credit.totalSupply(), quota * 2);

        // Real PoP badges: one each, tied to this project.
        assertEq(pop.balanceOf(bob), 1);
        assertEq(pop.balanceOf(carol), 1);
        uint256 bobTokenId = 1;
        uint256 carolTokenId = 2;
        assertEq(pop.ownerOf(bobTokenId), bob);
        assertEq(pop.ownerOf(carolTokenId), carol);
        (uint256 bobProjectId, uint64 bobMintedAt) = pop.tokenData(bobTokenId);
        (uint256 carolProjectId, uint64 carolMintedAt) = pop.tokenData(carolTokenId);
        assertEq(bobProjectId, id);
        assertEq(carolProjectId, id);
        assertEq(bobMintedAt, uint64(block.timestamp));
        assertEq(carolMintedAt, uint64(block.timestamp));

        // The real closed-circuit restriction: Bob can spend his credit at an
        // active merchant, but not send it to another citizen (Carol).
        vm.prank(bob);
        credit.transfer(bar, quota);
        assertEq(credit.balanceOf(bob), 0);
        assertEq(credit.balanceOf(bar), quota);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, bob));
        credit.transfer(bob, 1);
    }
}
