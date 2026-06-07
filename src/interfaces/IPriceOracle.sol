// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice LendingPool / RiskEngine / Liquidation 取价的统一入口。
/// @dev 价格统一为 1e8 USD base（architecture.md §八）。EURC 等非美元资产的价格
///      已把 FX 风险编码进 USD 报价（EURC ≈ 1.08e8），故核心 HF 数学只需 getPrice。
interface IPriceOracle {
    /// @notice 资产的 USD 价格，1e8 base。stale / 非正数 / 无 feed 时 revert。
    /// @dev 不因 paused 而 revert——repay/liquidate 在暂停期仍需取价（见 architecture.md §四.6）。
    function getPrice(address asset) external view returns (uint256);

    /// @notice 该资产是否被 guardian 熔断暂停（脱锚等异常）。
    /// @dev 暂停只挡新 borrow/deposit；repay/liquidate 由调用方选择忽略本标志。
    function isPaused(address asset) external view returns (bool);
}
