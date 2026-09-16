// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICommunityCredit} from "../../src/interfaces/ICommunityCredit.sol";
import {IProofOfParticipation} from "../../src/interfaces/IProofOfParticipation.sol";
import {IReputation} from "../../src/interfaces/IReputation.sol";
import {IJury} from "../../src/interfaces/IJury.sol";

/// @notice Trivial mocks of the four frontier interfaces CivicProject depends
///         on, plus a minimal stand-in for CitizenshipSBT. Shared between the
///         Foundry test suite (CivicProject.t.sol) and the live-Anvil demo
///         (demo-privato.sh, deployed via `forge create`): one source of
///         truth for what "the economy side" looks like in both contexts.
///
///         Each mock just records what CivicProject called it with, so tests
///         (and the demo, via `cast call`) can assert exact counts and
///         arguments -- there is no real token/badge/reputation logic here on
///         purpose, per the frontier-interface design of CivicProject.

/// @notice Minimal stand-in for CitizenshipSBT: only the view CivicProject
///         depends on (balanceOf), plus a bare deployer-callable mint. This is
///         NOT the real CitizenshipSBT (see src/CitizenshipSBT.sol) and does
///         NOT go through the EIP-712 mintWithAuth onboarding flow -- it is
///         only a shortcut to shape an electorate of "already registered"
///         citizens for tests and for the CivicProject demo, which is about
///         the private flow, not about onboarding (see demo-onboarding.sh for
///         the real flow).
contract MockCitizenshipSBT {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;

    function mint(address to) external {
        _balances[to] = 1;
        _totalSupply++;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
}

/// @notice Records every mint call so callers can assert count and arguments.
contract MockCommunityCredit is ICommunityCredit {
    struct Call {
        address to;
        uint256 amount;
    }

    Call[] public calls;

    function mint(address to, uint256 amount) external {
        calls.push(Call(to, amount));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

contract MockProofOfParticipation is IProofOfParticipation {
    struct Call {
        address to;
        uint256 projectId;
    }

    Call[] public calls;

    function mint(address to, uint256 projectId) external {
        calls.push(Call(to, projectId));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

contract MockReputation is IReputation {
    struct Call {
        address citizen;
        uint256 amount;
    }

    Call[] public calls;

    function increase(address citizen, uint256 amount) external {
        calls.push(Call(citizen, amount));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

/// @notice Jury membership is set directly by whoever deploys this mock (no
///         access control): appropriate for a mock, never for the real thing.
contract MockJury is IJury {
    mapping(address => bool) public jurors;

    function setJuror(address who, bool status) external {
        jurors[who] = status;
    }

    function isJuror(address who) external view returns (bool) {
        return jurors[who];
    }
}
