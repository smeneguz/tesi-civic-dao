// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Reputation} from "../src/Reputation.sol";
import {MockCitizenshipSBT} from "./mocks/CivicProjectMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Unit tests for Reputation, standalone from CivicProject: role
///         gating, accumulation, lazy linear decay, crystallization on
///         write, and the threshold-based read (`hasReputation`).
contract ReputationTest is Test {
    Reputation internal rep;
    MockCitizenshipSBT internal sbt;

    address internal admin = makeAddr("admin");
    address internal scorer = makeAddr("scorer"); // stands in for CivicProject
    address internal citizen = makeAddr("citizen");
    address internal stranger = makeAddr("stranger"); // never minted citizenship

    uint256 internal constant RATE_PER_DAY = 2;

    function setUp() public {
        vm.warp(1_700_000_000);

        sbt = new MockCitizenshipSBT();
        rep = new Reputation(admin, address(sbt), RATE_PER_DAY);

        bytes32 scorerRole = rep.SCORER_ROLE();
        vm.prank(admin);
        rep.grantRole(scorerRole, scorer);

        sbt.mint(citizen);
    }

    // --- Access control ----------------------------------------------------

    function test_Increase_RevertWhen_NotScorer() public {
        bytes32 scorerRole = rep.SCORER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, scorerRole)
        );
        rep.increase(citizen, 10);
    }

    function test_Increase_RevertWhen_NotCitizen() public {
        vm.prank(scorer);
        vm.expectRevert(Reputation.NotCitizen.selector);
        rep.increase(stranger, 10);
    }

    // --- Accumulation --------------------------------------------------------

    function test_Increase_Accumulates() public {
        vm.startPrank(scorer);
        rep.increase(citizen, 10);
        rep.increase(citizen, 5);
        vm.stopPrank();

        assertEq(rep.reputationOf(citizen), 15);
    }

    // --- Decay ---------------------------------------------------------------

    function test_Decay_LinearOverElapsedDays() public {
        vm.prank(scorer);
        rep.increase(citizen, 20);

        vm.warp(block.timestamp + 3 days);
        // 20 - (RATE_PER_DAY * 3) = 20 - 6 = 14
        assertEq(rep.reputationOf(citizen), 20 - RATE_PER_DAY * 3);
    }

    function test_Decay_FloorsAtZero_NeverNegative() public {
        vm.prank(scorer);
        rep.increase(citizen, 5);

        // Far more days than needed to erase 5 points at RATE_PER_DAY=2.
        vm.warp(block.timestamp + 3650 days);
        assertEq(rep.reputationOf(citizen), 0);
    }

    function test_Decay_LessThanOneDay_NoEffectYet() public {
        vm.prank(scorer);
        rep.increase(citizen, 10);

        vm.warp(block.timestamp + 12 hours);
        assertEq(rep.reputationOf(citizen), 10);
    }

    // --- Crystallization on write --------------------------------------------

    function test_Crystallization_DecayAppliedBeforeSecondIncrease() public {
        vm.prank(scorer);
        rep.increase(citizen, 20); // raw = 20 @ t0

        vm.warp(block.timestamp + 2 days); // decayed to 20 - 4 = 16, but not yet written

        vm.prank(scorer);
        rep.increase(citizen, 10); // crystallize 16, then + 10 = 26

        (uint256 raw, uint64 updatedAt) = rep.rawScoreOf(citizen);
        assertEq(raw, 26);
        assertEq(updatedAt, uint64(block.timestamp));
        assertEq(rep.reputationOf(citizen), 26);

        // Further decay now runs from the NEW timestamp/value, not the old one.
        vm.warp(block.timestamp + 1 days);
        assertEq(rep.reputationOf(citizen), 26 - RATE_PER_DAY);
    }

    // --- Threshold -----------------------------------------------------------

    function test_HasReputation_TrueFalseAgainstThreshold() public {
        vm.prank(scorer);
        rep.increase(citizen, 10);

        assertTrue(rep.hasReputation(citizen, 10)); // inclusive threshold
        assertTrue(rep.hasReputation(citizen, 5));
        assertFalse(rep.hasReputation(citizen, 11));
    }

    function test_HasReputation_ChangesOutcomeAfterDecay() public {
        vm.prank(scorer);
        rep.increase(citizen, 10);

        assertTrue(rep.hasReputation(citizen, 10));

        vm.warp(block.timestamp + 3 days); // 10 - 6 = 4
        assertFalse(rep.hasReputation(citizen, 10));
        assertTrue(rep.hasReputation(citizen, 4));
    }
}
