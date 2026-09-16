// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReputation
/// @notice Frontier interface towards the reputation system. CivicProject
///         increases every confirmed performer's reputation by the same
///         constant amount: participation counts equally regardless of the
///         project's credit allocation.
interface IReputation {
    function increase(address citizen, uint256 amount) external;
}
