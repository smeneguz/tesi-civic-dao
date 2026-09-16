// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IReputation} from "./interfaces/IReputation.sol";

/// @notice Minimal view surface of CitizenshipSBT that this contract depends
///         on. Defined locally (not imported from CivicProject.sol) so
///         Reputation stays a fully standalone contract, decoupled from
///         CivicProject's own copy of the same minimal interface.
interface ICitizenshipSBTView {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title Reputation
/// @notice Real implementation of the reputation system behind IReputation
///         (thesis sez. 4.3.4): a standalone contract, not a feature bolted
///         onto CitizenshipSBT. It reads CitizenshipSBT.balanceOf only to
///         confirm the subject is a citizen; it otherwise lives entirely on
///         its own.
///
///         Non-transferable by construction: there is simply no transfer
///         function. The score never weighs a vote (governance stays one-
///         citizen-one-vote everywhere); its only purpose is to gate
///         functional roles by threshold (sez. 4.3.4), exposed via
///         `hasReputation`. Jury eligibility is deliberately NOT wired to
///         this threshold: Jury stays minimal/designated as it is today --
///         random extraction and reputational eligibility for jurors are
///         documented future work.
///
///         Decay (sez. 4.3.4) is LAZY (pull), not push: no function ever
///         actively decrements a score, and no external job/keeper exists.
///         For each citizen this contract stores only a raw score and the
///         timestamp of its last write; the true, current value is that raw
///         score with linear decay applied on demand, at READ time, from the
///         stored timestamp to `block.timestamp`. See `_decayed` for the
///         formula and `increase` for the crystallization step that keeps a
///         write from losing or double-applying pending decay.
contract Reputation is AccessControl, IReputation {
    // --- Roles -----------------------------------------------------------

    /// @notice Held by CivicProject (or any future scorer): the only party
    ///         allowed to write reputation. It is the DAO (governance) that
    ///         writes reputation, never the Comune directly.
    bytes32 public constant SCORER_ROLE = keccak256("SCORER_ROLE");

    // --- Types -------------------------------------------------------------

    /// @notice Raw, crystallized state for one citizen: `value` is the score
    ///         as of `updatedAt`, NOT the current decayed value -- callers
    ///         wanting the current value must go through `reputationOf`.
    struct Score {
        uint256 value;
        uint64 updatedAt;
    }

    // --- Immutable dependencies ----------------------------------------

    ICitizenshipSBTView public immutable citizenship;

    /// @notice Points lost per full day elapsed since the last write.
    ///         Configurable at deploy time; one period = 1 day.
    uint256 public immutable decayRatePerDay;

    // --- Storage -----------------------------------------------------------

    mapping(address => Score) private _scores;

    // --- Events --------------------------------------------------------------

    event ReputationIncreased(address indexed citizen, uint256 amount, uint256 newRawValue);

    // --- Errors --------------------------------------------------------------

    error NotCitizen();

    // --- Constructor -----------------------------------------------------

    constructor(address admin, address citizenshipSBT, uint256 decayRatePerDay_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        citizenship = ICitizenshipSBTView(citizenshipSBT);
        decayRatePerDay = decayRatePerDay_;
    }

    // --- Scorer: write ---------------------------------------------------

    /// @inheritdoc IReputation
    /// @dev Crystallizes the decay accrued since the last write BEFORE adding
    ///      `amount`: `value` is first replaced by its own decayed value at
    ///      `updatedAt = now`, only then is `amount` summed on top. This is
    ///      what keeps pending decay from being lost (if it were ignored) or
    ///      compounded incorrectly (if `amount` were added to the stale raw
    ///      value and decay computed from an old timestamp over the total).
    function increase(address citizen, uint256 amount) external onlyRole(SCORER_ROLE) {
        if (citizenship.balanceOf(citizen) == 0) revert NotCitizen();

        Score storage s = _scores[citizen];
        uint256 crystallized = _decayed(s.value, s.updatedAt);
        s.value = crystallized + amount;
        s.updatedAt = uint64(block.timestamp);

        emit ReputationIncreased(citizen, amount, s.value);
    }

    // --- Views -----------------------------------------------------------

    /// @notice Current reputation of `citizen`, i.e. the stored score with
    ///         every day of decay accrued since the last write already
    ///         applied. This is the value threshold checks and any external
    ///         reader should use -- never the raw stored value.
    function reputationOf(address citizen) public view returns (uint256) {
        Score storage s = _scores[citizen];
        return _decayed(s.value, s.updatedAt);
    }

    /// @notice Raw stored score and its last-write timestamp, before decay.
    ///         Exposed for tests/inspection; `reputationOf` is the value that
    ///         actually matters to callers.
    function rawScoreOf(address citizen) external view returns (uint256 value, uint64 updatedAt) {
        Score storage s = _scores[citizen];
        return (s.value, s.updatedAt);
    }

    /// @notice True if `who`'s current (decayed) reputation is at least
    ///         `threshold`. Models the functional-role-by-threshold pattern
    ///         of sez. 4.3.4 as a plain view on top of the lazy score --
    ///         Jury is deliberately NOT gated by this (see contract notice).
    function hasReputation(address who, uint256 threshold) external view returns (bool) {
        return reputationOf(who) >= threshold;
    }

    // --- Internal ----------------------------------------------------------

    /// @dev Linear lazy decay: current = max(0, value - rate * fullDaysElapsed).
    ///      `updatedAt == 0` (never written) trivially returns `value` (0)
    ///      without underflowing on `block.timestamp - updatedAt`.
    function _decayed(uint256 value, uint64 updatedAt) internal view returns (uint256) {
        if (value == 0 || updatedAt == 0) return value;
        uint256 elapsedDays = (block.timestamp - updatedAt) / 1 days;
        uint256 drop = elapsedDays * decayRatePerDay;
        return drop >= value ? 0 : value - drop;
    }
}
