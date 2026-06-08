// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*//////////////////////////////////////////////////////////////
                  Precision constants (protocol-wide, see architecture.md §8)
//////////////////////////////////////////////////////////////*/

uint256 constant RAY = 1e27; // index (liquidity/borrow) and interest rates
uint256 constant WAD = 1e18; // HF
uint256 constant BPS = 1e4; // risk parameters (LTV/LT/bonus/closeFactor/reserveFactor)
uint256 constant USD_BASE = 1e8; // internal USD valuation + Chainlink USD feed precision
uint256 constant SECONDS_PER_YEAR = 365 days;

/*//////////////////////////////////////////////////////////////
                              Structs
//////////////////////////////////////////////////////////////*/

library DataTypes {
    /// @notice Per-asset risk configuration (statically set by admin).
    /// @dev Fields are grouped into three categories by "the role the asset plays" — do not conflate them (see architecture.md §3):
    ///      ┌ As [collateral] (Standard mode): ltv / liquidationThreshold / liquidationBonus
    ///      │   —— These are collateral-side risks; the debt-side asset does not use these three fields.
    ///      │   —— If (col, debt) hits an enabled FX currency pair, these three are [overridden] by the fxCategories table (E-Mode).
    ///      ├ As [debt / borrowed asset]: borrowable / borrowCap / reserveFactor / fxPremium / interest rate model
    ///      │   —— fxPremium is per-reserve (not per-pair): a shared borrowIndex cannot charge different rates to
    ///      │      borrowers in different currency pairs, so the FX borrow premium is attributed to the debt asset itself (see architecture.md §4.3).
    ///      └ Common to both roles: currency / oracle / decimals / depositCap / collateralCap
    struct AssetConfig {
        bool configured; // whether the asset has been configured (prevents use of uninitialized assets)
        bool borrowable; // [debt side] whether borrowing is allowed (ETH is collateral-only → false)
        uint8 decimals; // [common] ERC20 decimals (Arc USDC/EURC = 6)
        uint16 ltv; // [collateral side · Standard] LTV when used as collateral, bps (overridden by fxCategory for FX pairs)
        uint16 liquidationThreshold; // [collateral side · Standard] liquidation threshold when used as collateral, bps
        uint16 liquidationBonus; // [collateral side · Standard] liquidation bonus for this collateral, bps
        uint16 reserveFactor; // [debt side] protocol reserve share, bps (percentage of borrow interest, not principal)
        uint16 fxPremium; // [debt side] FX risk premium for borrowing this asset, bps (added to borrowRate; set 0 for non-FX assets)
        bytes32 currency; // [common] currency code, e.g. "USD"/"EUR" (FX risk looked up by currency pair)
        address oracle; // [common] price feed (asset/USD)
        uint128 borrowCap; // [debt side] total debt cap, native decimals (0 = unlimited)
        uint128 collateralCap; // [collateral side] total collateral cap, native decimals (0 = unlimited)
        uint128 depositCap; // [lender side] deposit cap, native decimals (0 = unlimited)
    }

    /// @notice Per-currency-pair FX risk configuration (key = pairKey(min, max)).
    /// @dev When enabled, the ltv/LT/bonus values here [replace] the same fields in the collateral asset's AssetConfig inside resolveParams
    ///      (E-Mode, e.g. USDC↔EURC at 90%/94%/2.5%). Risk is attributed to the "currency pair" rather than a single asset, hence a separate table.
    ///      These three parameters are consumed in real time per [individual isolated position] (HF/liquidation) without going through a shared index, so per-pair is fine.
    ///      The interest rate premium (fxPremium) is instead placed in AssetConfig (per-reserve) due to the shared borrowIndex constraint.
    struct FxCategory {
        bool enabled; // whether FX E-Mode is enabled for this currency pair
        uint16 ltv; // E-Mode LTV, bps (overrides collateral asset's AssetConfig.ltv)
        uint16 liquidationThreshold; // E-Mode LT, bps
        uint16 liquidationBonus; // E-Mode liquidation bonus, bps
    }

    /// @notice Per-asset internal accounting (AToken/DebtToken removed; all accounting is internal).
    struct ReserveData {
        uint128 liquidityIndex; // lender-side cumulative index, ray (initial value RAY)
        uint128 borrowIndex; // borrow-side cumulative index, ray (initial value RAY)
        uint128 totalScaledSupply; // scaled total supply; × liquidityIndex = actual supply
        uint128 totalScaledBorrow; // scaled total debt; × borrowIndex = actual debt
        uint128 currentBorrowRate; // current annualized borrow rate, ray
        uint40 lastUpdateTimestamp; // timestamp of the last updateIndexes call
    }

    /// @notice Isolated position. key = keccak256(owner, collateralAsset, debtAsset), unique per triple.
    /// @dev owner / mode are not stored: owner is encoded in the key, mode is derived in real time by resolveParams.
    struct Position {
        address collateralAsset; // collateral asset
        address debtAsset; // debt asset
        uint128 collateralAmount; // raw collateral amount (does not accrue interest, does not change with index)
        uint128 scaledDebt; // scaled debt; × borrowIndex(ray) = actual debt
    }

    /// @notice Real-time risk parameters returned by resolveParams (not persisted to storage).
    /// @dev Does not include fxPremium — the interest rate premium is per-reserve (AssetConfig.fxPremium) and does not pass through this struct.
    struct RiskParams {
        uint16 ltv; // bps
        uint16 liquidationThreshold; // bps
        uint16 liquidationBonus; // bps
        bool isFx; // whether FX E-Mode parameters apply
    }
}

