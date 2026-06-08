// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Ray (1e27) fixed-point multiplication and division with half-up rounding. Used for index compound accrual and interest rate calculations.
/// @dev Intended only for symmetric quantities such as interest/indexes. Amount↔scaled conversions
///      inside LendingPool use directional rounding instead (debt rounds up, collateral rounds down;
///      see architecture.md §8) and do not go through this library.
library WadRayMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    /// @notice a * b / RAY, half-up rounding.
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    /// @notice a * RAY / b, half-up rounding. Caller guarantees b != 0.
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }
}
