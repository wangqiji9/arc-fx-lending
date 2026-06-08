// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Unified price entry point for LendingPool / RiskEngine / Liquidation.
/// @dev All prices are denominated in USD with 1e8 base (architecture.md §8). Non-USD assets
///      such as EURC have their FX risk encoded into the USD quote (EURC ≈ 1.08e8), so the
///      core HF math only needs getPrice.
interface IPriceOracle {
    /// @notice USD price of an asset, 1e8 base. Reverts on stale data, non-positive values, or missing feed.
    /// @dev Does not revert when paused — repay/liquidate still need prices during a pause period
    ///      (see architecture.md §4.6).
    function getPrice(address asset) external view returns (uint256);

    /// @notice Whether the asset has been circuit-breaker paused by the guardian (e.g. depeg or other anomaly).
    /// @dev Pausing only blocks new borrows/deposits; repay/liquidate callers may choose to ignore this flag.
    function isPaused(address asset) external view returns (bool);
}
