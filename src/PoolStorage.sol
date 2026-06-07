// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Keys} from "./libraries/Keys.sol";

/// @title PoolStorage
/// @notice 协议的唯一状态持有者（方案 C，见 architecture.md §一）。
///         RateEngine/RiskEngine/Liquidation 是无状态 library；只有继承本合约的
///         LendingPool 读写这些 slot。本合约只放存储 + key 计算 + 只读 getter，无业务逻辑。
abstract contract PoolStorage {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                 状态
    //////////////////////////////////////////////////////////////*/

    /// @notice 每资产自身风险配置（admin 设置）。
    mapping(address asset => DataTypes.AssetConfig) internal assetConfig;

    /// @notice 每货币对的 FX 风险配置。key = pairKey(min(curA,curB), max(curA,curB))。
    mapping(bytes32 pairKey => DataTypes.FxCategory) internal fxCategories;

    /// @notice 每资产内部记账（index / 总量 / 利率 / 时间戳）。
    mapping(address asset => DataTypes.ReserveData) internal reserves;

    /// @notice 出借侧记账：asset => user => 缩放存款（× liquidityIndex = 实际可赎回）。
    mapping(address asset => mapping(address user => uint256 scaledDeposit)) internal scaledDeposits;

    /// @notice 隔离仓位。key = positionKey(owner, collateralAsset, debtAsset)。
    mapping(bytes32 key => DataTypes.Position) internal positions;

    /// @notice 某资产作抵押的总裸数量（不计息）。用于 collateralCap + 余额不变量。
    mapping(address asset => uint256) internal totalCollateral;

    /// @notice 用户持有的仓位 key 集合（开仓加入、关仓移除）。UI + invariant 枚举用。
    mapping(address user => EnumerableSet.Bytes32Set) internal userPositionKeys;

    /// @notice 已配置资产集合（enumerate reserves，invariant/caps 用）。
    EnumerableSet.AddressSet internal reservesList;

    /*//////////////////////////////////////////////////////////////
                            key 计算（pure）
    //////////////////////////////////////////////////////////////*/

    /// @notice 仓位确定性 key：每个 (owner, 抵押, 债务) 三元组唯一。委托 Keys（单一来源）。
    function positionKey(address owner, address collateralAsset, address debtAsset)
        public
        pure
        returns (bytes32)
    {
        return Keys.positionKey(owner, collateralAsset, debtAsset);
    }

    /// @notice 货币对 key：与顺序无关（min,max 归一），USD↔EUR 与 EUR↔USD 命中同一条。
    function pairKey(bytes32 currencyA, bytes32 currencyB) public pure returns (bytes32) {
        return Keys.pairKey(currencyA, currencyB);
    }

    /*//////////////////////////////////////////////////////////////
                          只读 getter（UI / 测试）
    //////////////////////////////////////////////////////////////*/

    function getAssetConfig(address asset) external view returns (DataTypes.AssetConfig memory) {
        return assetConfig[asset];
    }

    function getFxCategory(bytes32 currencyA, bytes32 currencyB)
        external
        view
        returns (DataTypes.FxCategory memory)
    {
        return fxCategories[pairKey(currencyA, currencyB)];
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return reserves[asset];
    }

    function getPosition(bytes32 key) external view returns (DataTypes.Position memory) {
        return positions[key];
    }

    function getPosition(address owner, address collateralAsset, address debtAsset)
        external
        view
        returns (DataTypes.Position memory)
    {
        return positions[positionKey(owner, collateralAsset, debtAsset)];
    }

    function getScaledDeposit(address asset, address user) external view returns (uint256) {
        return scaledDeposits[asset][user];
    }

    function getTotalCollateral(address asset) external view returns (uint256) {
        return totalCollateral[asset];
    }

    /// @notice 用户全部仓位 key（链下/测试枚举）。
    function getUserPositionKeys(address user) external view returns (bytes32[] memory) {
        return userPositionKeys[user].values();
    }

    /// @notice 已配置资产列表（invariant 测试遍历各 reserve）。
    function getReservesList() external view returns (address[] memory) {
        return reservesList.values();
    }
}
