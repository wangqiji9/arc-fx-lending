// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {NotAuthorized} from "../libraries/DataTypes.sol";

/// @title BasePriceOracle
/// @notice Shared protocol-side oracle scaffolding: guardian-controlled circuit breaker + the
///         getPrice entry point. The price source itself is left abstract (_readPrice), so every
///         concrete oracle (Chainlink, Pyth, mock, ...) reuses the same pause logic and only
///         implements how it fetches a 1e8 USD price.
/// @dev The pause flag is protocol risk control, NOT an oracle feature — it lives here so it is
///      defined exactly once and behaves identically regardless of the underlying price source
///      (architecture.md §4.6 / §7). Pausing only blocks new borrows/deposits; getPrice itself
///      ignores the flag so repay/liquidate keep working during a pause.
abstract contract BasePriceOracle is IPriceOracle, Ownable {
    /// @notice Asset => whether circuit-breaker pause is active.
    mapping(address asset => bool) public paused;

    /// @notice Hot wallet that can trigger a pause (separate from admin for fast response to depeg events).
    address public guardian;

    event GuardianSet(address indexed guardian);
    event PausedSet(address indexed asset, bool paused);

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                                 GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Guardian/owner triggers or lifts the circuit breaker for an asset (called when off-chain monitoring detects a depeg or deviation anomaly).
    function setPaused(address asset, bool isPaused_) external onlyGuardianOrOwner {
        paused[asset] = isPaused_;
        emit PausedSet(asset, isPaused_);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICE FETCH
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256) {
        return _readPrice(asset);
    }

    /// @inheritdoc IPriceOracle
    function isPaused(address asset) external view returns (bool) {
        return paused[asset];
    }

    /// @notice Source-specific price fetch. Must return a 1e8 USD-base price and revert on
    ///         stale/invalid/missing data. Subclasses own their own staleness + normalization rules.
    function _readPrice(address asset) internal view virtual returns (uint256);
}
