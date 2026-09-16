// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CitizenshipSBT} from "../src/CitizenshipSBT.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Verifica le proprietà del token di cittadinanza descritte nella
///         tesi (sez. 5.4): emissione autorizzata dall'ente, non trasferibilità
///         (RF-02), unicità per identità/indirizzo, validità temporale e
///         resistenza al replay. Il contratto non prevede revoca: una volta
///         coniata, la cittadinanza è definitiva.
contract CitizenshipSBTTest is Test {
    CitizenshipSBT sbt;

    // Il "Comune" (issuer) è un indirizzo di cui controlliamo la chiave privata,
    // così possiamo firmare le autorizzazioni come farebbe l'ente reale.
    uint256 issuerPk = 0xA11CE;
    address issuer;
    address admin = address(0xAD);

    address alice = address(0xA1);
    address bob = address(0xB0);

    function setUp() public {
        issuer = vm.addr(issuerPk);
        sbt = new CitizenshipSBT(admin, issuer);
    }

    // --- Helper: costruisce e firma un'autorizzazione di conio ---
    function _auth(address to, bytes32 nullifier, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = sbt.hashMintAuth(to, nullifier, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _mint(address to, bytes32 nullifier) internal {
        uint256 deadline = block.timestamp + 1 hours;
        sbt.mintWithAuth(to, nullifier, deadline, _auth(to, nullifier, deadline));
    }

    // RF-01: conio valido con firma dell'ente
    function test_MintWithValidAuth() public {
        _mint(alice, keccak256("alice"));
        assertEq(sbt.balanceOf(alice), 1);
        assertTrue(sbt.locked(1)); // ERC-5192: soulbound
    }

    // totalSupply(): usato da ParticipatoryBudget come snapshot dell'elettorato
    // per il quorum. Cresce di 1 ad ogni mint; nessun burn esiste oggi.
    function test_TotalSupply_TracksMints() public {
        assertEq(sbt.totalSupply(), 0);
        _mint(alice, keccak256("alice"));
        assertEq(sbt.totalSupply(), 1);
        _mint(bob, keccak256("bob"));
        assertEq(sbt.totalSupply(), 2);
    }

    // RF-02: non trasferibilità
    function test_TransferReverts() public {
        _mint(alice, keccak256("alice"));
        vm.prank(alice);
        vm.expectRevert(CitizenshipSBT.NonTransferable.selector);
        sbt.transferFrom(alice, bob, 1);
    }

    // RS-01 / RF-02: un solo token per indirizzo (anti-Sybil sul lato indirizzo)
    function test_SecondTokenSameAddressReverts() public {
        _mint(alice, keccak256("alice"));
        bytes32 n2 = keccak256("alice-2");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _auth(alice, n2, deadline);
        vm.expectRevert(CitizenshipSBT.AlreadyCitizen.selector);
        sbt.mintWithAuth(alice, n2, deadline, sig);
    }

    // Anti-replay: lo stesso nullifier non può essere riusato
    function test_NullifierReuseReverts() public {
        bytes32 n = keccak256("same-person");
        _mint(alice, n);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _auth(bob, n, deadline);
        vm.expectRevert(CitizenshipSBT.NullifierAlreadyUsed.selector);
        sbt.mintWithAuth(bob, n, deadline, sig);
    }

    // Validità temporale: firma scaduta
    function test_ExpiredDeadlineReverts() public {
        bytes32 n = keccak256("late");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _auth(alice, n, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(CitizenshipSBT.DeadlineExpired.selector);
        sbt.mintWithAuth(alice, n, deadline, sig);
    }

    // Autorizzazione: firma di chi non ha ISSUER_ROLE
    function test_WrongSignerReverts() public {
        uint256 attackerPk = 0xBAD;
        bytes32 n = keccak256("forged");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = sbt.hashMintAuth(alice, n, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
        vm.expectRevert(CitizenshipSBT.InvalidIssuerSignature.selector);
        sbt.mintWithAuth(alice, n, deadline, abi.encodePacked(r, s, v));
    }

    // locked() reverte su token inesistente (conformità ERC-5192)
    function test_LockedRevertsForNonexistentToken() public {
        vm.expectRevert(CitizenshipSBT.TokenDoesNotExist.selector);
        sbt.locked(999);
    }
}
