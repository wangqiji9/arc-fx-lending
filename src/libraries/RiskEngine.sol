// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DataTypes, RAY, WAD, BPS} from "./DataTypes.sol";
import {Keys} from "./Keys.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title RiskEngine
/// @notice Stateless risk engine (architecture.md §4.4). Two responsibilities:
///         1. resolveParams — selects Standard or FX (E-Mode) parameters based on the currency pair
///         2. calculateHealthFactor — computes the health factor (HF, wad) for a single isolated position
/// @dev Pure read-only library. The HF function is shared by borrow / withdrawCollateral
///      (effect-then-verify) and liquidate, using【the same code path】, eliminating
///      "simulated HF ≠ real HF" class bugs.
library RiskEngine {
    /*//////////////////////////////////////////////////////////////
                            resolveParams
    //////////////////////////////////////////////////////////////*/

    /// @notice Resolves the real-time risk parameters for a given (collateral, debt) pair. Uses the FX
    ///         parameter set if a matching enabled FX currency pair is found; otherwise falls back to the
    ///         【collateral asset's】Standard parameters (LTV/LT/bonus are collateral-side attributes).
    /// @dev Does not touch storage (architecture.md §4.1: mode/category is not stored, derived on-the-fly).
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
            // E-Mode: FX currency pair parameters override the collateral asset's Standard parameters
            p = DataTypes.RiskParams({
                ltv: fx.ltv,
                liquidationThreshold: fx.liquidationThreshold,
                liquidationBonus: fx.liquidationBonus,
                isFx: true
            });
        } else {
            // Standard: use the collateral asset's own risk parameters
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

    /// @notice HF = (collateral value × threshold) / debt value, in wad. Returns max if there is no debt (treated as infinitely healthy).
    /// @dev The threshold is passed explicitly by the caller, enabling "same function, different inputs":
    ///        - open position / borrow / withdraw collateral passes LTV → gating, preserving safety buffer to the liquidation threshold (architecture.md §2)
    ///        - liquidation passes LT → determination
    ///      Both paths share the same code, eliminating "simulated HF ≠ real HF" bugs.
    ///      Rounding rule (§8): collateral valuation rounds【down】, debt (amount + valuation) rounds【up】→ HF is biased low, conservative for the protocol.
    /// @param position    target position (memory copy)
    /// @param thresholdBps risk threshold, bps (LTV for gating / LT for liquidation)
    /// @param borrowIndex current borrowIndex of the debt asset (ray) — caller must have called updateIndexes first
    /// @param oracle      price source
    /// @param assetConfig asset configuration (used for decimals)
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

        // Collateral valuation: round【down】(integer division is naturally floor)
        uint256 collValue = (uint256(position.collateralAmount) * collPrice) / colUnit;

        // Actual debt: round【up】(debt rounds up), then valuation: round【up】
        uint256 debtAmount = mulDivUp(uint256(position.scaledDebt), borrowIndex, RAY);
        uint256 debtValue = mulDivUp(debtAmount, debtPrice, debtUnit);
        if (debtValue == 0) return type(uint256).max;

        // HF_wad = (collValue × threshold / BPS) × WAD / debtValue  — rounds【down】
        uint256 riskAdjustedColl = (collValue * thresholdBps) / BPS;
        return (riskAdjustedColl * WAD) / debtValue;
    }

    /// @notice Actual debt (native units): scaledDebt × borrowIndex, rounded【up】(debt rounds up).
    function debtOf(uint256 scaledDebt, uint256 borrowIndex) internal pure returns (uint256) {
        return mulDivUp(scaledDebt, borrowIndex, RAY);
    }

    /*//////////////////////////////////////////////////////////////
                                Internal
    //////////////////////////////////////////////////////////////*/

    /// @notice ceil(a × b / d). Caller guarantees d != 0.
    /// @dev internal (not private) so the agent view layer reuses the EXACT same debt-side ceil
    ///      rounding when reporting debtValue / liquidationPrice — single source of truth, no
    ///      parallel formula that could disagree with calculateHealthFactor (docs/findings.md §D-1).
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + d - 1) / d;
    }
}
