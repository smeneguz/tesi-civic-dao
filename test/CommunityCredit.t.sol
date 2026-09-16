// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CommunityCredit} from "../src/CommunityCredit.sol";
import {MerchantMembership} from "../src/MerchantMembership.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Unit tests for CommunityCredit, isolated from CivicProject: only
///         MINTER_ROLE can mint, balances read back correctly, and transfers
///         succeed only towards an address MerchantMembership currently
///         reports as an active member -- in particular, citizen -> citizen
///         transfers always revert, since a citizen is never a merchant.
contract CommunityCreditTest is Test {
    CommunityCredit internal credit;
    MerchantMembership internal mm;

    address internal admin = makeAddr("admin");
    address internal ets = makeAddr("ets");
    address internal minter = makeAddr("minter"); // stands in for CivicProject
    address internal alice = makeAddr("alice"); // citizen
    address internal bob = makeAddr("bob"); // citizen
    address internal bar = makeAddr("bar"); // active merchant

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = new MerchantMembership(admin, ets);
        credit = new CommunityCredit(admin, address(mm));

        // Role fetched BEFORE the prank: see the comment in
        // test_Mint_RevertWhen_NotMinter for why this ordering matters.
        bytes32 minterRole = credit.MINTER_ROLE();
        vm.prank(admin);
        credit.grantRole(minterRole, minter);

        vm.prank(ets);
        mm.mint(bar);
    }

    // ---- mint -------------------------------------------------------------

    function test_Mint_RevertWhen_NotMinter() public {
        // Role fetched BEFORE the prank: `vm.prank` arms only the very next
        // external call, and credit.MINTER_ROLE() would otherwise consume it
        // as an argument-evaluation call before credit.mint(...) ever runs.
        bytes32 minterRole = credit.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole)
        );
        credit.mint(alice, 100);
    }

    function test_Mint_Success_CreditsBalance() public {
        vm.prank(minter);
        credit.mint(alice, 100);
        assertEq(credit.balanceOf(alice), 100);
        assertEq(credit.totalSupply(), 100);
    }

    // ---- transfer restriction -----------------------------------------------

    function test_Transfer_ToActiveMerchant_Succeeds() public {
        vm.prank(minter);
        credit.mint(alice, 100);

        vm.prank(alice);
        credit.transfer(bar, 40);

        assertEq(credit.balanceOf(alice), 60);
        assertEq(credit.balanceOf(bar), 40);
    }

    function test_Transfer_ToCitizen_Reverts() public {
        vm.prank(minter);
        credit.mint(alice, 100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, bob));
        credit.transfer(bob, 10);
    }

    function test_Transfer_ToExpiredMerchant_Reverts() public {
        vm.prank(minter);
        credit.mint(alice, 100);

        vm.warp(block.timestamp + mm.MEMBERSHIP_DURATION() + 1);
        assertFalse(mm.isActiveMember(bar));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, bar));
        credit.transfer(bar, 10);
    }

    function test_TransferFrom_ToCitizen_Reverts() public {
        vm.prank(minter);
        credit.mint(alice, 100);
        vm.prank(alice);
        credit.approve(bob, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, bob));
        credit.transferFrom(alice, bob, 10);
    }

    function test_Mint_DoesNotRequireRecipientToBeMerchant() public {
        // Mint (from == 0) is exempt from the merchant check: CivicProject
        // mints straight to citizen-performers, never to a merchant.
        vm.prank(minter);
        credit.mint(alice, 100);
        assertEq(credit.balanceOf(alice), 100);
    }

    // ---- redeem: closed-circuit stage 3 ------------------------------------

    function test_Redeem_Success_BurnsAndEmits() public {
        vm.prank(minter);
        credit.mint(alice, 100);
        vm.prank(alice);
        credit.transfer(bar, 40); // stage 2: bar now holds 40

        vm.expectEmit(true, false, false, true, address(credit));
        emit CommunityCredit.Redeemed(bar, 40);

        vm.prank(bar);
        credit.redeem(40);

        assertEq(credit.balanceOf(bar), 0);
        assertEq(credit.totalSupply(), 60); // 100 minted - 40 burned
    }

    function test_Redeem_RevertWhen_InsufficientBalance() public {
        vm.prank(minter);
        credit.mint(alice, 100);
        vm.prank(alice);
        credit.transfer(bar, 40);

        vm.prank(bar);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bar, 40, 41)
        );
        credit.redeem(41);
    }

    function test_Redeem_RevertWhen_NotMerchant() public {
        // alice holds no MerchantMembership: not even a zero-amount redeem is
        // allowed -- the membership check runs before the balance is touched.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, alice));
        credit.redeem(0);
    }

    function test_Redeem_RevertWhen_MembershipExpired() public {
        vm.prank(minter);
        credit.mint(alice, 100);
        vm.prank(alice);
        credit.transfer(bar, 40);

        vm.warp(block.timestamp + mm.MEMBERSHIP_DURATION() + 1);
        assertFalse(mm.isActiveMember(bar));

        vm.prank(bar);
        vm.expectRevert(abi.encodeWithSelector(CommunityCredit.NotAuthorizedRecipient.selector, bar));
        credit.redeem(40);
    }

    function test_FullCircuit_MintSpendRedeem_BalancesReconcile() public {
        // Stage 1: mint towards the citizen (at project confirmation).
        vm.prank(minter);
        credit.mint(alice, 100);
        assertEq(credit.balanceOf(alice), 100);
        assertEq(credit.totalSupply(), 100);

        // Stage 2: citizen spends at the merchant.
        vm.prank(alice);
        credit.transfer(bar, 100);
        assertEq(credit.balanceOf(alice), 0);
        assertEq(credit.balanceOf(bar), 100);
        assertEq(credit.totalSupply(), 100); // still fully circulating

        // Stage 3: merchant redeems (returns + burns) the full amount.
        vm.prank(bar);
        credit.redeem(100);
        assertEq(credit.balanceOf(bar), 0);
        assertEq(credit.totalSupply(), 0); // the circuit closed: nothing left outstanding
    }
}
