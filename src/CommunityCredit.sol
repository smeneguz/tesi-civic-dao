// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICommunityCredit} from "./interfaces/ICommunityCredit.sol";
import {MerchantMembership} from "./MerchantMembership.sol";

/// @title CommunityCredit
/// @notice Community-credit token of the CivicDAO private flow (thesis sez.
///         4.7.2). Implements ICommunityCredit with no signature change, so it
///         can replace MockCommunityCredit in CivicProject without touching
///         CivicProject itself.
/// @dev    Design choice: a real ERC-20 (OpenZeppelin), not a bare balance
///         registry -- BECAUSE unlike a fully non-transferable credit, this
///         credit is genuinely SPENDABLE: at businesses holding a valid
///         MerchantMembership certificate (i.e. that paid this period's
///         CivicDAO membership fee to the ETS, off-chain). Riding on ERC-20
///         gives that spending a familiar `transfer`/`balanceOf` surface for
///         free; `_update` is overridden to enforce the one restriction that
///         actually matters here: the recipient of any non-mint transfer must
///         be an active merchant. Citizen -> citizen transfers are therefore
///         impossible not as a special case, but because citizens are never
///         active merchants.
///
///         Closed circuit (thesis sez. 4.5.4), all three stages now on-chain:
///           1) mint towards citizens, at project confirmation (CivicProject);
///           2) spend from citizen to merchant (`transfer`, gated above);
///           3) redeem: the merchant returns accumulated credit to the DAO,
///              which is burned (`redeem`, below). In exchange the merchant
///              receives visibility/sponsorship from the DAO -- but that is
///              an OFF-CHAIN service; on-chain, `redeem` only records the
///              fact (via the `Redeemed` event) that the circuit closed,
///              exactly like CivicProject's off-chain euro reimbursement:
///              the chain registers the fact, the real service happens
///              outside it.
///
///         Explicitly NOT implemented in this demo version (left for later
///         tokenomics work -- see TODO below): a supply cap and decay of
///         unspent balances over time.
contract CommunityCredit is ERC20, AccessControl, ICommunityCredit {
    // --- Roles ---------------------------------------------------------------

    /// @notice Held by CivicProject: the only party allowed to mint credit.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // --- Immutable dependencies ---------------------------------------------

    /// @notice Consulted on every transfer to decide whether the recipient is
    ///         an authorized spending destination.
    MerchantMembership public immutable merchantMembership;

    // --- Errors ----------------------------------------------------------

    error NotAuthorizedRecipient(address to);

    // --- Events ------------------------------------------------------------

    /// @notice Stage 3 of the closed circuit: `merchant` returned `amount` of
    ///         accumulated credit to the DAO, which was burned. Accounting
    ///         base for the off-chain visibility/sponsorship the DAO owes the
    ///         merchant in exchange -- same role as CivicProject's
    ///         ReimbursementDue for the off-chain euro reimbursement.
    event Redeemed(address indexed merchant, uint256 amount);

    constructor(address admin, address merchantMembership_) ERC20("CivicDAO Community Credit", "CIVIC-CC") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        merchantMembership = MerchantMembership(merchantMembership_);
    }

    /// @inheritdoc ICommunityCredit
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Stage 3 of the closed circuit (thesis sez. 4.5.4): a merchant
    ///         returns `amount` of its own accumulated credit to the DAO,
    ///         closing the loop opened by `mint` (stage 1) and `transfer`
    ///         (stage 2). The credit is burned, not moved to any address: the
    ///         DAO's compensation for it (visibility/sponsorship) is an
    ///         off-chain service, so there is nothing further to hold
    ///         on-chain -- only `Redeemed` records that the exchange happened.
    /// @dev Only a currently active merchant may call this on its own
    ///      balance (msg.sender, not an arbitrary `merchant` parameter):
    ///      redeem is self-service, never something one address does to
    ///      another. Insufficient balance reverts via `_burn`'s own check
    ///      (ERC20InsufficientBalance), so there is no separate balance
    ///      check here.
    function redeem(uint256 amount) external {
        if (!merchantMembership.isActiveMember(msg.sender)) revert NotAuthorizedRecipient(msg.sender);
        _burn(msg.sender, amount);
        emit Redeemed(msg.sender, amount);
    }

    // TODO (post-thesis-demo tokenomics): supply cap and decay of unspent
    // balances over time.

    /// @dev Single choke point for mint/burn/transfer (OZ v5 pattern, the same
    ///      role `_update` plays in CitizenshipSBT/ProofOfParticipation). Mint
    ///      (from == 0) and burn (to == 0, no burn path exists today) are
    ///      always allowed; any other transfer requires the recipient to
    ///      currently be an active merchant.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !merchantMembership.isActiveMember(to)) {
            revert NotAuthorizedRecipient(to);
        }
        super._update(from, to, value);
    }
}
