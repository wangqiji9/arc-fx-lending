// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BPS} from "./DataTypes.sol";

/// @title Liquidation
/// @notice 无状态清算计算(architecture.md §四.5 / §七 / state-transitions §7)。
///         给定仓位与价格,算出最终 (repayAmt, seizeAmt)。HF<1 的前置校验在 LendingPool 完成。
/// @dev 关键:抵押不够覆盖 seize 时【反推 repay】,让清算人按实际能拿到的抵押付款 →
///      市场愿意清,只把无抵押残债(collateralAmount==0 && scaledDebt>0)留给 Layer 3 协议资金兜底。
library Liquidation {
    /// @notice 动态 closeFactor 的 HF 阈值(wad)。HF≥0.98 部分清算,<0.98 整仓清算。
    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD = 0.98e18;
    uint256 internal constant CLOSE_FACTOR_PARTIAL = 5000; // 50% bps
    uint256 internal constant CLOSE_FACTOR_FULL = 10000; // 100% bps

    struct Params {
        uint256 requestedRepay; // 清算人请求偿还的债务量(debt native)
        uint256 actualDebt; // 仓位当前实际债务(debt native,已 updateIndexes)
        uint256 hf; // 仓位 HF(wad),调用方已确保 < 1e18
        uint256 collateralAmount; // 仓位抵押裸数量(col native)
        uint256 collPrice; // 抵押价格(1e8)
        uint256 debtPrice; // 债务价格(1e8)
        uint256 colUnit; // 10**collateralDecimals
        uint256 debtUnit; // 10**debtDecimals
        uint16 bonusBps; // 清算 bonus(bps)
    }

    /// @notice 动态 closeFactor(防死亡螺旋,architecture.md §七)。仅在 HF<1 时调用。
    function closeFactorBps(uint256 hf) internal pure returns (uint256) {
        return hf >= CLOSE_FACTOR_HF_THRESHOLD ? CLOSE_FACTOR_PARTIAL : CLOSE_FACTOR_FULL;
    }

    /// @notice 计算最终偿还量与扣押抵押量。
    /// @return repayAmt 实际偿还的债务(debt native)
    /// @return seizeAmt 扣押给清算人的抵押(col native)
    function calcLiquidation(Params memory p)
        internal
        pure
        returns (uint256 repayAmt, uint256 seizeAmt)
    {
        // 1. 动态 closeFactor → maxRepay,并用请求量截断
        uint256 maxRepay = (p.actualDebt * closeFactorBps(p.hf)) / BPS;
        repayAmt = p.requestedRepay < maxRepay ? p.requestedRepay : maxRepay;

        // 2. 由 repay 正算 seize:seize = repay价值 ×(1+bonus) 换成抵押数量
        //    seize 给清算人,故各步【向下】取整(协议保守)
        uint256 repayValue = (repayAmt * p.debtPrice) / p.debtUnit; // 1e8 usd
        uint256 seizeValue = (repayValue * (BPS + p.bonusBps)) / BPS; // 加 bonus
        seizeAmt = (seizeValue * p.colUnit) / p.collPrice; // col native

        // 3. 抵押约束:seize 超过仓位抵押时,封顶并【反推】repay
        //    反推同样【向下】取整 → 保证 抵押价值 ≥ repay×(1+bonus),清算人有利可图
        if (seizeAmt > p.collateralAmount) {
            seizeAmt = p.collateralAmount;
            uint256 collateralValue = (p.collateralAmount * p.collPrice) / p.colUnit; // 1e8
            uint256 repayValueNeeded = (collateralValue * BPS) / (BPS + p.bonusBps); // 去掉 bonus
            repayAmt = (repayValueNeeded * p.debtUnit) / p.debtPrice; // debt native
        }
    }
}
