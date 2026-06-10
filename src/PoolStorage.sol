// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Keys} from "./libraries/Keys.sol";

/// @title PoolStorage
/// @notice The sole state holder for the protocol (Option C, see architecture.md §1).
///         RateEngine/RiskEngine/Liquidation are stateless libraries; only LendingPool,
///         which inherits this contract, reads and writes these slots. This contract
///         contains only storage, key computation, and read-only getters — no business logic.
abstract contract PoolStorage {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-asset risk configuration (set by admin).
    mapping(address asset => DataTypes.AssetConfig) internal assetConfig;

    /// @notice FX risk configuration per currency pair. key = pairKey(min(curA,curB), max(curA,curB)).
    mapping(bytes32 pairKey => DataTypes.FxCategory) internal fxCategories;

    /// @notice Per-asset internal accounting (index / totals / borrow rate / timestamp).
    mapping(address asset => DataTypes.ReserveData) internal reserves;

    /// @notice Lender-side accounting: asset => user => scaled deposit (× liquidityIndex = actual redeemable amount).
    mapping(address asset => mapping(address user => uint256 scaledDeposit)) internal scaledDeposits;

    /// @notice Isolated positions. key = positionKey(owner, collateralAsset, debtAsset).
    mapping(bytes32 key => DataTypes.Position) internal positions;

    /// @notice Total raw collateral amount for each asset (non-interest-bearing). Used for collateral cap + balance invariant.
    mapping(address asset => uint256) internal totalCollateral;

    /// @notice Set of position keys held by a user (added on open, removed on close). Used for UI + invariant enumeration.
    mapping(address user => EnumerableSet.Bytes32Set) internal userPositionKeys;

    /// @notice Set of configured assets (enumerate reserves, used for invariant/caps).
    EnumerableSet.AddressSet internal reservesList;

    /*//////////////////////////////////////////////////////////////
                            KEY COMPUTATION (pure)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deterministic position key: unique per (owner, collateral, debt) triple. Delegates to Keys (single source of truth).
    function positionKey(address owner, address collateralAsset, address debtAsset) public pure returns (bytes32) {
        return Keys.positionKey(owner, collateralAsset, debtAsset);
    }

    /// @notice Currency pair key: order-independent (normalized to min,max), USD↔EUR and EUR↔USD resolve to the same entry.
    function pairKey(bytes32 currencyA, bytes32 currencyB) public pure returns (bytes32) {
        return Keys.pairKey(currencyA, currencyB);
    }

    /*//////////////////////////////////////////////////////////////
                          READ-ONLY GETTERS (UI / tests)
    //////////////////////////////////////////////////////////////*/

    function getAssetConfig(address asset) external view returns (DataTypes.AssetConfig memory) {
        return assetConfig[asset];
    }

    function getFxCategory(bytes32 currencyA, bytes32 currencyB) external view returns (DataTypes.FxCategory memory) {
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

    /// @notice All position keys for a user (for off-chain/test enumeration).
    function getUserPositionKeys(address user) external view returns (bytes32[] memory) {
        return userPositionKeys[user].values();
    }

    /// @notice List of configured assets (for iterating all reserves in invariant tests).
    function getReservesList() external view returns (address[] memory) {
        return reservesList.values();
    }
}
