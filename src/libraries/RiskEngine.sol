// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DataTypes, RAY, WAD, BPS} from "./DataTypes.sol";
import {Keys} from "./Keys.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title RiskEngine
/// @notice 无状态风险引擎(architecture.md §四.4)。两件事:
///         1. resolveParams —— 按货币对决定用 Standard 还是 FX(E-Mode)参数
///         2. calculateHealthFactor —— 算单个隔离仓位的 HF(wad)
/// @dev 纯只读 library。HF 函数被 borrow / withdrawCollateral 的 effect-then-verify
///      与 liquidate 复用【同一份代码】,消灭「模拟 HF ≠ 真实 HF」类 bug。
library RiskEngine {
    /*//////////////////////////////////////////////////////////////
                            resolveParams
    //////////////////////////////////////////////////////////////*/

    /// @notice 解析某 (抵押,债务) 组合的实时风险参数。命中启用的 FX 货币对则用 FX 那套,
    ///         否则回落到【抵押资产】的 Standard 参数(LTV/LT/bonus 是抵押侧属性)。
    /// @dev 不落存储(architecture.md §四.1:mode/category 不存,实时推导)。
    function resolveParams(
        mapping(address => DataTypes.AssetConfig) storage assetConfig,
        mapping(bytes32 => DataTypes.FxCategory) storage fxCategories,
        address collateralAsset,
        address debtAsset
    ) internal view returns (DataTypes.RiskParams memory p) {
        DataTypes.AssetConfig storage colCfg = assetConfig[collateralAsset];
        bytes32 pk = Keys.pairKey(colCfg.currency, assetConfig[debtAsset].currency);
        DataTypes.FxCategory storage fx = fxCategories[pk];

        if (fx.enabled) {
            // E-Mode:FX 货币对参数覆盖抵押资产的 Standard 参数
            p = DataTypes.RiskParams({
                ltv: fx.ltv,
                liquidationThreshold: fx.liquidationThreshold,
                liquidationBonus: fx.liquidationBonus,
                isFx: true
            });
        } else {
            // Standard:用抵押资产自身的风险参数
            p = DataTypes.RiskParams({
                ltv: colCfg.ltv,
                liquidationThreshold: colCfg.liquidationThreshold,
                liquidationBonus: colCfg.liquidationBonus,
                isFx: false
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                          calculateHealthFactor
    //////////////////////////////////////////////////////////////*/

    /// @notice HF = (抵押价值 × 阈值) / 债务价值,wad。无债务返回 max(视为无限健康)。
    /// @dev 阈值由调用方显式传入,实现「同一函数、不同入参」:
    ///        - 开仓/借款/取抵押 传 LTV → 门控,留出到清算线的安全垫(architecture.md §二)
    ///        - 清算          传 LT  → 判定
    ///      两条路径走同一份代码,杜绝「模拟 HF ≠ 真实 HF」。
    ///      舍入铁律(§八):抵押估值【向下】、债务(数量+估值)【向上】→ HF 偏小,对协议保守。
    /// @param position    目标仓位(memory 副本)
    /// @param thresholdBps 风险阈值,bps(LTV 用于门控 / LT 用于清算)
    /// @param borrowIndex 债务资产当前 borrowIndex(ray)——调用前须已 updateIndexes
    /// @param oracle      价格源
    /// @param assetConfig 资产配置(取 decimals)
    function calculateHealthFactor(
        DataTypes.Position memory position,
        uint256 thresholdBps,
        uint256 borrowIndex,
        IPriceOracle oracle,
        mapping(address => DataTypes.AssetConfig) storage assetConfig
    ) internal view returns (uint256) {
        if (position.scaledDebt == 0) return type(uint256).max;

        uint256 collPrice = oracle.getPrice(position.collateralAsset);
        uint256 debtPrice = oracle.getPrice(position.debtAsset);
        uint256 colUnit = 10 ** assetConfig[position.collateralAsset].decimals;
        uint256 debtUnit = 10 ** assetConfig[position.debtAsset].decimals;

        // 抵押估值【向下】取整(整数除法天然 floor)
        uint256 collValue = (uint256(position.collateralAmount) * collPrice) / colUnit;

        // 实际债务【向上】取整(债务向上),再估值【向上】取整
        uint256 debtAmount = _mulDivUp(uint256(position.scaledDebt), borrowIndex, RAY);
        uint256 debtValue = _mulDivUp(debtAmount, debtPrice, debtUnit);
        if (debtValue == 0) return type(uint256).max;

        // HF_wad = (collValue × 阈值 / BPS) × WAD / debtValue  ——【向下】取整
        uint256 riskAdjustedColl = (collValue * thresholdBps) / BPS;
        return (riskAdjustedColl * WAD) / debtValue;
    }

    /// @notice 实际债务(native),scaledDebt × borrowIndex,【向上】取整(债务向上)。
    function debtOf(uint256 scaledDebt, uint256 borrowIndex) internal pure returns (uint256) {
        return _mulDivUp(scaledDebt, borrowIndex, RAY);
    }

    /*//////////////////////////////////////////////////////////////
                                内部
    //////////////////////////////////////////////////////////////*/

    /// @notice ceil(a × b / d)。调用方保证 d != 0。
    function _mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + d - 1) / d;
    }
}
