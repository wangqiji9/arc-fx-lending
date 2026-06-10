// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AgentTypes
/// @notice Return structs for the agent-facing read-only decision layer (see docs/findings.md §D-1).
/// @dev These types are consumed by Circle Agent Wallet (or any programmatic caller) to
///      discover markets, assess position risk, and preview new positions — all via view
///      functions on LendingPool, with no change to the core lending logic.
///
///      Precision conventions (architecture.md §8), shared by every field below:
///        - rates (borrow/supply)        : ray   (1e27)
///        - risk params (ltv/LT/buffer)  : bps   (1e4)
///        - prices / USD valuations      : 1e8
///        - health factor                : wad   (1e18)
///        - token amounts                : native decimals of the asset
library AgentTypes {
    /// @notice One (collateral, debt) market combination discovered from the reserves registry.
    /// @dev Returned by LendingPool.getAvailableMarkets(). ltv / liquidationThreshold are already
    ///      resolved (FX E-Mode or Standard) for this specific pair.
    struct MarketInfo {
        address collateralAsset;
        address debtAsset;
        uint16 ltv; // bps, resolved (FX pair → E-Mode value; otherwise collateral's Standard LTV)
        uint16 liquidationThreshold; // bps, resolved
        uint256 debtBorrowRate; // ray — annualized cost of borrowing the debt asset
        // ray — market supplyRate of the collateral asset *as a lender deposit*. This is the
        // asset's market rate, NOT the yield of collateral locked in a position (locked collateral
        // is non-interest-bearing and earns 0). An agent that wants this yield must separately
        // deposit the asset as a lender; the value is provided for carry-strategy composition.
        uint256 collateralSupplyRate;
        uint256 availableLiquidity; // debt native — borrowable now = pool balance − locked collateral
        bool isFxMode; // true if this pair resolves to FX E-Mode params
    }

    /// @notice Real-time risk snapshot for an existing isolated position.
    /// @dev Returned by LendingPool.getPositionRisk(key) / batchGetPositionRisk(keys). The health
    ///      factor is produced by the SAME RiskEngine.calculateHealthFactor path used by liquidate(),
    ///      so a preview/snapshot never disagrees with the on-chain liquidation check.
    struct PositionRisk {
        bytes32 key;
        bool exists; // false if the position does not exist (all other fields are zero)
        uint256 healthFactor; // wad, LT basis (distance to the liquidation threshold)
        // 1e8 — lowest collateral price at which the position is still healthy (HF == 1e18), for the
        // single direction "collateral price drops". The position becomes liquidatable only when the
        // price falls STRICTLY below this value. ONLY meaningful in Standard mode; in FX E-Mode this
        // is 0 (see applicable).
        uint256 liquidationPrice;
        // false for FX E-Mode (and for no-debt positions). FX real risk is a depeg jump, not a
        // continuous approach to a price level — a scalar liquidation price would give a false
        // sense of safety, so FX reports bufferBps instead. See docs/findings.md §D-1 ②.
        bool liquidationPriceApplicable;
        uint256 bufferBps; // bps — relative safety buffer = (HF − 1e18) × BPS / 1e18 (0 if HF ≤ 1e18)
        uint256 currentDebt; // debt native — scaledDebt × borrowIndex (rounded up)
        uint256 collateralValue; // 1e8 — collateral USD value (floor, matches HF internals)
        uint256 debtValue; // 1e8 — debt USD value (ceil, matches HF internals)
        uint256 debtBorrowRate; // ray — this position's real cost leg (borrow rate of the debt asset)
        // ray — market supplyRate of the collateral asset as a lender deposit. NOT the yield of this
        // position's locked collateral (which is 0). Reported for parity with MarketInfo.
        uint256 collateralSupplyRate;
    }

    /// @notice Simulated outcome of opening a new position, without changing state.
    /// @dev Returned by LendingPool.previewPosition(...). Both health factors come from
    ///      RiskEngine.calculateHealthFactor (LTV basis for the open gate, LT basis for risk
    ///      distance) — no parallel HF formula exists, so preview cannot say "healthy" while a real
    ///      open would be liquidatable.
    struct PreviewResult {
        uint256 healthFactor; // wad, LT basis (comparable to PositionRisk.healthFactor)
        uint256 ltvHealthFactor; // wad, LTV basis — must be ≥ 1e18 for the open to pass the gate
        bool openable; // ltvHealthFactor ≥ 1e18 AND borrowAmount ≤ availableLiquidity
        uint256 liquidationPrice; // 1e8 — Standard only; 0 in FX (see applicable)
        bool liquidationPriceApplicable; // false in FX E-Mode
        uint256 bufferBps; // bps — (HF − 1e18) × BPS / 1e18 on the LT basis
        uint256 borrowRate; // ray — borrow rate AFTER this borrow (post-open utilization)
        // ray — market supplyRate of the collateral asset as a lender deposit. NOT this position's
        // collateral yield (0). Reported for parity with MarketInfo.
        uint256 collateralSupplyRate;
        uint256 availableLiquidity; // debt native — borrowable now
        bool isFxMode;
    }
}
