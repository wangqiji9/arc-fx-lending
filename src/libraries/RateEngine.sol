// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DataTypes, RAY, BPS, SECONDS_PER_YEAR} from "./DataTypes.sol";
import {WadRayMath} from "./WadRayMath.sol";

/// @title RateEngine
/// @notice 无状态利率引擎(architecture.md §四.3)。kink 利率模型 + index 复利累积。
/// @dev library:直接操作调用方(LendingPool)持有的 ReserveData storage,不持任何状态。
///      职责分工(对齐 state-transitions §updateIndexes):
///        - updateIndexes:只用【旧】利率把利息滚进 index,不重算利率
///        - calculateBorrowRate:操作末尾用【新】利用率重算利率,由 LendingPool 写回
library RateEngine {
    using WadRayMath for uint256;

    /*//////////////////////////////////////////////////////////////
                          利率模型参数(ray)
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BASE_RATE = 0; // 0% 基础利率
    uint256 internal constant SLOPE1 = 0.04e27; // kink 前斜率:0→4%
    uint256 internal constant SLOPE2 = 0.75e27; // kink 后斜率:4%→79%
    uint256 internal constant KINK = 0.8e27; // 拐点利用率 80%

    /*//////////////////////////////////////////////////////////////
                              utilization
    //////////////////////////////////////////////////////////////*/

    /// @notice 利用率 = 实际债务 / 实际供给,ray。供给为 0 时返回 0。
    /// @dev 用当前 index 折算:debt = scaledBorrow×borrowIndex,supply = scaledSupply×liquidityIndex。
    function utilization(DataTypes.ReserveData storage reserve) internal view returns (uint256) {
        uint256 totalSupply = uint256(reserve.totalScaledSupply).rayMul(reserve.liquidityIndex);
        if (totalSupply == 0) return 0;
        uint256 totalBorrow = uint256(reserve.totalScaledBorrow).rayMul(reserve.borrowIndex);
        return totalBorrow.rayDiv(totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                            借款利率(kink)
    //////////////////////////////////////////////////////////////*/

    /// @notice kink 利率模型 + FX 风险溢价。返回年化借款利率,ray。
    /// @param utilizationRay 利用率,ray
    /// @param fxPremiumBps   该货币对 FX 溢价,bps(standard 模式为 0)
    function calculateBorrowRate(uint256 utilizationRay, uint16 fxPremiumBps)
        internal
        pure
        returns (uint256)
    {
        uint256 rate;
        if (utilizationRay <= KINK) {
            // base + (util/kink) × slope1
            rate = BASE_RATE + (utilizationRay * SLOPE1) / KINK;
        } else {
            // base + slope1 + ((util-kink)/(1-kink)) × slope2
            uint256 excess = utilizationRay - KINK;
            rate = BASE_RATE + SLOPE1 + (excess * SLOPE2) / (RAY - KINK);
        }
        // FX 溢价:bps → ray 后叠加
        rate += (uint256(fxPremiumBps) * RAY) / BPS;
        return rate;
    }

    /*//////////////////////////////////////////////////////////////
                            index 复利累积
    //////////////////////////////////////////////////////////////*/

    /// @notice 用旧利率把 Δt 的利息滚进 borrowIndex / liquidityIndex,并更新时间戳。
    /// @dev 线性近似(architecture.md §updateIndexes):
    ///        borrowFactor    = 1 + borrowRate × Δt / year
    ///        supplyRate      = borrowRate × util × (1 − reserveFactor)
    ///        liquidityFactor = 1 + supplyRate × Δt / year
    ///      util 用更新【前】状态(旧 index)算,代表这段时间真实占用率。
    /// @param reserve          目标 reserve(storage,原地改)
    /// @param reserveFactorBps 协议留存比例,bps
    function updateIndexes(DataTypes.ReserveData storage reserve, uint16 reserveFactorBps) internal {
        uint256 dt = block.timestamp - reserve.lastUpdateTimestamp;
        if (dt == 0) return;

        uint256 rate = reserve.currentBorrowRate; // 旧利率,ray
        if (rate != 0 && reserve.totalScaledBorrow != 0) {
            // 先用旧 index 算 util(供给侧因子需要)
            uint256 util = utilization(reserve);

            // 借款侧:borrowIndex ×= (1 + rate·Δt/year)
            uint256 borrowFactor = RAY + (rate * dt) / SECONDS_PER_YEAR;
            reserve.borrowIndex = uint128(uint256(reserve.borrowIndex).rayMul(borrowFactor));

            // 供给侧:supplyRate = rate × util × (1 − reserveFactor)
            uint256 oneMinusRf = RAY - (uint256(reserveFactorBps) * RAY) / BPS;
            uint256 supplyRate = rate.rayMul(util).rayMul(oneMinusRf);
            uint256 liquidityFactor = RAY + (supplyRate * dt) / SECONDS_PER_YEAR;
            reserve.liquidityIndex =
                uint128(uint256(reserve.liquidityIndex).rayMul(liquidityFactor));
        }

        reserve.lastUpdateTimestamp = uint40(block.timestamp);
    }
}
