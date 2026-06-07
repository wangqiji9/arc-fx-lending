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
import "./libraries/DataTypes.sol"; // DataTypes 库 + 常量 + file-level 错误/事件

/// @title LendingPool
/// @notice 协议唯一对外入口(architecture.md §四.2)。继承 PoolStorage 独占状态,
///         调用 RateEngine/RiskEngine/Liquidation(无状态 library)与 PriceOracle(外部合约)。
///         所有真实 token 转账在此,严格遵守 CEI;让仓位变危险的操作用 effect-then-verify。
/// @dev 角色:出借人(deposit/withdraw,计息) 与 借款人(openPosition/borrow/...,隔离仓位)。
contract LendingPool is PoolStorage, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using RateEngine for DataTypes.ReserveData;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice 价格源。
    IPriceOracle public oracle;

    /// @notice Layer 3 坏账注资来源(architecture.md §七)。由它对无抵押残债 repay。
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

    /// @notice 配置/更新资产。首次配置时把 index 初始化为 RAY 并加入 reservesList。
    function configureAsset(address asset, DataTypes.AssetConfig calldata cfg) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        assetConfig[asset] = cfg;
        assetConfig[asset].configured = true; // 强制标记,避免 admin 漏填

        DataTypes.ReserveData storage r = reserves[asset];
        if (r.liquidityIndex == 0) {
            r.liquidityIndex = RAY.toUint128();
            r.borrowIndex = RAY.toUint128();
            r.lastUpdateTimestamp = block.timestamp.toUint40();
            reservesList.add(asset);
        }
        emit AssetConfigured(asset);
    }

    /// @notice 配置货币对 FX E-Mode 参数。
    function configureFxCategory(bytes32 currencyA, bytes32 currencyB, DataTypes.FxCategory calldata fx)
        external
        onlyOwner
    {
        bytes32 pk = Keys.pairKey(currencyA, currencyB);
        fxCategories[pk] = fx;
        emit FxCategoryConfigured(pk);
    }

    /*//////////////////////////////////////////////////////////////
                          出借侧:deposit / withdraw
    //////////////////////////////////////////////////////////////*/

    /// @notice 出借流动性,换取随 liquidityIndex 计息的份额。
    function deposit(address asset, uint256 amount) external nonReentrant {
        _requireConfigured(asset);
        if (amount == 0) revert InvalidAmount();
        if (oracle.isPaused(asset)) revert OraclePaused(asset); // 暂停挡新 supply

        _accrue(asset);
        DataTypes.ReserveData storage r = reserves[asset];
        DataTypes.AssetConfig storage cfg = assetConfig[asset];

        // depositCap(underlying 计,与 borrowCap 对齐)
        if (cfg.depositCap != 0) {
            uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
            if (supplied + amount > cfg.depositCap) revert DepositCapExceeded(asset);
        }

        // 份额【向下】取整(份额少 → 协议有利)
        uint256 scaled = (amount * RAY) / r.liquidityIndex;
        scaledDeposits[asset][msg.sender] += scaled;
        r.totalScaledSupply += scaled.toUint128();

        _refreshRate(asset); // 供给变化 → 利用率变 → 重算利率
        _pull(asset, msg.sender, amount); // I
        emit Deposited(asset, msg.sender, amount, scaled);
    }

    /// @notice 赎回份额,取走本金 + 利息。
    function withdraw(address asset, uint256 amount) external nonReentrant {
        _requireConfigured(asset);
        if (amount == 0) revert InvalidAmount();

        _accrue(asset);
        DataTypes.ReserveData storage r = reserves[asset];

        uint256 userScaled = scaledDeposits[asset][msg.sender];
        uint256 balance = (userScaled * r.liquidityIndex) / RAY; // 实际可赎回(floor)
        if (amount > balance) revert InsufficientBalance();

        // 流动性检查:物理可出借 = balanceOf − 锁定抵押(见 state-transitions §2)
        uint256 available = IERC20(asset).balanceOf(address(this)) - totalCollateral[asset];
        if (amount > available) revert InsufficientLiquidity(asset);

        // 份额【向上】取整(burn 更多 → 协议有利),全额赎回时夹紧到持有量
        uint256 scaled = (amount * RAY + r.liquidityIndex - 1) / r.liquidityIndex;
        if (scaled > userScaled) scaled = userScaled;
        scaledDeposits[asset][msg.sender] = userScaled - scaled;
        r.totalScaledSupply -= scaled.toUint128();

        _refreshRate(asset); // 抽走流动性 → 利用率上升 → 重算利率
        _push(asset, msg.sender, amount); // I
        emit Withdrawn(asset, msg.sender, amount, scaled);
    }

    /*//////////////////////////////////////////////////////////////
                    借款侧:openPosition / borrow
    //////////////////////////////////////////////////////////////*/

    /// @notice 首次开仓或在同一三元组上加抵押并借款(存抵押 + 借款一步)。
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

        // E:写抵押 + 建仓位 key
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) {
            pos.collateralAsset = collateralAsset;
            pos.debtAsset = debtAsset;
            userPositionKeys[msg.sender].add(key);
        }
        pos.collateralAmount += collateralAmount.toUint128();
        totalCollateral[collateralAsset] += collateralAmount;

        // E:写债务 + cap/流动性检查 + 重算利率
        _drawDebt(key, debtAsset, borrowAmount);

        // C:HF 后检(effect-then-verify)
        _verifyHealthy(key, collateralAsset, debtAsset);

        // I:先拉抵押,再放借款(转账放最后)
        _pull(collateralAsset, msg.sender, collateralAmount);
        _push(debtAsset, msg.sender, borrowAmount);

        emit Borrowed(msg.sender, collateralAsset, debtAsset, borrowAmount);
    }

    /// @notice 在已有仓位上追加借款(抵押已在仓位中)。
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
                  抵押:addCollateral / withdrawCollateral
    //////////////////////////////////////////////////////////////*/

    /// @notice 向已有仓位追加抵押(单调改善 HF,无需 HF 检查、无需 updateIndexes)。
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

    /// @notice 取出部分抵押(让仓位变危险 → effect-then-verify HF 后检)。
    function withdrawCollateral(address collateralAsset, address debtAsset, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        bytes32 key = Keys.positionKey(msg.sender, collateralAsset, debtAsset);
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAsset == address(0)) revert PositionNotFound(key);
        if (amount > pos.collateralAmount) revert InsufficientCollateral();

        _accrue(debtAsset); // HF 需要当前 borrowIndex

        pos.collateralAmount -= amount.toUint128(); // E
        totalCollateral[collateralAsset] -= amount;

        // C:HF 后检(无债务时 HF 无意义,跳过)
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

    /// @notice 归还债务(任何人可替任意仓位还,无需许可)。返回实际偿还量。
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
        uint256 paid = repayAmount < actualDebt ? repayAmount : actualDebt; // 截断防超还

        // 减债务:全额还清直接清空 scaled;部分还【向下】取整(余量继续计息)
        uint256 scaled = paid == actualDebt ? pos.scaledDebt : (paid * RAY) / r.borrowIndex;
        pos.scaledDebt -= scaled.toUint128();
        r.totalScaledBorrow -= scaled.toUint128();

        _closeIfEmpty(key, account);
        _refreshRate(debtAsset);

        _pull(debtAsset, msg.sender, paid); // I
        emit Repaid(msg.sender, account, debtAsset, paid);
        return paid;
    }

    /// @notice 清算 HF<1 的仓位:还部分/全部债务,获等值抵押 + bonus。
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

        // HF<1 校验(忽略 oracle pause:清算永远放行;但 getPrice 仍受 staleness 约束)
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        // 清算判定用 LT(liquidationThreshold)
        uint256 hf = RiskEngine.calculateHealthFactor(
            pos, params.liquidationThreshold, r.borrowIndex, oracle, assetConfig
        );
        if (hf >= WAD) revert PositionHealthy(hf);

        uint256 actualDebt = RiskEngine.debtOf(pos.scaledDebt, r.borrowIndex);

        // closeFactor / seize / 抵押约束反推 —— 全在 Liquidation library
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

        // E:减债务(向下取整;全额则清空)
        uint256 scaledRepaid = repaid == actualDebt ? pos.scaledDebt : (repaid * RAY) / r.borrowIndex;
        if (scaledRepaid > pos.scaledDebt) scaledRepaid = pos.scaledDebt;
        pos.scaledDebt -= scaledRepaid.toUint128();
        r.totalScaledBorrow -= scaledRepaid.toUint128();

        // E:减抵押
        pos.collateralAmount -= seized.toUint128();
        totalCollateral[collateralAsset] -= seized;

        // 关仓检查(坏账残仓 collateral==0 && debt>0 不会被关 → Layer 3 信号)
        _closeIfEmpty(key, account);
        _refreshRate(debtAsset);

        // I:清算人还债 + 拿抵押
        _pull(debtAsset, msg.sender, repaid);
        _push(collateralAsset, msg.sender, seized);

        emit Liquidated(msg.sender, account, collateralAsset, debtAsset, repaid, seized);
    }

    /*//////////////////////////////////////////////////////////////
                          Layer 3:坏账注资
    //////////////////////////////////////////////////////////////*/

    /// @notice 用协议资金清掉无抵押残债(architecture.md §七 Layer 3)。
    ///         仅 owner / insuranceFund 可调,且仓位抵押必须已为 0(否则应走正常清算)。
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

        _pull(debtAsset, msg.sender, actualDebt); // 注资方还清残债
        emit Repaid(msg.sender, account, debtAsset, actualDebt);
        return actualDebt;
    }

    /*//////////////////////////////////////////////////////////////
                              只读(UI/测试)
    //////////////////////////////////////////////////////////////*/

    /// @notice 仓位清算 HF(wad,以 LT 计 → 反映距离清算线)。view 不滚利息可能略旧;无仓位/无债务返回 max。
    /// @dev 与清算判定同口径(LT)。开仓门控用的是 LTV,会更严格,不在此暴露。
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
                                内部
    //////////////////////////////////////////////////////////////*/

    function _requireConfigured(address asset) internal view {
        if (!assetConfig[asset].configured) revert AssetNotConfigured(asset);
    }

    /// @notice 滚利息到当前区块(操作第一步)。
    function _accrue(address asset) internal {
        reserves[asset].updateIndexes(assetConfig[asset].reserveFactor);
    }

    /// @notice 用新利用率重算借款利率并写回(操作末尾)。
    function _refreshRate(address asset) internal {
        DataTypes.ReserveData storage r = reserves[asset];
        uint256 util = r.utilization();
        r.currentBorrowRate =
            RateEngine.calculateBorrowRate(util, assetConfig[asset].fxPremium).toUint128();
        emit ReserveDataUpdated(asset, r.liquidityIndex, r.borrowIndex, r.currentBorrowRate);
    }

    /// @notice 写仓位债务:cap + 流动性检查 → scaledDebt 向上取整 → 重算利率。
    function _drawDebt(bytes32 key, address debtAsset, uint256 borrowAmount) internal {
        DataTypes.AssetConfig storage cfg = assetConfig[debtAsset];
        if (!cfg.borrowable) revert AssetNotBorrowable(debtAsset);

        DataTypes.ReserveData storage r = reserves[debtAsset];

        // borrowCap(underlying)
        if (cfg.borrowCap != 0) {
            uint256 totalDebt = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
            if (totalDebt + borrowAmount > cfg.borrowCap) revert BorrowCapExceeded(debtAsset);
        }

        // 出借流动性检查:可借 = balanceOf − 锁定抵押
        uint256 available = IERC20(debtAsset).balanceOf(address(this)) - totalCollateral[debtAsset];
        if (borrowAmount > available) revert InsufficientLiquidity(debtAsset);

        uint256 scaled = (borrowAmount * RAY + r.borrowIndex - 1) / r.borrowIndex; // 向上取整(债务向上)
        positions[key].scaledDebt += scaled.toUint128();
        r.totalScaledBorrow += scaled.toUint128();

        _refreshRate(debtAsset);
    }

    /// @notice effect-then-verify:用真实 storage 算 HF(以 LTV 门控),< 1 则 revert(回滚 Effects)。
    /// @dev 开仓/借款/取抵押用 LTV → 开仓后到清算线(LT)留安全垫(architecture.md §二)。
    function _verifyHealthy(bytes32 key, address collateralAsset, address debtAsset) internal view {
        DataTypes.RiskParams memory params =
            RiskEngine.resolveParams(assetConfig, fxCategories, collateralAsset, debtAsset);
        uint256 hf = RiskEngine.calculateHealthFactor(
            positions[key], params.ltv, reserves[debtAsset].borrowIndex, oracle, assetConfig
        );
        if (hf < WAD) revert HealthFactorTooLow(hf);
    }

    /// @notice 抵押与债务均归零时关仓:delete + 从枚举集移除。
    function _closeIfEmpty(bytes32 key, address account) internal {
        DataTypes.Position storage pos = positions[key];
        if (pos.collateralAmount == 0 && pos.scaledDebt == 0) {
            delete positions[key];
            userPositionKeys[account].remove(key);
            emit PositionClosed(key, account);
        }
    }

    /// @notice 收款:转入后用余额差校验实际到账 ≥ 预期,拒绝 fee-on-transfer token。
    function _pull(address token, address from, uint256 amount) internal {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - balBefore < amount) revert TransferAmountMismatch();
    }

    /// @notice 付款。
    function _push(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }
}
