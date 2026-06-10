// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @notice T-6: Multi-position isolation — different (col, debt) pairs do not affect each other.
/// @dev alice holds two positions simultaneously: WETH→USDC (Standard) and USDC→EURC (FX E-Mode).
contract MultiPositionTest is BaseTest {
    address internal lender = makeAddr("lender");

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 50_000e6);
        _deposit(eurc, lender, 50_000e6);
    }

    /// @notice Two positions have distinct keys and do not interfere with each other.
    function test_twoPositions_independentKeys() public {
        _fund(weth, alice, 1e18);
        _fund(usdc, alice, 1_000e6);

        vm.startPrank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 1_000e6);   // Standard
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);   // FX E-Mode
        vm.stopPrank();

        bytes32[] memory keys = pool.getUserPositionKeys(alice);
        assertEq(keys.length, 2, "two independent positions");
    }

    /// @notice ETH price crash makes the Standard position unhealthy; FX position HF is unaffected.
    function test_etherCrash_onlyAffectsStandardPosition() public {
        _fund(weth, alice, 1e18);
        _fund(usdc, alice, 1_000e6);

        vm.startPrank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 1_000e6);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);
        vm.stopPrank();

        // ETH crashes; Standard position HF < 1
        oracle.setPrice(address(weth), 1200e8); // HF_LT = 1200×0.80/1000 = 0.96 < 1

        // liquidate the WETH→USDC position
        _fund(usdc, liquidator, 10_000e6);
        vm.prank(liquidator);
        pool.liquidate(alice, address(weth), address(usdc), 10_000e6, 0);

        DataTypes.Position memory stdPos = pool.getPosition(alice, address(weth), address(usdc));
        assertEq(stdPos.scaledDebt, 0, "Standard position liquidated");

        // FX position: EURC price unchanged, position still healthy
        DataTypes.Position memory fxPos = pool.getPosition(alice, address(usdc), address(eurc));
        assertEq(fxPos.scaledDebt, 500e6, "FX position unaffected");
        assertGt(fxPos.collateralAmount, 0, "FX collateral intact");
    }

    /// @notice Two positions sharing the same debtAsset (USDC) accumulate scaledDebt independently.
    function test_sharedDebtAsset_accounting() public {
        _fund(weth, alice, 2e18);
        _fund(eurc, alice, 1_000e6);

        vm.startPrank(alice);
        // position 1: WETH→USDC
        pool.openPosition(address(weth), 1e18, address(usdc), 1_000e6);
        // position 2: EURC→USDC (FX E-Mode reverse)
        pool.openPosition(address(eurc), 1_000e6, address(usdc), 500e6);
        vm.stopPrank();

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        // totalScaledBorrow = sum of both positions
        assertEq(r.totalScaledBorrow, 1_500e6, "total borrow aggregates both positions");

        // each position's scaledDebt is tracked independently
        DataTypes.Position memory p1 = pool.getPosition(alice, address(weth), address(usdc));
        DataTypes.Position memory p2 = pool.getPosition(alice, address(eurc), address(usdc));
        assertEq(p1.scaledDebt, 1_000e6, "position1 debt");
        assertEq(p2.scaledDebt, 500e6, "position2 debt");
    }

    /// @notice Closing one position does not affect the other; the enumeration set shrinks correctly.
    function test_closeOnePosition_keepsOther() public {
        _fund(weth, alice, 1e18);
        _fund(usdc, alice, 2_000e6);

        vm.startPrank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 1_000e6);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);
        vm.stopPrank();

        assertEq(pool.getUserPositionKeys(alice).length, 2, "two positions");

        // repay WETH→USDC debt in full + withdraw collateral → close position
        _fund(usdc, alice, 100e6); // top up to cover potential interest
        vm.startPrank(alice);
        pool.repay(alice, address(weth), address(usdc), type(uint128).max);
        pool.withdrawCollateral(address(weth), address(usdc), 1e18);
        vm.stopPrank();

        assertEq(pool.getUserPositionKeys(alice).length, 1, "one position remains");

        // remaining position is USDC→EURC
        DataTypes.Position memory remaining = pool.getPosition(alice, address(usdc), address(eurc));
        assertEq(remaining.scaledDebt, 500e6, "FX position still active");
    }
}
