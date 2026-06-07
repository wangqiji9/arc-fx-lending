// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Handler} from "./Handler.sol";
import {DataTypes, RAY} from "../../src/libraries/DataTypes.sol";

/// @notice 协议核心不变量(对照 state-transitions.md §不变量)。
/// @dev Handler 随机驱动操作;每条序列后断言下列恒等式始终成立。
contract InvariantTest is BaseTest {
    Handler internal handler;

    address[3] internal actorList;
    address[3] internal assetList;

    function setUp() public override {
        super.setUp();

        // 拉长 heartbeat,避免 warp 后取价被 staleness 拦(invariant 专用)
        oracle.setFeed(address(usdc), address(usdcFeed), 36500 days);
        oracle.setFeed(address(eurc), address(eurcFeed), 36500 days);
        oracle.setFeed(address(weth), address(ethFeed), 36500 days);

        actorList = [makeAddr("inv_a"), makeAddr("inv_b"), makeAddr("inv_c")];
        assetList = [address(usdc), address(eurc), address(weth)];

        handler = new Handler(
            pool, oracle, usdc, eurc, weth, usdcFeed, eurcFeed, ethFeed, actorList, makeAddr("inv_liq")
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                          §不变量 1/2/3:总量一致
    //////////////////////////////////////////////////////////////*/

    /// @notice sum(scaledDeposits[a][*]) == totalScaledSupply。
    function invariant_supplyConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                sum += pool.getScaledDeposit(a, actorList[j]);
            }
            assertEq(sum, pool.getReserveData(a).totalScaledSupply, "supply sum");
        }
    }

    /// @notice sum(position.scaledDebt where debt==a) == totalScaledBorrow。
    function invariant_borrowConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                for (uint256 p = 0; p < 4; p++) {
                    (address col, address debt) = _pair(p);
                    if (debt != a) continue;
                    sum += pool.getPosition(actorList[j], col, debt).scaledDebt;
                }
            }
            assertEq(sum, pool.getReserveData(a).totalScaledBorrow, "borrow sum");
        }
    }

    /// @notice sum(position.collateralAmount where col==a) == totalCollateral[a]。
    function invariant_collateralConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                for (uint256 p = 0; p < 4; p++) {
                    (address col, address debt) = _pair(p);
                    if (col != a) continue;
                    sum += pool.getPosition(actorList[j], col, debt).collateralAmount;
                }
            }
            assertEq(sum, pool.getTotalCollateral(a), "collateral sum");
        }
    }

    /*//////////////////////////////////////////////////////////////
                       §不变量 4/6:偿付能力 / index
    //////////////////////////////////////////////////////////////*/

    /// @notice 池内物理余额始终覆盖锁定抵押(抵押永不被出借/挪用)。
    function invariant_solvency_collateralBacked() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            assertGe(
                BaseTest_token(a).balanceOf(address(pool)),
                pool.getTotalCollateral(a),
                "balance covers collateral"
            );
        }
    }

    /// @notice 出借人偿付能力:可借现金 + 在外债务 >= 出借总额 + 锁定抵押。
    /// @dev 即 balanceOf + borrowed >= supplied + collateral。reserveFactor 盈余使
    ///      borrowed 略大于 supplied,差额以现金形式留在池中(协议储备),故偿付始终覆盖。
    ///      注:原文档「supplied >= borrowed」在 reserveFactor>0 时不成立,此为修正后的正确式。
    function invariant_supplierSolvency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            DataTypes.ReserveData memory r = pool.getReserveData(a);
            uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
            uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
            uint256 cash = BaseTest_token(a).balanceOf(address(pool));
            uint256 collateral = pool.getTotalCollateral(a);
            assertGe(cash + borrowed, supplied + collateral, "supplier claims backed");
        }
    }

    /// @notice index 单调:borrowIndex >= liquidityIndex >= RAY(借款人付息 >= 出借人收息)。
    function invariant_indexOrdering() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            DataTypes.ReserveData memory r = pool.getReserveData(assetList[i]);
            assertGe(r.liquidityIndex, RAY, "liquidityIndex >= RAY");
            assertGe(r.borrowIndex, r.liquidityIndex, "borrowIndex >= liquidityIndex");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _pair(uint256 p) internal view returns (address col, address debt) {
        if (p == 0) return (address(weth), address(usdc));
        if (p == 1) return (address(weth), address(eurc));
        if (p == 2) return (address(usdc), address(eurc));
        return (address(eurc), address(usdc));
    }

    function BaseTest_token(address a) internal view returns (IERC20Like) {
        return IERC20Like(a);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