/*//////////////////////////////////////////////////////////////
                          Custom Errors
//////////////////////////////////////////////////////////////*/

// General
error ZeroAddress();
error InvalidAmount();
error NotAuthorized();

// Configuration / assets
error AssetNotConfigured(address asset);
error AssetNotBorrowable(address asset);

// caps
error BorrowCapExceeded(address asset);
error CollateralCapExceeded(address asset);
error DepositCapExceeded(address asset);

// Liquidity / balance
error InsufficientLiquidity(address asset);
error InsufficientBalance();
error InsufficientCollateral();
error TransferAmountMismatch(); // actual received amount < expected (rejects fee-on-transfer tokens)
error SameAsset(); // collateral and debt are the same asset

// Layer 3
error PositionStillCollateralized(bytes32 key); // collateral still present; should go through normal liquidation rather than bad debt injection

// Position / health
error PositionNotFound(bytes32 key);
error HealthFactorTooLow(uint256 hf); // HF < 1 after the operation
error PositionHealthy(uint256 hf); // HF >= 1 during liquidation; position cannot be liquidated

// Oracle
error StalePrice(address oracle);
error PriceDeviationTooHigh(address asset);
error OraclePaused(address asset);
error InvalidPrice(address asset);
error FeedNotSet(address asset);

/*//////////////////////////////////////////////////////////////
                            Events
//////////////////////////////////////////////////////////////*/

// Lender side
event Deposited(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount);
event Withdrawn(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount);

// Borrow side
event Borrowed(
    address indexed user, address indexed collateralAsset, address indexed debtAsset, uint256 amount
);
event Repaid(
    address indexed payer, address indexed owner, address indexed debtAsset, uint256 amount
);
event CollateralAdded(
    address indexed user, address indexed collateralAsset, address indexed debtAsset, uint256 amount
);
event CollateralWithdrawn(
    address indexed user, address indexed collateralAsset, address indexed debtAsset, uint256 amount
);
event PositionClosed(bytes32 indexed key, address indexed owner);

// Liquidation
event Liquidated(
    address indexed liquidator,
    address indexed owner,
    address collateralAsset,
    address debtAsset,
    uint256 repaidAmount,
    uint256 seizedCollateral
);

// Interest rate / index
event ReserveDataUpdated(
    address indexed asset, uint256 liquidityIndex, uint256 borrowIndex, uint256 borrowRate
);
