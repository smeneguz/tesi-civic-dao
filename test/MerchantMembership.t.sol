// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerchantMembership} from "../src/MerchantMembership.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Unit tests for MerchantMembership, isolated from CommunityCredit
///         and CivicProject: only ISSUER_ROLE can certify a payment, a
///         certificate is non-transferable, and `isActiveMember` reflects the
///         rolling MEMBERSHIP_DURATION window from the last payment.
contract MerchantMembershipTest is Test {
    MerchantMembership internal mm;

    address internal admin = makeAddr("admin");
    address internal ets = makeAddr("ets"); // ISSUER_ROLE holder
    address internal bar = makeAddr("bar"); // a business
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = new MerchantMembership(admin, ets);
    }

    // ---- mint -------------------------------------------------------------

    function test_Mint_RevertWhen_NotIssuer() public {
        // Role fetched BEFORE the prank: `vm.prank` arms only the very next
        // external call, and mm.ISSUER_ROLE() would otherwise consume it as
        // an argument-evaluation call before mm.mint(bar) ever runs.
        bytes32 issuerRole = mm.ISSUER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, issuerRole));
        mm.mint(bar);
    }

    function test_Mint_Success_SetsLastPaidAtAndActivates() public {
        vm.prank(ets);
        uint256 tokenId = mm.mint(bar);

        assertEq(mm.ownerOf(tokenId), bar);
        assertEq(mm.lastPaidAt(bar), uint64(block.timestamp));
        assertTrue(mm.isActiveMember(bar));

        uint64 paidAt = mm.membershipData(tokenId);
        assertEq(paidAt, uint64(block.timestamp));
    }

    function test_Mint_Renewal_UpdatesLastPaidAt() public {
        vm.startPrank(ets);
        mm.mint(bar);
        vm.warp(block.timestamp + 200 days);
        uint256 secondTokenId = mm.mint(bar); // renewal: a second certificate
        vm.stopPrank();

        assertEq(mm.ownerOf(secondTokenId), bar);
        assertEq(mm.lastPaidAt(bar), uint64(block.timestamp));
        assertTrue(mm.isActiveMember(bar));
    }

    // ---- isActiveMember -----------------------------------------------------

    function test_IsActiveMember_FalseBeforeAnyPayment() public view {
        assertFalse(mm.isActiveMember(bar));
    }

    function test_IsActiveMember_FalseAfterMembershipDurationElapses() public {
        vm.prank(ets);
        mm.mint(bar);
        vm.warp(block.timestamp + mm.MEMBERSHIP_DURATION() + 1);
        assertFalse(mm.isActiveMember(bar));
    }

    function test_IsActiveMember_TrueAtExactBoundary() public {
        vm.prank(ets);
        mm.mint(bar);
        vm.warp(block.timestamp + mm.MEMBERSHIP_DURATION());
        assertTrue(mm.isActiveMember(bar));
    }

    // ---- soulbound ------------------------------------------------------

    function test_Transfer_Reverts() public {
        vm.prank(ets);
        uint256 tokenId = mm.mint(bar);

        vm.prank(bar);
        vm.expectRevert(MerchantMembership.NonTransferable.selector);
        mm.transferFrom(bar, stranger, tokenId);
    }

    // ---- reads on unknown token -------------------------------------------

    function test_MembershipData_RevertWhen_TokenDoesNotExist() public {
        vm.expectRevert(MerchantMembership.TokenDoesNotExist.selector);
        mm.membershipData(999);
    }
}
