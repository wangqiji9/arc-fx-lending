// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*//////////////////////////////////////////////////////////////
                         精度常量（全协议统一，见 architecture.md §八）
//////////////////////////////////////////////////////////////*/

uint256 constant RAY = 1e27; // index（liquidity/borrow）、利率
uint256 constant WAD = 1e18; // HF
uint256 constant BPS = 1e4; // 风险参数（LTV/LT/bonus/closeFactor/reserveFactor）
uint256 constant USD_BASE = 1e8; // 内部 USD 估值 + Chainlink USD feed 精度
uint256 constant SECONDS_PER_YEAR = 365 days;

/*//////////////////////////////////////////////////////////////
                              结构体
//////////////////////////////////////////////////////////////*/

library DataTypes {
    /// @notice 每资产自身风险配置（admin 静态设置）。
    /// @dev 字段按「资产扮演的角色」分三类，别混淆（见 architecture.md §三）：
    ///      ┌ 作【抵押】时（Standard 模式）：ltv / liquidationThreshold / liquidationBonus
    ///      │   —— 这是抵押物侧风险；债务侧资产不看这三个字段。
    ///      │   —— 若 (col,debt) 命中启用的 FX 货币对，这三个会被 fxCategories 那套【覆盖】（E-Mode）。
    ///      ├ 作【债务/借出】时：borrowable / borrowCap / reserveFactor / fxPremium / 利率模型
    ///      │   —— fxPremium 是 per-reserve（非 per-pair）：共享 borrowIndex 无法对不同货币对的
    ///      │      借款人收不同利率，故 FX 借款溢价归属于债务资产本身（见 architecture.md §四.3）。
    ///      └ 两者通用：currency / oracle / decimals / depositCap / collateralCap
    struct AssetConfig {
        bool configured; // 是否已配置（防未初始化资产）
        bool borrowable; // [债务侧] 是否可借（ETH 仅抵押 → false）
        uint8 decimals; // [通用] ERC20 精度（Arc USDC/EURC = 6）
        uint16 ltv; // [抵押侧·Standard] 作抵押的 LTV，bps（FX 对会被 fxCategory 覆盖）
        uint16 liquidationThreshold; // [抵押侧·Standard] 作抵押的 LT，bps
        uint16 liquidationBonus; // [抵押侧·Standard] 清算该抵押的 bonus，bps
        uint16 reserveFactor; // [债务侧] 协议留存，bps（借款利息的百分比，非本金）
        uint16 fxPremium; // [债务侧] 借该资产的 FX 风险溢价，bps（加到 borrowRate；非 FX 资产填 0）
        bytes32 currency; // [通用] 货币码，如 "USD"/"EUR"（FX 风险按货币对查表）
        address oracle; // [通用] 价格 feed（资产/USD）
        uint128 borrowCap; // [债务侧] 总债务上限，native decimals（0 = 不限）
        uint128 collateralCap; // [抵押侧] 作抵押总量上限，native decimals（0 = 不限）
        uint128 depositCap; // [出借侧] 出借存款上限，native decimals（0 = 不限）
    }

    /// @notice 每货币对的 FX 风险配置（key = pairKey(min,max)）。
    /// @dev enabled 时，这套 ltv/LT/bonus 在 resolveParams 里【替换】抵押资产 AssetConfig 的同名字段
    ///      （E-Mode，如 USDC↔EURC 的 90%/94%/2.5%）。风险归属于「货币对」而非单个资产，故独立成表。
    ///      这三个参数按【单个隔离仓位】实时取用（HF/清算），不走共享 index，故 per-pair 没问题。
    ///      利率溢价（fxPremium）则因共享 borrowIndex 的限制改放 AssetConfig（per-reserve）。
    struct FxCategory {
        bool enabled; // 该货币对是否启用 FX E-Mode
        uint16 ltv; // E-Mode LTV，bps（覆盖抵押资产的 AssetConfig.ltv）
        uint16 liquidationThreshold; // E-Mode LT，bps
        uint16 liquidationBonus; // E-Mode 清算 bonus，bps
    }

    /// @notice 每资产内部记账（取消 AToken/DebtToken，全部内部记账）。
    struct ReserveData {
        uint128 liquidityIndex; // 出借侧累积 index，ray（初始 RAY）
        uint128 borrowIndex; // 借款侧累积 index，ray（初始 RAY）
        uint128 totalScaledSupply; // 缩放出借总量，× liquidityIndex = 实际供给
        uint128 totalScaledBorrow; // 缩放债务总量，× borrowIndex = 实际债务
        uint128 currentBorrowRate; // 当前年化借款利率，ray
        uint40 lastUpdateTimestamp; // 上次 updateIndexes 时间戳
    }

    /// @notice 隔离仓位。key = keccak256(owner, collateralAsset, debtAsset)，每三元组唯一。
    /// @dev owner / mode 都不存：owner 编码进 key，mode 由 resolveParams 实时推导。
    struct Position {
        address collateralAsset; // 抵押资产
        address debtAsset; // 债务资产
        uint128 collateralAmount; // 抵押裸数量（不计息，不随 index 变）
        uint128 scaledDebt; // 缩放债务，× borrowIndex(ray) = 实际债务
    }

    /// @notice resolveParams 返回的实时风险参数（不落存储）。
    /// @dev 不含 fxPremium——利率溢价是 per-reserve（AssetConfig.fxPremium），不经此结构。
    struct RiskParams {
        uint16 ltv; // bps
        uint16 liquidationThreshold; // bps
        uint16 liquidationBonus; // bps
        bool isFx; // 是否走 FX E-Mode 参数
    }
}

/*//////////////////////////////////////////////////////////////
                          自定义错误
//////////////////////////////////////////////////////////////*/

// 通用
error ZeroAddress();
error InvalidAmount();
error NotAuthorized();

// 配置 / 资产
error AssetNotConfigured(address asset);
error AssetNotBorrowable(address asset);

// caps
error BorrowCapExceeded(address asset);
error CollateralCapExceeded(address asset);
error DepositCapExceeded(address asset);

// 流动性 / 余额
error InsufficientLiquidity(address asset);
error InsufficientBalance();
error InsufficientCollateral();
error TransferAmountMismatch(); // 实际到账 < 预期（拒绝 fee-on-transfer token）
error SameAsset(); // 抵押与债务为同一资产

// Layer 3
error PositionStillCollateralized(bytes32 key); // 仍有抵押，应走正常清算而非坏账注资

// 仓位 / 健康度
error PositionNotFound(bytes32 key);
error HealthFactorTooLow(uint256 hf); // 操作后 HF < 1
error PositionHealthy(uint256 hf); // 清算时 HF >= 1，不可清算

// 预言机
error StalePrice(address oracle);
error PriceDeviationTooHigh(address asset);
error OraclePaused(address asset);
error InvalidPrice(address asset);
error FeedNotSet(address asset);

/*//////////////////////////////////////////////////////////////
                            事件
//////////////////////////////////////////////////////////////*/

// 出借侧
event Deposited(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount);
event Withdrawn(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount);

// 借款侧
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

// 清算
event Liquidated(
    address indexed liquidator,
    address indexed owner,
    address collateralAsset,
    address debtAsset,
    uint256 repaidAmount,
    uint256 seizedCollateral
);

// 利率 / index
event ReserveDataUpdated(
    address indexed asset, uint256 liquidityIndex, uint256 borrowIndex, uint256 borrowRate
);
