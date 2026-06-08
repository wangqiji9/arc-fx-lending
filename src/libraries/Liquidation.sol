// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BPS} from "./DataTypes.sol";

/// @title Liquidation
/// @notice Stateless liquidation calculation (architecture.md §4.5 / §7 / state-transitions §7).
///         Given a position and prices, computes the final (repayAmt, seizeAmt). The precondition
///         check HF<1 is performed in LendingPool.
/// @dev Key design: when collateral is insufficient to cover the seize amount,【repay is reverse-computed】
///      so the liquidator pays based on what collateral they can actually receive →
///      the market remains willing to liquidate; only uncovered residual debt
///      (collateralAmount==0 && scaledDebt>0) is left for the Layer 3 protocol backstop.
library Liquidation {
    /// @notice Default close-factor HF threshold (wad). Standard mode.
    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD_STANDARD = 0.98e18;
    /// @notice FX E-Mode close-factor HF threshold (wad). LT=94% + bonus=2.5% requires a higher
    ///         threshold to guarantee a single 50% partial liquidation restores HF > 1.
    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD_FX = 0.983e18;
    uint256 internal constant CLOSE_FACTOR_PARTIAL = 5000; // 50% bps
    uint256 internal constant CLOSE_FACTOR_FULL = 10000; // 100% bps

    struct Params {
        uint256 requestedRepay; // debt amount the liquidator requests to repay (debt native)
        uint256 actualDebt; // current actual debt of the position (debt native, after updateIndexes)
        uint256 hf; // position HF (wad), caller has ensured < 1e18
        uint256 collateralAmount; // raw collateral amount in the position (col native)
        uint256 collPrice; // collateral price (1e8)
        uint256 debtPrice; // debt price (1e8)
        uint256 colUnit; // 10**collateralDecimals
        uint256 debtUnit; // 10**debtDecimals
        uint16 bonusBps; // liquidation bonus (bps)
        bool isFx; // whether this is an FX E-Mode pair (determines closeFactor threshold)
    }

    /// @notice Dynamic close factor (prevents death spiral, architecture.md §7). Only called when HF<1.
    ///         FX E-Mode uses a higher threshold so that a 50% partial liquidation is sufficient to restore HF>1.
    function closeFactorBps(uint256 hf, bool isFx) internal pure returns (uint256) {
        uint256 threshold = isFx ? CLOSE_FACTOR_HF_THRESHOLD_FX : CLOSE_FACTOR_HF_THRESHOLD_STANDARD;
        return hf >= threshold ? CLOSE_FACTOR_PARTIAL : CLOSE_FACTOR_FULL;
    }

    /// @notice Calculates the final repay amount and seize amount.
    /// @return repayAmt actual debt to be repaid (debt native)
    /// @return seizeAmt collateral to be seized and given to the liquidator (col native)
    function calcLiquidation(Params memory p)
        internal
        pure
        returns (uint256 repayAmt, uint256 seizeAmt)
    {
        // 1. Dynamic close factor → maxRepay, capped by the requested amount
        uint256 maxRepay = (p.actualDebt * closeFactorBps(p.hf, p.isFx)) / BPS;
        repayAmt = p.requestedRepay < maxRepay ? p.requestedRepay : maxRepay;

        // 2. Forward-compute seize from repay: seize = repay value × (1+bonus) converted to collateral units
        //    Seize goes to the liquidator, so each step rounds【down】(protocol-favorable rounding)
        uint256 repayValue = (repayAmt * p.debtPrice) / p.debtUnit; // 1e8 USD
        uint256 seizeValue = (repayValue * (BPS + p.bonusBps)) / BPS; // add bonus
        seizeAmt = (seizeValue * p.colUnit) / p.collPrice; // col native

        // 3. Collateral constraint: if seize exceeds the position's collateral, cap seize and
        //    reverse-compute repay.
        //    Reverse-computation also rounds【down】→ ensures collateral value ≥ repay × (1+bonus),
        //    keeping the liquidation profitable for the liquidator.
        if (seizeAmt > p.collateralAmount) {
            seizeAmt = p.collateralAmount;
            uint256 collateralValue = (p.collateralAmount * p.collPrice) / p.colUnit; // 1e8
            uint256 repayValueNeeded = (collateralValue * BPS) / (BPS + p.bonusBps); // strip bonus
            repayAmt = (repayValueNeeded * p.debtUnit) / p.debtPrice; // debt native
        }
    }
}
