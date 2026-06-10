// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

import {PoolStorage} from "./PoolStorage.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Keys} from "./libraries/Keys.sol";
import {RateEngine} from "./libraries/RateEngine.sol";
import {RiskEngine} from "./libraries/RiskEngine.sol";
import {Liquidation} from "./libraries/Liquidation.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";
import {AgentTypes} from "./libraries/AgentTypes.sol";
import "./libraries/DataTypes.sol"; // DataTypes library + constants + file-level errors/events

/// @title LendingPool
/// @notice The protocol's sole external entry point (architecture.md §4.2). Inherits exclusive state
///         from PoolStorage, delegates to stateless libraries RateEngine/RiskEngine/Liquidation,
///         and calls the external PriceOracle contract.
///         All real token transfers happen here; CEI is strictly observed; risk-increasing operations
///         use effect-then-verify.
/// @dev Roles: lender (deposit/withdraw, earns interest) and borrower (openPosition/borrow/...,
///      isolated positions).
///
///      Multicall (OZ): lets an agent batch several calls (e.g. addCollateral + borrow) atomically
///      in one transaction. Each sub-call is a delegatecall to `this`, executed sequentially (not
///      nested), so it composes with `nonReentrant`; `msg.sender` is preserved across the batch, so
///      positions stay attributed to the agent.
///
///      ⚠️ MULTICALL SAFETY INVARIANT — DO NOT BREAK (docs/findings.md §D-1 ③):
///      The protocol has NO payable entry points. The classic OZ Multicall vulnerability (a payable
///      function reading msg.value, replayed across delegatecall loop iterations so one msg.value is
///      "spent" N times) therefore CANNOT occur here. If a future change makes ANY entry payable
///      (e.g. to forward fees to Pyth's payable updatePriceFeeds), Multicall instantly becomes a
///      high-severity bug: either add explicit msg.value accounting/guards or remove Multicall.
contract LendingPool is PoolStorage, ReentrancyGuard, Ownable, Multicall {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using RateEngine for DataTypes.ReserveData;
    using WadRayMath for uint256;
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

        // Liquidity check: physically available = balanceOf − locked collateral (see state-transitions §2)
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
    function openPosition(address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 borrowAmount)
        external
        nonReentrant
    {
        _requireConfigured(collateralAsset);
        _requireConfigured(debtAsset);
        if (collateralAsset == debtAsset) revert SameAsset();
        if (collateralAmount == 0 || borrowAmount == 0) revert InvalidAmount();
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(debtAsset);

        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        _accrue(debtAsset);

        // collateralCap
        DataTypes.AssetConfig storage colCfg = assetConfig[collateralAsset];
        if (colCfg.collateralCap != 0 && totalCollateral[collateralAsset] + collateralAmount > colCfg.collateralCap) {
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

        // C: post-effect HF check (effect-then-verify), gated by LTV to control initial borrow limits
        _verifyHealthy(key, collateralAsset, debtAsset, true);

        // I: pull collateral first, then push borrow (transfers last)
        _pull(collateralAsset, msg.sender, collateralAmount);
        _push(debtAsset, msg.sender, borrowAmount);

        emit Borrowed(msg.sender, collateralAsset, debtAsset, borrowAmount);
    }

    /// @notice Borrow additional debt against an existing position (collateral already in position).
    function borrow(address collateralAsset, address debtAsset, uint256 borrowAmount) external nonReentrant {
        if (borrowAmount == 0) revert InvalidAmount();
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(debtAsset);

        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        if (positions[key].collateralAsset == address(0)) revert PositionNotFound(key);

        _accrue(debtAsset);
        _drawDebt(key, debtAsset, borrowAmount);
        _verifyHealthy(key, collateralAsset, debtAsset, true);

        _push(debtAsset, msg.sender, borrowAmount); // I
        emit Borrowed(msg.sender, collateralAsset, debtAsset, borrowAmount);
    }

    /*//////////////////////////////////////////////////////////////
                  Collateral: addCollateral / withdrawCollateral
    //////////////////////////////////////////////////////////////*/

    /// @notice Add collateral to an existing position (monotonically improves HF;
    ///         no HF check needed, no index update needed).
    function addCollateral(address collateralAsset, address debtAsset, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);

        DataTypes.AssetConfig storage colCfg = assetConfig[collateralAsset];
        if (colCfg.collateralCap != 0 && totalCollateral[collateralAsset] + amount > colCfg.collateralCap) {
            revert CollateralCapExceeded(collateralAsset);
        }

        pos.collateralAmount += amount.toUint128(); // E
        totalCollateral[collateralAsset] += amount;

        _pull(collateralAsset, msg.sender, amount); // I
        emit CollateralAdded(msg.sender, collateralAsset, debtAsset, amount);
    }

    /// @notice Withdraw part of the collateral (risk-increasing operation → effect-then-verify HF post-check).
    function withdrawCollateral(address collateralAsset, address debtAsset, uint256 amount) external nonReentrant {
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
        // Uses LT (not LTV) — consistent with liquidation threshold (M-4)
        if (pos.scaledDebt != 0) {
            _verifyHealthy(key, collateralAsset, debtAsset, false);
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
    /// @param minCollateralOut Liquidator slippage guard: the call reverts if the collateral
    ///        actually seized is below this amount. The seize value is derived from the oracle
    ///        price at execution time, so a price move between submission and execution changes
    ///        the payout; this bounds the liquidator's downside. Pass 0 to disable the guard.
    function liquidate(
        address account,
        address collateralAsset,
        address debtAsset,
        uint256 repayAmount,
        uint256 minCollateralOut
    ) external nonReentrant {
        if (repayAmount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(account, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);

        // Oracle pause gate: untrustworthy prices must block liquidation to prevent
        // seizing collateral from positions that may actually be healthy.
        if (oracle.isPaused(collateralAsset) || oracle.isPaused(debtAsset)) revert OraclePaused(collateralAsset);

        _accrue(debtAsset);
        DataTypes.ReserveData storage r = reserves[debtAsset];

        // HF < 1 check
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        // Liquidation eligibility uses LT (liquidationThreshold)
        uint256 hf =
            RiskEngine.calculateHealthFactor(pos, params.liquidationThreshold, r.borrowIndex, oracle, assetConfig);
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
                bonusBps: params.liquidationBonus,
                isFx: params.isFx
            })
        );

        // Liquidator slippage guard: bound the downside from oracle price moves between
        // submission and execution. Checked before state changes (fail-fast).
        if (seized < minCollateralOut) revert InsufficientCollateralSeized(seized, minCollateralOut);

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
                    Agent decision layer (view, docs/findings.md §D-1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Current borrow and supply rates for an asset (both ray, annualized).
    /// @dev view does not accrue, so values reflect the last on-chain operation (the borrow rate does
    ///      not drift between accruals — it only changes when an operation calls _refreshRate).
    ///      supplyRate uses the SAME RateEngine.calculateSupplyRate that updateIndexes compounds with,
    ///      so the rate an agent reads equals the rate actually accrued.
    /// @return borrowRate annualized borrow rate (ray)
    /// @return supplyRate annualized lender supply rate (ray)
    function viewRates(address asset) public view returns (uint256 borrowRate, uint256 supplyRate) {
        DataTypes.ReserveData storage r = reserves[asset];
        uint256 util = RateEngine.utilization(r);
        borrowRate = r.currentBorrowRate;
        supplyRate = RateEngine.calculateSupplyRate(borrowRate, util, assetConfig[asset].reserveFactor);
    }

    /// @notice Discover every valid (collateral, debt) market the agent can act on in one call.
    /// @dev Iterates the existing reservesList (no new registry). A combination is included when:
    ///      collateral ≠ debt, the debt asset is borrowable, and the resolved LTV > 0 (a 0 LTV means
    ///      the asset cannot back a borrow). ltv / liquidationThreshold are resolved (FX E-Mode or
    ///      Standard) per pair. See AgentTypes.MarketInfo for field semantics — in particular,
    ///      collateralSupplyRate is the asset's market lender rate, NOT locked-collateral yield.
    function getAvailableMarkets() external view returns (AgentTypes.MarketInfo[] memory markets) {
        address[] memory assets = reservesList.values();
        uint256 n = assets.length;

        // First pass: count valid combinations (so we can return a tight array).
        uint256 count;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                if (i == j) continue;
                if (_isValidMarket(assets[i], assets[j])) ++count;
            }
        }

        markets = new AgentTypes.MarketInfo[](count);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            address col = assets[i];
            (, uint256 colSupplyRate) = viewRates(col);
            for (uint256 j; j < n; ++j) {
                if (i == j) continue;
                address debt = assets[j];
                if (!_isValidMarket(col, debt)) continue;

                DataTypes.RiskParams memory p = RiskEngine.resolveParams(assetConfig, fxCategories, col, debt);
                (uint256 debtBorrowRate,) = viewRates(debt);

                markets[k++] = AgentTypes.MarketInfo({
                    collateralAsset: col,
                    debtAsset: debt,
                    ltv: p.ltv,
                    liquidationThreshold: p.liquidationThreshold,
                    debtBorrowRate: debtBorrowRate,
                    collateralSupplyRate: colSupplyRate,
                    availableLiquidity: _availableLiquidity(debt),
                    isFxMode: p.isFx
                });
            }
        }
    }

    /// @notice Real-time risk snapshot for one position by key.
    /// @dev HF comes from RiskEngine.calculateHealthFactor on the LT basis — the SAME path liquidate()
    ///      uses — so this never disagrees with the on-chain liquidation check. liquidationPrice is
    ///      reported only in Standard mode (single-direction collateral-price drop); FX E-Mode reports
    ///      bufferBps instead (see AgentTypes / docs/findings.md §D-1 ②). view does not accrue, so HF
    ///      may be marginally stale (same caveat as getHealthFactor).
    function getPositionRisk(bytes32 key) public view returns (AgentTypes.PositionRisk memory risk) {
        risk.key = key;
        DataTypes.Position memory pos = positions[key];
        if (pos.collateralAsset == address(0)) {
            return risk; // exists = false, all fields zero
        }
        risk.exists = true;

        address col = pos.collateralAsset;
        address debt = pos.debtAsset;
        uint256 borrowIndex = reserves[debt].borrowIndex;

        DataTypes.RiskParams memory p = RiskEngine.resolveParams(assetConfig, fxCategories, col, debt);
        uint256 hf = RiskEngine.calculateHealthFactor(pos, p.liquidationThreshold, borrowIndex, oracle, assetConfig);

        risk.healthFactor = hf;
        risk.bufferBps = _bufferBps(hf);
        risk.currentDebt = RiskEngine.debtOf(pos.scaledDebt, borrowIndex);

        // Collateral / debt USD valuations: reuse the exact rounding of calculateHealthFactor.
        uint256 colPrice = oracle.getPrice(col);
        uint256 colUnit = 10 ** assetConfig[col].decimals;
        risk.collateralValue = (uint256(pos.collateralAmount) * colPrice) / colUnit;
        if (pos.scaledDebt != 0) {
            uint256 debtPrice = oracle.getPrice(debt);
            uint256 debtUnit = 10 ** assetConfig[debt].decimals;
            risk.debtValue = RiskEngine.mulDivUp(risk.currentDebt, debtPrice, debtUnit);
        }

        bool hasDebt = pos.scaledDebt != 0;
        risk.liquidationPriceApplicable = hasDebt && !p.isFx;
        if (risk.liquidationPriceApplicable) {
            risk.liquidationPrice =
                _standardLiquidationPrice(risk.debtValue, pos.collateralAmount, p.liquidationThreshold, colUnit);
        }

        (uint256 debtBorrowRate,) = viewRates(debt);
        (, uint256 colSupplyRate) = viewRates(col);
        risk.debtBorrowRate = debtBorrowRate;
        risk.collateralSupplyRate = colSupplyRate;
    }

    /// @notice Batch version of getPositionRisk.
    function batchGetPositionRisk(bytes32[] calldata keys)
        external
        view
        returns (AgentTypes.PositionRisk[] memory out)
    {
        out = new AgentTypes.PositionRisk[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            out[i] = getPositionRisk(keys[i]);
        }
    }

    /// @notice Simulate opening (collateralAsset, collateralAmount, debtAsset, borrowAmount) without
    ///         changing state, returning the resulting risk and the rate the agent would actually pay.
    /// @dev Both HFs come from RiskEngine.calculateHealthFactor (LTV basis = the open gate, LT basis =
    ///      risk distance) — no parallel formula, so preview cannot claim "healthy" while a real open
    ///      reverts. borrowRate is computed at the POST-open utilization (the rate the agent will pay
    ///      after borrowing), not the current one. Reverts only on misconfiguration (unconfigured /
    ///      same-asset); an unhealthy or illiquid request returns openable = false rather than reverting.
    function previewPosition(address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 borrowAmount)
        external
        view
        returns (AgentTypes.PreviewResult memory res)
    {
        _requireConfigured(collateralAsset);
        _requireConfigured(debtAsset);
        if (collateralAsset == debtAsset) revert SameAsset();

        DataTypes.ReserveData storage r = reserves[debtAsset];
        uint256 borrowIndex = r.borrowIndex;

        // Build an in-memory position; debt scaled up (debt rounds up), matching _drawDebt.
        DataTypes.Position memory pos = DataTypes.Position({
            collateralAsset: collateralAsset,
            debtAsset: debtAsset,
            collateralAmount: collateralAmount.toUint128(),
            scaledDebt: ((borrowAmount * RAY + borrowIndex - 1) / borrowIndex).toUint128()
        });

        DataTypes.RiskParams memory p = RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);

        uint256 ltvHf = RiskEngine.calculateHealthFactor(pos, p.ltv, borrowIndex, oracle, assetConfig);
        uint256 ltHf = RiskEngine.calculateHealthFactor(pos, p.liquidationThreshold, borrowIndex, oracle, assetConfig);

        res.healthFactor = ltHf;
        res.ltvHealthFactor = ltvHf;
        res.bufferBps = _bufferBps(ltHf);
        res.isFxMode = p.isFx;

        uint256 avail = _availableLiquidity(debtAsset);
        res.availableLiquidity = avail;
        res.openable = ltvHf >= WAD && borrowAmount <= avail && assetConfig[debtAsset].borrowable;

        bool hasDebt = borrowAmount != 0;
        res.liquidationPriceApplicable = hasDebt && !p.isFx;
        if (res.liquidationPriceApplicable) {
            uint256 debtPrice = oracle.getPrice(debtAsset);
            uint256 debtUnit = 10 ** assetConfig[debtAsset].decimals;
            uint256 debtAmount = RiskEngine.debtOf(pos.scaledDebt, borrowIndex);
            uint256 debtValue = RiskEngine.mulDivUp(debtAmount, debtPrice, debtUnit);
            uint256 colUnit = 10 ** assetConfig[collateralAsset].decimals;
            res.liquidationPrice =
                _standardLiquidationPrice(debtValue, pos.collateralAmount, p.liquidationThreshold, colUnit);
        }

        // borrowRate at post-open utilization: recompute with the simulated extra debt.
        uint256 postUtil = _utilizationWithExtraBorrow(debtAsset, borrowAmount);
        res.borrowRate = RateEngine.calculateBorrowRate(postUtil, assetConfig[debtAsset].fxPremium);
        (, res.collateralSupplyRate) = viewRates(collateralAsset);
    }

    /*//////////////////////////////////////////////////////////////
                    Agent decision layer — internal helpers (view)
    //////////////////////////////////////////////////////////////*/

    /// @notice A (col, debt) pair is a valid market when assets differ, debt is borrowable, and the
    ///         resolved collateral LTV > 0 (LTV 0 → cannot back a borrow).
    function _isValidMarket(address col, address debt) internal view returns (bool) {
        if (col == debt) return false;
        if (!assetConfig[col].configured || !assetConfig[debt].configured) return false;
        if (!assetConfig[debt].borrowable) return false;
        DataTypes.RiskParams memory p = RiskEngine.resolveParams(assetConfig, fxCategories, col, debt);
        return p.ltv > 0;
    }

    /// @notice Borrowable liquidity right now = pool balance − locked collateral (matches _drawDebt).
    function _availableLiquidity(address asset) internal view returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 locked = totalCollateral[asset];
        return bal > locked ? bal - locked : 0;
    }

    /// @notice Relative safety buffer in bps = (HF − 1e18) × BPS / 1e18; 0 when HF ≤ 1e18.
    /// @dev type(uint256).max (no debt) maps to 0 — a debtless position has no liquidation distance to report.
    function _bufferBps(uint256 hf) internal pure returns (uint256) {
        if (hf == type(uint256).max) return 0;
        if (hf <= WAD) return 0;
        return ((hf - WAD) * BPS) / WAD;
    }

    /// @notice Standard-mode liquidation price (1e8): the collateral price at which HF = 1e18.
    /// @dev Inverts calculateHealthFactor for the single direction "collateral price drops":
    ///        HF = (colAmt × price / colUnit × LT / BPS) × WAD / debtValue = WAD
    ///      ⇒ price = debtValue × BPS × colUnit / (colAmt × LT). Rounded UP so the reported price is
    ///      marginally conservative (feeding it back makes HF ≤ 1e18 → liquidatable; see D-1 consistency test).
    ///      Returns 0 if collateral or LT is 0.
    function _standardLiquidationPrice(
        uint256 debtValue,
        uint256 collateralAmount,
        uint16 liquidationThreshold,
        uint256 colUnit
    ) internal pure returns (uint256) {
        if (collateralAmount == 0 || liquidationThreshold == 0 || debtValue == 0) return 0;
        uint256 denom = collateralAmount * liquidationThreshold;
        return (debtValue * BPS * colUnit + denom - 1) / denom;
    }

    /// @notice Utilization if `extraBorrow` more debt were drawn now (for previewPosition's post-open rate).
    /// @dev Mirrors RateEngine.utilization but adds extraBorrow to the debt side at the current index.
    function _utilizationWithExtraBorrow(address asset, uint256 extraBorrow) internal view returns (uint256) {
        DataTypes.ReserveData storage r = reserves[asset];
        uint256 totalSupply = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        if (totalSupply == 0) return 0;
        uint256 totalBorrow = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY + extraBorrow;
        return (totalBorrow * RAY) / totalSupply;
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
        r.currentBorrowRate = RateEngine.calculateBorrowRate(util, assetConfig[asset].fxPremium).toUint128();
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

    /// @notice effect-then-verify: compute HF from real storage; revert if < 1 (rolls back Effects).
    /// @dev openPosition/borrow pass useLtv=true → LTV gating (caps initial borrow).
    ///      withdrawCollateral passes useLtv=false → LT gating (consistent with the liquidation
    ///      check, so positions can still be adjusted above the LT line after borrowing to the LTV cap).
    function _verifyHealthy(bytes32 key, address collateralAsset, address debtAsset, bool useLtv) internal view {
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        uint256 threshold = useLtv ? params.ltv : params.liquidationThreshold;
        uint256 hf = RiskEngine.calculateHealthFactor(
            positions[key], threshold, reserves[debtAsset].borrowIndex, oracle, assetConfig
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
