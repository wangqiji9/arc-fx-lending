// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DataTypes, RAY, BPS, SECONDS_PER_YEAR} from "./DataTypes.sol";
import {WadRayMath} from "./WadRayMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title RateEngine
/// @notice Stateless interest rate engine (architecture.md §4.3). Kink rate model + index compound accrual.
/// @dev library: directly operates on the ReserveData storage held by the caller (LendingPool); holds no state.
///      Responsibility separation (aligned with state-transitions §updateIndexes):
///        - updateIndexes: rolls interest into the index using the【old】rate only, does not recalculate the rate
///        - calculateBorrowRate: recalculates the rate using the【new】utilization at the end of each operation; written back by LendingPool
library RateEngine {
    using WadRayMath for uint256;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                        Rate Model Parameters (ray)
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BASE_RATE = 0; // 0% base rate
    uint256 internal constant SLOPE1 = 0.04e27; // slope before kink: 0→4%
    uint256 internal constant SLOPE2 = 0.75e27; // slope after kink: 4%→79%
    uint256 internal constant KINK = 0.8e27; // kink utilization 80%

    /*//////////////////////////////////////////////////////////////
                              utilization
    //////////////////////////////////////////////////////////////*/

    /// @notice Utilization = actual debt / actual supply, in ray. Returns 0 when supply is 0.
    /// @dev Uses current indexes to unscale: debt = scaledBorrow×borrowIndex, supply = scaledSupply×liquidityIndex.
    function utilization(DataTypes.ReserveData storage reserve) internal view returns (uint256) {
        uint256 totalSupply = uint256(reserve.totalScaledSupply).rayMul(reserve.liquidityIndex);
        if (totalSupply == 0) return 0;
        uint256 totalBorrow = uint256(reserve.totalScaledBorrow).rayMul(reserve.borrowIndex);
        return totalBorrow.rayDiv(totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                            Borrow Rate (kink)
    //////////////////////////////////////////////////////////////*/

    /// @notice Kink rate model + FX risk premium. Returns the annualized borrow rate, in ray.
    /// @param utilizationRay utilization, in ray
    /// @param fxPremiumBps   FX premium for this currency pair, in bps (0 for standard mode)
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
        // FX premium: convert bps → ray and add
        rate += (uint256(fxPremiumBps) * RAY) / BPS;
        return rate;
    }

    /*//////////////////////////////////////////////////////////////
                            Index Compound Accrual
    //////////////////////////////////////////////////////////////*/

    /// @notice Rolls Δt of interest into borrowIndex / liquidityIndex using the old rate, then updates the timestamp.
    /// @dev Linear approximation (architecture.md §updateIndexes):
    ///        borrowFactor    = 1 + borrowRate × Δt / year
    ///        supplyRate      = borrowRate × util × (1 − reserveFactor)
    ///        liquidityFactor = 1 + supplyRate × Δt / year
    ///      Utilization is computed from the【pre-update】state (old indexes), representing the true occupancy
    ///      over this time interval.
    /// @param reserve          target reserve (storage, modified in place)
    /// @param reserveFactorBps protocol reserve factor, in bps
    function updateIndexes(DataTypes.ReserveData storage reserve, uint16 reserveFactorBps) internal {
        uint256 dt = block.timestamp - reserve.lastUpdateTimestamp;
        if (dt == 0) return;
        // Note: the rate used to compute the index here is the stored rate, not a freshly computed one.
        // Verify that every operation that affects the rate also updates it. For example, does a direct
        // transfer affect utilization, or are there other operations that change the rate?
        uint256 rate = reserve.currentBorrowRate; // old rate, ray. Verified: no impact.
        if (rate != 0 && reserve.totalScaledBorrow != 0) {
            // Compute utilization from old indexes (needed for supply-side factor)
            uint256 util = utilization(reserve);

            // Borrow side: borrowIndex ×= (1 + rate·Δt/year)
            uint256 borrowFactor = RAY + (rate * dt) / SECONDS_PER_YEAR;
            reserve.borrowIndex = uint256(reserve.borrowIndex).rayMul(borrowFactor).toUint128();

            // Supply side: supplyRate = rate × util × (1 − reserveFactor)
            uint256 oneMinusRf = RAY - (uint256(reserveFactorBps) * RAY) / BPS;
            uint256 supplyRate = rate.rayMul(util).rayMul(oneMinusRf);
            uint256 liquidityFactor = RAY + (supplyRate * dt) / SECONDS_PER_YEAR;
            reserve.liquidityIndex =
                uint256(reserve.liquidityIndex).rayMul(liquidityFactor).toUint128();
        }

        reserve.lastUpdateTimestamp = uint40(block.timestamp);
    }
}
