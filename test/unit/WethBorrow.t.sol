// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes, HealthFactorTooLow} from "../../src/libraries/DataTypes.sol";

/// @notice Tests for the USDC -> WETH borrow path (Standard mode).
///         Economic interpretation: borrower is shorting ETH.
///         Liquidation is triggered by ETH price RISING (opposite of WETH->USDC).
///
/// Key params (USDC as collateral, Standard mode):
///   LTV=75%, LT=80%, bonus=5%
///   1000 USDC collateral, $3000 ETH:
///     maxBorrow = 1000e8 * 7500/10000 / 3000e8 * 1e18 = 0.25e18 WETH exactly
///     liquidation threshold: ethPrice > 4000 USD when 0.25 WETH borrowed
///     (riskAdjColl=800e8, debtValue at 4000 USD=1000e8 -> HF=0.8 < 1)
contract WethBorrowTest is BaseTest {
    address internal wethLender = makeAddr("wethLender");

    function setUp() public override {
        super.setUp();
        // Provide WETH liquidity for borrowing
        _deposit(weth, wethLender, 2e18);
    }

    // -----------------------------------------------------------------------
    // Test 1: Full lifecycle — borrow WETH with USDC collateral, repay, close
    // -----------------------------------------------------------------------

    /// @notice 1000 USDC -> borrow 0.2 WETH at $3000 (HF = 1.333 WAD).
    ///         Repay WETH debt, withdraw USDC collateral, position closes.
    function test_wethBorrow_basicLifecycle() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(weth), 0.2e18);

        // HF check: collValue=1000e8, riskAdjColl(LT=80%)=800e8, debtValue=600e8
        // HF = 800/600 * WAD = 1.333 WAD
        uint256 hf = pool.getHealthFactor(bob, address(usdc), address(weth));
        assertGt(hf, 1e18, "position is healthy at $3000 ETH");

        // Bob has 0.2 WETH from borrow — approve and repay
        vm.prank(bob);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        pool.repay(bob, address(usdc), address(weth), type(uint128).max);

        vm.prank(bob);
        pool.withdrawCollateral(address(usdc), address(weth), 1_000e6);

        assertEq(pool.getUserPositionKeys(bob).length, 0, "position fully closed");
        assertEq(usdc.balanceOf(bob), 1_000e6, "USDC collateral returned");
    }

    // -----------------------------------------------------------------------
    // Test 2: ETH price rises -> short squeeze -> liquidation
    // -----------------------------------------------------------------------

    /// @notice ETH: $3000 -> $4100. Debt value increases, HF falls below 1.
    ///         Liquidator repays WETH debt, receives USDC collateral + 5% bonus.
    ///
    ///   At $4100: debtValue = 0.2e18 * 4100e8 / 1e18 = 820e8
    ///             riskAdjColl = 1000e8 * 80% = 800e8
    ///             HF = 800/820 * WAD ≈ 0.976 WAD < 0.98 -> 100% close factor
    ///   Seize: repayValue=820e8, seize=820e8*105%=861e8 -> 861 USDC
    function test_wethBorrow_liquidation_ethRises() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(weth), 0.2e18);

        // ETH rises above the liquidation threshold ($4000)
        oracle.setPrice(address(weth), 4100e8);

        uint256 hf = pool.getHealthFactor(bob, address(usdc), address(weth));
        assertLt(hf, 1e18, "HF < 1 after ETH price rise");
        assertLt(hf, 0.98e18, "HF < 0.98 -> 100% close factor");

        // Liquidator repays 0.2 WETH, receives USDC
        _fund(weth, liquidator, 0.2e18);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(bob, address(usdc), address(weth), 0.2e18, 0);

        uint256 usdcReceived = usdc.balanceOf(liquidator) - liquidatorUsdcBefore;
        // Expected seize: 861 USDC (820 USDC debt value * 1.05 bonus / $1 USDC)
        assertGt(usdcReceived, 800e6, "liquidator receives profitable USDC amount");
        assertLt(usdcReceived, 1_000e6, "seized < full collateral, no bad debt");

        // Residual USDC remains in bob's position (not seized)
        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(weth));
        assertEq(pos.scaledDebt, 0, "debt cleared");
        assertGt(pos.collateralAmount, 0, "residual collateral remains for bob");
    }

    // -----------------------------------------------------------------------
    // Test 3: LTV boundary — exactly at max borrow succeeds; +1 wei reverts
    // -----------------------------------------------------------------------

    /// @notice maxBorrow = 1000 USDC * 75% LTV / $3000 = 0.25 WETH.
    ///         At exactly 0.25e18: HF_ltv = 1e18 (boundary) -> succeeds.
    ///         At 0.25e18 + 1: debtValue = 750e8 + 1 -> HF_ltv < 1e18 -> reverts.
    function test_wethBorrow_ltvBoundary() public {
        _fund(usdc, bob, 1_000e6);

        // Exactly at LTV boundary: should succeed
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(weth), 0.25e18);
        assertEq(pool.getUserPositionKeys(bob).length, 1, "borrow at LTV boundary succeeds");

        // Close position to reset state
        vm.prank(bob);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        pool.repay(bob, address(usdc), address(weth), type(uint128).max);
        vm.prank(bob);
        pool.withdrawCollateral(address(usdc), address(weth), 1_000e6);

        // One wei over max: should revert with HealthFactorTooLow (selector check via try/catch)
        vm.prank(bob);
        try pool.openPosition(address(usdc), 1_000e6, address(weth), 0.25e18 + 1) {
            revert("should have reverted above LTV");
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertEq(sel, HealthFactorTooLow.selector, "expected HealthFactorTooLow");
        }
    }

    // -----------------------------------------------------------------------
    // Test 4: ETH price falls -> short position improves, cannot be liquidated
    // -----------------------------------------------------------------------

    /// @notice When ETH price falls, short position becomes MORE healthy.
    ///         At $2000 ETH: debtValue = 0.2 * 2000e8 = 400e8, HF >> 1.
    ///         Liquidation should revert with PositionHealthy.
    function test_wethBorrow_ethFall_positionImproves() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(weth), 0.2e18);

        // ETH falls: debt value drops, HF improves
        oracle.setPrice(address(weth), 2000e8);

        uint256 hf = pool.getHealthFactor(bob, address(usdc), address(weth));
        assertGt(hf, 1.5e18, "short position more healthy as ETH falls");

        // Liquidation should fail
        _fund(weth, liquidator, 0.2e18);
        vm.prank(liquidator);
        vm.expectRevert();
        pool.liquidate(bob, address(usdc), address(weth), 0.2e18, 0);
    }
}
