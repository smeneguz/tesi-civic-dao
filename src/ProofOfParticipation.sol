// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IProofOfParticipation} from "./interfaces/IProofOfParticipation.sol";

/// @title ProofOfParticipation
/// @notice Soulbound ERC-721 badge minted to every performer of a confirmed
///         civic project (thesis sez. 4.7.2). Implements IProofOfParticipation
///         with no signature change, so it can replace
///         MockProofOfParticipation in CivicProject without touching
///         CivicProject itself.
/// @dev    Unlike CitizenshipSBT (one token per resident, ever), a single
///         address is meant to accumulate MANY of these -- one per confirmed
///         project it performed -- so, unlike CitizenshipSBT, there is no
///         per-address uniqueness check at mint. No URI/IPFS: the only
///         on-chain payload is which project and when, read back via
///         `tokenData`.
contract ProofOfParticipation is ERC721, AccessControl, IProofOfParticipation {
    // --- Roles ---------------------------------------------------------------

    /// @notice Held by CivicProject: the only party allowed to mint a badge.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // --- Storage -------------------------------------------------------------

    uint256 private _nextId = 1;

    struct TokenData {
        uint256 projectId;
        uint64 mintedAt;
    }

    mapping(uint256 => TokenData) private _data;

    // --- Errors ----------------------------------------------------------

    error NonTransferable();
    error TokenDoesNotExist();

    // --- Events ------------------------------------------------------------

    event ParticipationMinted(address indexed to, uint256 indexed tokenId, uint256 indexed projectId);

    constructor(address admin) ERC721("CivicDAO Proof of Participation", "CIVIC-POP") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IProofOfParticipation
    /// @dev `mintedAt` is taken internally from block.timestamp -- CivicProject
    ///      never passes it -- so a caller cannot backdate a badge.
    function mint(address to, uint256 projectId) external onlyRole(MINTER_ROLE) {
        uint256 tokenId = _nextId++;
        uint64 mintedAt = uint64(block.timestamp);
        _data[tokenId] = TokenData(projectId, mintedAt);
        _mint(to, tokenId);
        emit ParticipationMinted(to, tokenId, projectId);
    }

    /// @notice Reads a badge's payload.
    function tokenData(uint256 tokenId) external view returns (uint256 projectId, uint64 mintedAt) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        TokenData storage d = _data[tokenId];
        return (d.projectId, d.mintedAt);
    }

    // --- Soulbound: only minting (from == 0) is allowed; no burn function is
    //     defined, so a badge, once issued, can never be transferred or
    //     destroyed by anyone. Same choke point pattern as CitizenshipSBT, but
    //     with no per-address uniqueness constraint: many badges per address
    //     are expected here. ---
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return interfaceId == type(IProofOfParticipation).interfaceId || super.supportsInterface(interfaceId);
    }
}
