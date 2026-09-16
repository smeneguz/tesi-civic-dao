// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MerchantMembership
/// @notice Annual membership certificate for businesses that join the
///         CivicDAO's community-credit circuit (thesis "Prossimi passi":
///         membership business, circuito chiuso). A business pays an annual
///         fee OFF-CHAIN to the ETS (Ente del Terzo Settore, the DAO's legal
///         entity); once that payment is verified, the ETS mints one of these
///         soulbound NFTs to the business's address as proof of that period's
///         payment. CommunityCredit reads `isActiveMember` on every transfer
///         to decide whether a given address is an authorized spending
///         destination for community credit.
/// @dev    Same soulbound pattern as CitizenshipSBT (`_update` reverts on any
///         transfer), but -- unlike CitizenshipSBT -- a business accumulates
///         one certificate PER PAYMENT over time (renewals), so re-minting to
///         an address that already holds one is allowed by design.
contract MerchantMembership is ERC721, AccessControl {
    // --- Roles ---------------------------------------------------------------

    /// @notice Held by the ETS: the only party allowed to certify a payment.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    // --- Constants -------------------------------------------------------

    /// @notice How long a payment keeps a business an active member.
    /// @dev A rolling window from the payment's own timestamp, not a calendar
    ///      year: simpler to compute on-chain and close enough for the demo.
    ///      TODO: calendar-year semantics and a renewal grace period, if the
    ///      thesis needs that precision when this circuit is built out fully.
    uint64 public constant MEMBERSHIP_DURATION = 365 days;

    // --- Storage -------------------------------------------------------------

    uint256 private _nextId = 1;

    struct MembershipData {
        uint64 paidAt;
    }

    mapping(uint256 => MembershipData) private _data;

    /// @notice Timestamp of each business's most recent payment.
    /// @dev Kept separately from the per-token data so `isActiveMember` is an
    ///      O(1) mapping read instead of an enumeration over every
    ///      certificate ever minted to that address -- only the latest
    ///      payment matters for "is currently active".
    mapping(address => uint64) public lastPaidAt;

    // --- Errors ----------------------------------------------------------

    error NonTransferable();
    error TokenDoesNotExist();

    // --- Events ------------------------------------------------------------

    event MembershipPaid(address indexed business, uint256 indexed tokenId, uint64 paidAt);

    constructor(address admin, address issuer) ERC721("CivicDAO Merchant Membership", "CIVIC-MM") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, issuer);
    }

    /// @notice Certifies that `business` has paid this period's fee.
    /// @dev Callable only by the ETS (ISSUER_ROLE) after off-chain payment is
    ///      verified -- there is no on-chain payment: the euro fee, like every
    ///      other euro amount in CivicDAO, is never held by this contract.
    function mint(address business) external onlyRole(ISSUER_ROLE) returns (uint256 tokenId) {
        tokenId = _nextId++;
        uint64 paidAt = uint64(block.timestamp);
        _data[tokenId] = MembershipData(paidAt);
        lastPaidAt[business] = paidAt;
        _mint(business, tokenId);
        emit MembershipPaid(business, tokenId, paidAt);
    }

    /// @notice True if `business`'s most recent payment is still within
    ///         MEMBERSHIP_DURATION. The single check CommunityCredit relies on
    ///         to gate transfers.
    function isActiveMember(address business) public view returns (bool) {
        uint64 paidAt = lastPaidAt[business];
        return paidAt != 0 && block.timestamp - paidAt <= MEMBERSHIP_DURATION;
    }

    /// @notice Reads a certificate's payload.
    function membershipData(uint256 tokenId) external view returns (uint64 paidAt) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        return _data[tokenId].paidAt;
    }

    // --- Soulbound: only minting (from == 0) is allowed; no burn function is
    //     defined, so a certificate, once issued, can never be transferred or
    //     destroyed by anyone (same guarantee as CitizenshipSBT). ---
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
