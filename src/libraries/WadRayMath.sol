// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice ray(1e27)定点乘除,四舍五入(half-up)。用于 index 复利与利率计算。
/// @dev 仅用于「利息/index」这类对称量;LendingPool 里 amount↔scaled 的换算另用方向性取整
///      (债务向上、抵押向下,见 architecture.md §八),不走这里。
library WadRayMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    /// @notice a * b / RAY,half-up。
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    /// @notice a * RAY / b,half-up。调用方保证 b != 0。
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }
}
