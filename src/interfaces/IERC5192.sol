// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC-5192: Minimal Soulbound NFTs
/// @notice Interfaccia minimale che formalizza il concetto di token non
///         trasferibile (soulbound), come richiamato nella tesi (sez. 5.4.1).
interface IERC5192 {
    /// @notice Emesso quando lo stato di un token diventa "locked".
    event Locked(uint256 tokenId);

    /// @notice Emesso quando lo stato di un token diventa "unlocked".
    event Unlocked(uint256 tokenId);

    /// @notice Restituisce lo stato di blocco di un token.
    /// @dev DEVE revertire se il token non esiste.
    function locked(uint256 tokenId) external view returns (bool);
}
