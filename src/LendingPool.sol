// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {PoolStorage} from "./PoolStorage.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Keys} from "./libraries/Keys.sol";
import {RateEngine} from "./libraries/RateEngine.sol";
import {RiskEngine} from "./libraries/RiskEngine.sol";
import {Liquidation} from "./libraries/Liquidation.sol";
import "./libraries/DataTypes.sol"; // DataTypes library + constants + file-level errors/events

/// @title LendingPool
/// @notice The protocol's sole external entry point (architecture.md §4.2). Inherits exclusive state
///         from PoolStorage, delegates to stateless libraries RateEngine/RiskEngine/Liquidation,
///         and calls the external PriceOracle contract.
///         All real token transfers happen here; CEI is strictly observed; risk-increasing operations
///         use effect-then-verify.
/// @dev Roles: lender (deposit/withdraw, earns interest) and borrower (openPosition/borrow/...,
///      isolated positions).
contract LendingPool is PoolStorage, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using RateEngine for DataTypes.ReserveData;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Price oracle.
    IPriceOracle public oracle;

    /// @notice Layer 3 bad-debt recapitalization source (architecture.md §7). Repays uncollateralized residual debt.
    address public insuranceFund;

    event OracleSet(address indexed oracle);
    event InsuranceFundSet(address indexed fund);
    event AssetConfigured(address indexed asset);
    event FxCategoryConfigured(bytes32 indexed pairKey);

    constructor(address initialOwner, address oracle_) Ownable(initialOwner) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
    }

    /*//////////////////////////////////////////////////////////////
                                admin
    //////////////////////////////////////////////////////////////*/

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setInsuranceFund(address fund) external onlyOwner {
        insuranceFund = fund;
        emit InsuranceFundSet(fund);
    }

    /// @notice Configure or update an asset. On first configuration, initializes the index to RAY
    ///         and adds the asset to reservesList.
    function configureAsset(address asset, DataTypes.AssetConfig calldata cfg) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        assetConfig[asset] = cfg;
        assetConfig[asset].configured = true; // force-set to avoid admin accidentally leaving it unset

        DataTypes.ReserveData storage r = reserves[asset];
        if (r.liquidityIndex == 0) {
            r.liquidityIndex = RAY.toUint128();
            r.borrowIndex = RAY.toUint128();
            r.lastUpdateTimestamp = block.timestamp.toUint40();
            reservesList.add(asset);
        }
        emit AssetConfigured(asset);
    }

    /// @notice Configure FX E-Mode parameters for a currency pair.
    function configureFxCategory(bytes32 currencyA, bytes32 currencyB, DataTypes.FxCategory calldata fx)
        external
        onlyOwner
    {
        bytes32 pk = Keys.pairKey(currencyA, currencyB);
        fxCategories[pk] = fx;
        emit FxCategoryConfigured(pk);
    }

    /*//////////////////////////////////////////////////////////////
                          Lender side: deposit / withdraw
    //////////////////////////////////////////////////////////////*/

    /// @notice Supply liquidity in exchange for shares that accrue interest via liquidityIndex.
    function deposit(address asset, uint256 amount) external nonReentrant {
        _requireConfigured(asset);
        if (amount == 0) revert InvalidAmount();
        if (oracle.isPaused(asset)) revert OraclePaused(asset); // paused: block new supply

        _accrue(asset);
        DataTypes.ReserveData storage r = reserves[asset];
        DataTypes.AssetConfig storage cfg = assetConfig[asset];

        // depositCap (in underlying terms, aligned with borrowCap)
        if (cfg.depositCap != 0) {
            uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
            if (supplied + amount > cfg.depositCap) revert DepositCapExceeded(asset);
        }

        // Shares rounded DOWN (fewer shares → favors protocol)
        uint256 scaled = (amount * RAY) / r.liquidityIndex;
        scaledDeposits[asset][msg.sender] += scaled;
        r.totalScaledSupply += scaled.toUint128();

        _refreshRate(asset); // supply change → utilization change → recalculate rate
        _pull(asset, msg.sender, amount); // I
        emit Deposited(asset, msg.sender, amount, scaled);
    }

    /// @notice Redeem shares to withdraw principal + interest.
    function withdraw(address asset, uint256 amount) external nonReentrant {
        _requireConfigured(asset);
        if (amount == 0) revert InvalidAmount();

        _accrue(asset);
        DataTypes.ReserveData storage r = reserves[asset];

        uint256 userScaled = scaledDeposits[asset][msg.sender];
        uint256 balance = (userScaled * r.liquidityIndex) / RAY; // actual redeemable (floor)
        if (amount > balance) revert InsufficientBalance();

        // Liquidity check: physically available = balanceOf − locked collateral (see state-transitions §2); question whether totalCollateral could be an issue
        uint256 available = IERC20(asset).balanceOf(address(this)) - totalCollateral[asset];
        if (amount > available) revert InsufficientLiquidity(asset);

        // Shares rounded UP on burn (burn more → favors protocol); clamp to held amount on full withdrawal
        uint256 scaled = (amount * RAY + r.liquidityIndex - 1) / r.liquidityIndex;
        if (scaled > userScaled) scaled = userScaled;
        scaledDeposits[asset][msg.sender] = userScaled - scaled;
        r.totalScaledSupply -= scaled.toUint128();

        _refreshRate(asset); // liquidity withdrawn → utilization rises → recalculate rate
        _push(asset, msg.sender, amount); // I
        emit Withdrawn(asset, msg.sender, amount, scaled);
    }

    /*//////////////////////////////////////////////////////////////
                    Borrower side: openPosition / borrow
    //////////////////////////////////////////////////////////////*/

    /// @notice Open a new position or add collateral and borrow on an existing triplet
    ///         (deposit collateral + borrow in one step).
    function openPosition(
        address collateralAsset,
        uint256 collateralAmount,
        address debtAsset,
        uint256 borrowAmount
    ) external nonReentrant {
        _requireConfigured(collateralAsset);
        _requireConfigured(debtAsset);
        if (collateralAsset == debtAsset) revert SameAsset();
        if (collateralAmount == 0 || borrowAmount == 0) revert InvalidAmount();
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(debtAsset);

        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        _accrue(debtAsset);

        // collateralCap
        DataTypes.AssetConfig storage colCfg = assetConfig[collateralAsset];
        if (colCfg.collateralCap != 0 && totalCollateral[collateralAsset] + collateralAmount > colCfg.collateralCap)
        {
            revert CollateralCapExceeded(collateralAsset);
        }

        // E: write collateral + create position key
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) {
            pos.collateralAsset = collateralAsset;
            pos.debtAsset = debtAsset;
            userPositionKeys[msg.sender].add(key);
        }
        pos.collateralAmount += collateralAmount.toUint128();
        totalCollateral[collateralAsset] += collateralAmount;

        // E: write debt + cap/liquidity check + recalculate rate
        _drawDebt(key, debtAsset, borrowAmount);

        // C: post-effect HF check (effect-then-verify)
        _verifyHealthy(key, collateralAsset, debtAsset);

        // I: pull collateral first, then push borrow (transfers last)
        _pull(collateralAsset, msg.sender, collateralAmount);
        _push(debtAsset, msg.sender, borrowAmount);

        emit Borrowed(msg.sender, collateralAsset, debtAsset, borrowAmount);
    }

    /// @notice Borrow additional debt against an existing position (collateral already in position).
    function borrow(address collateralAsset, address debtAsset, uint256 borrowAmount)
        external
        nonReentrant
    {
        if (borrowAmount == 0) revert InvalidAmount();
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(debtAsset);

        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        if (positions[key].collateralAsset == address(0)) revert PositionNotFound(key);

        _accrue(debtAsset);
        _drawDebt(key, debtAsset, borrowAmount);
        _verifyHealthy(key, collateralAsset, debtAsset);

        _push(debtAsset, msg.sender, borrowAmount); // I
        emit Borrowed(msg.sender, collateralAsset, debtAsset, borrowAmount);
    }

    /*//////////////////////////////////////////////////////////////
                  Collateral: addCollateral / withdrawCollateral
    //////////////////////////////////////////////////////////////*/

    /// @notice Add collateral to an existing position (monotonically improves HF;
    ///         no HF check needed, no index update needed).
    function addCollateral(address collateralAsset, address debtAsset, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);

        DataTypes.AssetConfig storage colCfg = assetConfig[collateralAsset];
        if (colCfg.collateralCap != 0 && totalCollateral[collateralAsset] + amount > colCfg.collateralCap)
        {
            revert CollateralCapExceeded(collateralAsset);
        }

        pos.collateralAmount += amount.toUint128(); // E
        totalCollateral[collateralAsset] += amount;

        _pull(collateralAsset, msg.sender, amount); // I
        emit CollateralAdded(msg.sender, collateralAsset, debtAsset, amount);
    }

    /// @notice Withdraw part of the collateral (risk-increasing operation → effect-then-verify HF post-check).
    function withdrawCollateral(address collateralAsset, address debtAsset, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(collateralAsset);
        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);
        if (amount > pos.collateralAmount) revert InsufficientCollateral();

        _accrue(debtAsset); // HF requires current borrowIndex

        pos.collateralAmount -= amount.toUint128(); // E
        totalCollateral[collateralAsset] -= amount;

        // C: post-effect HF check (skip if no debt — HF is meaningless with no debt)
        if (pos.scaledDebt != 0) {
            _verifyHealthy(key, collateralAsset, debtAsset);
        }

        _closeIfEmpty(key, msg.sender);

        _push(collateralAsset, msg.sender, amount); // I
        emit CollateralWithdrawn(msg.sender, collateralAsset, debtAsset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              repay / liquidate
    //////////////////////////////////////////////////////////////*/

    /// @notice Repay debt (anyone may repay on behalf of any position, permissionlessly).
    ///         Returns the actual amount repaid.
    function repay(address account, address collateralAsset, address debtAsset, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256)
    {
        if (repayAmount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(account, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);

        _accrue(debtAsset);
        DataTypes.ReserveData storage r = reserves[debtAsset];

        uint256 actualDebt = RiskEngine.debtOf(pos.scaledDebt, r.borrowIndex);
        uint256 paid = repayAmount < actualDebt ? repayAmount : actualDebt; // cap to prevent over-repayment

        // Reduce debt: zero out scaled on full repayment; on partial repayment round DOWN (remainder continues to accrue)
        uint256 scaled = paid == actualDebt ? pos.scaledDebt : (paid * RAY) / r.borrowIndex;
        pos.scaledDebt -= scaled.toUint128();
        r.totalScaledBorrow -= scaled.toUint128();

        _closeIfEmpty(key, account);
        _refreshRate(debtAsset);

        _pull(debtAsset, msg.sender, paid); // I
        emit Repaid(msg.sender, account, debtAsset, paid);
        return paid;
    }

    /// @notice Liquidate a position with HF < 1: repay part or all of the debt and
    ///         receive equivalent collateral + bonus.
    function liquidate(
        address account,
        address collateralAsset,
        address debtAsset,
        uint256 repayAmount
    ) external nonReentrant {
        if (repayAmount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(account, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);

        _accrue(debtAsset);
        DataTypes.ReserveData storage r = reserves[debtAsset];

        // HF < 1 check (oracle pause is ignored here: liquidation is always permitted;
        // but getPrice is still subject to staleness constraints)
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        // Liquidation eligibility uses LT (liquidationThreshold)
        uint256 hf = RiskEngine.calculateHealthFactor(
            pos, params.liquidationThreshold, r.borrowIndex, oracle, assetConfig
        );
        if (hf >= WAD) revert PositionHealthy(hf);

        uint256 actualDebt = RiskEngine.debtOf(pos.scaledDebt, r.borrowIndex);

        // closeFactor / seize / collateral-constraint back-calculation — all in Liquidation library
        (uint256 repaid, uint256 seized) = Liquidation.calcLiquidation(
            Liquidation.Params({
                requestedRepay: repayAmount,
                actualDebt: actualDebt,
                hf: hf,
                collateralAmount: pos.collateralAmount,
                collPrice: oracle.getPrice(collateralAsset),
                debtPrice: oracle.getPrice(debtAsset),
                colUnit: 10 ** assetConfig[collateralAsset].decimals,
                debtUnit: 10 ** assetConfig[debtAsset].decimals,
                bonusBps: params.liquidationBonus
            })
        );

        // E: reduce debt (round down; zero out on full repayment)
        uint256 scaledRepaid = repaid == actualDebt ? pos.scaledDebt : (repaid * RAY) / r.borrowIndex;
        if (scaledRepaid > pos.scaledDebt) scaledRepaid = pos.scaledDebt;
        pos.scaledDebt -= scaledRepaid.toUint128();
        r.totalScaledBorrow -= scaledRepaid.toUint128();

        // E: reduce collateral
        pos.collateralAmount -= seized.toUint128();
        totalCollateral[collateralAsset] -= seized;

        // Close-position check (bad-debt residual: collateral==0 && debt>0 will NOT be closed → Layer 3 signal)
        _closeIfEmpty(key, account);
        _refreshRate(debtAsset);

        // I: liquidator repays debt + receives collateral
        _pull(debtAsset, msg.sender, repaid);
        _push(collateralAsset, msg.sender, seized);

        emit Liquidated(msg.sender, account, collateralAsset, debtAsset, repaid, seized);
    }

    /*//////////////////////////////////////////////////////////////
                          Layer 3: bad-debt recapitalization
    //////////////////////////////////////////////////////////////*/

    /// @notice Clear uncollateralized residual debt using protocol funds (architecture.md §7 Layer 3).
    ///         Only callable by owner / insuranceFund, and only when the position's collateral is
    ///         already zero (otherwise normal liquidation should be used).
    function repayBadDebt(address account, address collateralAsset, address debtAsset)
        external
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != owner() && msg.sender != insuranceFund) revert NotAuthorized();
        bytes32 key = Keys.positionKey(account, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);
        if (pos.collateralAmount != 0) revert PositionStillCollateralized(key);

        _accrue(debtAsset);
        DataTypes.ReserveData storage r = reserves[debtAsset];
        uint256 actualDebt = RiskEngine.debtOf(pos.scaledDebt, r.borrowIndex);

        uint256 scaled = pos.scaledDebt;
        pos.scaledDebt = 0;
        r.totalScaledBorrow -= scaled.toUint128();

        _closeIfEmpty(key, account);
        _refreshRate(debtAsset);

        _pull(debtAsset, msg.sender, actualDebt); // recapitalization source repays residual debt
        emit Repaid(msg.sender, account, debtAsset, actualDebt);
        return actualDebt;
    }

    /*//////////////////////////////////////////////////////////////
                              Read-only (UI / tests)
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidation HF for a position (wad, computed with LT → reflects distance to liquidation threshold).
    ///         view does not accrue interest so the value may be slightly stale; returns max if position
    ///         does not exist or has no debt.
    /// @dev Uses the same LT basis as the liquidation check. Open-position gating uses LTV (stricter)
    ///      and is not exposed here.
    function getHealthFactor(address account, address collateralAsset, address debtAsset)
        external
        view
        returns (uint256)
    {
        bytes32 key = Keys.positionKey(account, collateralAsset, debtAsset);
        DataTypes.Position memory pos = positions[key];
        if (pos.collateralAsset == address(0)) return type(uint256).max;
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        return RiskEngine.calculateHealthFactor(
            pos, params.liquidationThreshold, reserves[debtAsset].borrowIndex, oracle, assetConfig
        );
    }

    /*//////////////////////////////////////////////////////////////
                                Internal
    //////////////////////////////////////////////////////////////*/

    function _requireConfigured(address asset) internal view {
        if (!assetConfig[asset].configured) revert AssetNotConfigured(asset);
    }

    /// @notice Accrue interest to the current block (first step of any operation).
    function _accrue(address asset) internal {
        reserves[asset].updateIndexes(assetConfig[asset].reserveFactor);
    }

    /// @notice Recalculate and store the borrow rate using the new utilization (called at end of operations).
    function _refreshRate(address asset) internal {
        DataTypes.ReserveData storage r = reserves[asset];
        uint256 util = r.utilization();
        r.currentBorrowRate =
            RateEngine.calculateBorrowRate(util, assetConfig[asset].fxPremium).toUint128();
        emit ReserveDataUpdated(asset, r.liquidityIndex, r.borrowIndex, r.currentBorrowRate);
    }

    /// @notice Write position debt: cap + liquidity check → scaledDebt rounded UP → recalculate rate.
    function _drawDebt(bytes32 key, address debtAsset, uint256 borrowAmount) internal {
        DataTypes.AssetConfig storage cfg = assetConfig[debtAsset];
        if (!cfg.borrowable) revert AssetNotBorrowable(debtAsset);

        DataTypes.ReserveData storage r = reserves[debtAsset];

        // borrowCap (in underlying terms)
        if (cfg.borrowCap != 0) {
            uint256 totalDebt = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
            if (totalDebt + borrowAmount > cfg.borrowCap) revert BorrowCapExceeded(debtAsset);
        }

        // Lender liquidity check: borrowable = balanceOf − locked collateral
        uint256 available = IERC20(debtAsset).balanceOf(address(this)) - totalCollateral[debtAsset];
        if (borrowAmount > available) revert InsufficientLiquidity(debtAsset);

        uint256 scaled = (borrowAmount * RAY + r.borrowIndex - 1) / r.borrowIndex; // round up (debt rounds up)
        positions[key].scaledDebt += scaled.toUint128();
        r.totalScaledBorrow += scaled.toUint128();

        _refreshRate(debtAsset);
    }

    /// @notice effect-then-verify: compute HF from real storage (gated by LTV); revert if < 1
    ///         (rolls back Effects).
    /// @dev openPosition/borrow/withdrawCollateral use LTV → leaves a safety buffer between
    ///      open-position and liquidation threshold (LT) (architecture.md §2).
    function _verifyHealthy(bytes32 key, address collateralAsset, address debtAsset) internal view {
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        uint256 hf = RiskEngine.calculateHealthFactor(
            positions[key], params.ltv, reserves[debtAsset].borrowIndex, oracle, assetConfig
        );
        if (hf < WAD) revert HealthFactorTooLow(hf);
    }

    /// @notice Close a position when both collateral and debt reach zero: delete + remove from enumerable set.
    function _closeIfEmpty(bytes32 key, address account) internal {
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAmount == 0 && pos.scaledDebt == 0) {
            delete positions[key];
            userPositionKeys[account].remove(key);
            emit PositionClosed(key, account);
        }
    }

    /// @notice Receive payment: verify actual amount received >= expected via balance delta after transfer;
    ///         rejects fee-on-transfer tokens.
    function _pull(address token, address from, uint256 amount) internal {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - balBefore < amount) revert TransferAmountMismatch();
    }

    /// @notice Send payment.
    function _push(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }
}
