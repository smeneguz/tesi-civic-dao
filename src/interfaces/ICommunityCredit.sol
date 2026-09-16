// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICommunityCredit
/// @notice Frontier interface towards the community-credit economy (sez. 4.7.2).
/// @dev CivicProject depends only on this minimal write surface, never on a
///      concrete token: governance (CivicProject) commands, economy (the real
///      ICommunityCredit implementation) executes. `amount` is denominated in
///      whatever unit the concrete community-credit token uses.
interface ICommunityCredit {
    function mint(address to, uint256 amount) external;
}
