// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IJury
/// @notice Frontier interface towards the jury/dispute-resolution system.
///         CivicProject only asks a yes/no question of it (is this address
///         currently a juror?); how jurors are selected, rotated or
///         compensated is entirely the concrete implementation's concern.
interface IJury {
    function isJuror(address who) external view returns (bool);
}
