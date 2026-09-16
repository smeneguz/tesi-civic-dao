// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IProofOfParticipation
/// @notice Frontier interface towards the proof-of-participation badge/NFT
///         economy. CivicProject mints one badge per confirmed performer per
///         project, tying it to `projectId` so the badge is attributable to a
///         specific delivered civic project.
interface IProofOfParticipation {
    function mint(address to, uint256 projectId) external;
}
