// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Handler} from "./Handler.sol";
import {DataTypes, RAY} from "../../src/libraries/DataTypes.sol";

/// @notice Core protocol invariants (see state-transitions.md §invariants).
/// @dev Handler drives random operations; after each sequence, the following identities must hold.
contract InvariantTest is BaseTest {
    Handler internal handler;

    address[3] internal actorList;
    address[3] internal assetList;

    function setUp() public override {
        super.setUp();

        actorList = [makeAddr("inv_a"), makeAddr("inv_b"), makeAddr("inv_c")];
        assetList = [address(usdc), address(eurc), address(weth)];

        handler = new Handler(pool, oracle, usdc, eurc, weth, actorList, makeAddr("inv_liq"));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                          §invariants 1/2/3: sum consistency
    //////////////////////////////////////////////////////////////*/

    /// @notice sum(scaledDeposits[a][*]) == totalScaledSupply.
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

    /// @notice sum(position.scaledDebt where debt==a) == totalScaledBorrow.
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

    /// @notice sum(position.collateralAmount where col==a) == totalCollateral[a].
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
                       §invariants 4/6: solvency / index
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool physical balance always covers locked collateral (collateral is never lent out or misappropriated).
    function invariant_solvency_collateralBacked() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            assertGe(
                BaseTest_token(a).balanceOf(address(pool)), pool.getTotalCollateral(a), "balance covers collateral"
            );
        }
    }

    /// @notice Supplier solvency: available cash + outstanding debt >= total supplied + locked collateral.
    /// @dev i.e. balanceOf + borrowed >= supplied + collateral. The reserveFactor surplus causes
    ///      borrowed to slightly exceed supplied; the difference stays in the pool as cash (protocol reserve),
    ///      so solvency is always maintained.
    ///      Note: the original doc formula "supplied >= borrowed" does not hold when reserveFactor>0; this is the corrected form.
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

    /// @notice Index ordering is monotonic: borrowIndex >= liquidityIndex >= RAY (borrowers pay more than lenders earn).
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
