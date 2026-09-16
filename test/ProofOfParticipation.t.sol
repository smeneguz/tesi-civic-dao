// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProofOfParticipation} from "../src/ProofOfParticipation.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Unit tests for ProofOfParticipation, isolated from CivicProject:
///         only MINTER_ROLE can mint, a badge is non-transferable, an address
///         can accumulate many badges, and `tokenData` returns the right
///         (projectId, mintedAt) pair.
contract ProofOfParticipationTest is Test {
    ProofOfParticipation internal pop;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter"); // stands in for CivicProject
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        pop = new ProofOfParticipation(admin);
        // Role fetched BEFORE the prank: see the comment in
        // test_Mint_RevertWhen_NotMinter for why this ordering matters.
        bytes32 minterRole = pop.MINTER_ROLE();
        vm.prank(admin);
        pop.grantRole(minterRole, minter);
    }

    // ---- mint -------------------------------------------------------------

    function test_Mint_RevertWhen_NotMinter() public {
        // Role fetched BEFORE the prank: `vm.prank` arms only the very next
        // external call, and pop.MINTER_ROLE() would otherwise consume it as
        // an argument-evaluation call before pop.mint(...) ever runs.
        bytes32 minterRole = pop.MINTER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, minterRole)
        );
        pop.mint(bob, 7);
    }

    function test_Mint_Success_SetsOwnerAndTokenData() public {
        vm.prank(minter);
        pop.mint(bob, 7);

        assertEq(pop.ownerOf(1), bob);
        (uint256 projectId, uint64 mintedAt) = pop.tokenData(1);
        assertEq(projectId, 7);
        assertEq(mintedAt, uint64(block.timestamp));
    }

    function test_Mint_AccumulatesManyPerAddress() public {
        vm.startPrank(minter);
        pop.mint(bob, 1);
        pop.mint(bob, 2);
        pop.mint(bob, 3);
        vm.stopPrank();

        assertEq(pop.balanceOf(bob), 3);
        (uint256 p1,) = pop.tokenData(1);
        (uint256 p2,) = pop.tokenData(2);
        (uint256 p3,) = pop.tokenData(3);
        assertEq(p1, 1);
        assertEq(p2, 2);
        assertEq(p3, 3);
    }

    function test_Mint_DoesNotTakeMintedAtFromCaller() public {
        // The interface signature has no timestamp parameter: mintedAt can
        // only ever be block.timestamp at call time, never backdated.
        vm.warp(1_800_000_000);
        vm.prank(minter);
        pop.mint(bob, 1);
        (, uint64 mintedAt) = pop.tokenData(1);
        assertEq(mintedAt, 1_800_000_000);
    }

    // ---- soulbound ------------------------------------------------------

    function test_Transfer_Reverts() public {
        vm.prank(minter);
        pop.mint(bob, 1);

        vm.prank(bob);
        vm.expectRevert(ProofOfParticipation.NonTransferable.selector);
        pop.transferFrom(bob, stranger, 1);
    }

    // ---- reads on unknown token -------------------------------------------

    function test_TokenData_RevertWhen_TokenDoesNotExist() public {
        vm.expectRevert(ProofOfParticipation.TokenDoesNotExist.selector);
        pop.tokenData(999);
    }
}
