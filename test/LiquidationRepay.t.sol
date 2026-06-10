// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {
    InvalidAmount,
    PositionNotFound,
    PositionHealthy,
    PositionStillCollateralized,
    NotAuthorized,
    OraclePaused,
    InsufficientCollateralSeized
} from "../src/libraries/DataTypes.sol";

/// @notice repay + liquidate (including dynamic close factor, collateral-constrained reverse-compute, bad-debt residual + Layer3).
/// @dev Uses ETH→USDC (Standard, LT 80% / bonus 7.5%), manipulates ETH price to produce various HF scenarios.
contract LiquidationRepayTest is BaseTest {
    address internal lender = makeAddr("lender");

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 100_000e6); // USDC lending liquidity
        _fund(weth, bob, 10e18); // bob's ETH collateral
        _fund(usdc, liquidator, 100_000e6); // liquidator USDC reserve
    }

    /// @notice bob opens 1 ETH ($3000) → borrows 2000 USDC, HF (LT) = 1.2.
    function _openEthPosition() internal {
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                repay
    //////////////////////////////////////////////////////////////*/

    function test_repay_partial() public {
        _openEthPosition();
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max); // repay with borrowed USDC

        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), 500e6);

        assertEq(paid, 500e6, "paid");
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_500e6, "debt reduced");
    }

    function test_repay_truncatesOverpay() public {
        _openEthPosition();
        _fund(usdc, bob, 5_000e6); // extra funds

        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), 5_000e6); // attempting to repay 5000

        assertEq(paid, 2_000e6, "truncated to actual debt");
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "debt cleared");
    }

    function test_repay_byThirdParty() public {
        _openEthPosition();
        // anyone can repay on behalf of another: liquidator repays for bob
        vm.prank(liquidator);
        pool.repay(bob, address(weth), address(usdc), 1_000e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_000e6, "third party repaid");
    }

    function test_repay_thenWithdrawAll_closesPosition() public {
        _openEthPosition();
        _fund(usdc, bob, 5_000e6);

        vm.startPrank(bob);
        pool.repay(bob, address(weth), address(usdc), 2_000e6); // repay in full
        pool.withdrawCollateral(address(weth), address(usdc), 1e18); // withdraw all collateral
        vm.stopPrank();

        assertEq(pool.getUserPositionKeys(bob).length, 0, "position closed");
    }

    function test_repay_revert_positionNotFound() public {
        vm.prank(bob);
        vm.expectRevert();
        pool.repay(bob, address(weth), address(usdc), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                              liquidate
    //////////////////////////////////////////////////////////////*/

    function test_liquidate_revert_whenHealthy() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2500e8); // HF = 2500*0.8/2000 = 1.0, not liquidatable

        vm.prank(liquidator);
        vm.expectRevert();
        pool.liquidate(bob, address(weth), address(usdc), 1_000e6, 0);
    }

    /// @notice minCollateralOut guard: revert when seized collateral falls below the liquidator's floor.
    function test_liquidate_revert_whenSeizeBelowMinCollateralOut() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2490e8); // HF = 0.996 → 50% close, seize ≈ 0.43172e18

        // Demand more collateral than the call can possibly seize → must revert fail-fast.
        // Match the selector only; the exact seized amount carries wei-level rounding.
        vm.prank(liquidator);
        vm.expectPartialRevert(InsufficientCollateralSeized.selector);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 1e18);
    }

    /// @notice minCollateralOut guard: pass when seized collateral meets the floor; state unchanged vs guard-off.
    function test_liquidate_succeeds_whenSeizeMeetsMinCollateralOut() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2490e8); // HF = 0.996 → 50% close, seize ≈ 0.43172e18

        // Floor just below the expected seize → guard passes, liquidation proceeds normally.
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0.43e18);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_000e6, "half debt remains (same as guard-off path)");
        assertApproxEqAbs(weth.balanceOf(liquidator), 0.43172e18, 1e15, "seized collateral");
    }

    function test_liquidate_partial_closeFactor50() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2490e8); // HF = 0.996 ∈ [0.98,1) → close factor 50%

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0); // request exceeds cap, truncated to maxRepay

        // 50% × 2000 = 1000 USDC repaid
        uint256 repaid = liqUsdcBefore - usdc.balanceOf(liquidator);
        assertEq(repaid, 1_000e6, "repaid 50%");

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_000e6, "half debt remains");

        // seize = 1000 ×1.075 / 2490 ETH = 0.43172e18
        assertApproxEqAbs(weth.balanceOf(liquidator), 0.43172e18, 1e15, "seized collateral");
    }

    function test_liquidate_full_closeFactor100() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2400e8); // HF = 0.96 < 0.98 → close factor 100%

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "full debt cleared");
        // seize = 2000 ×1.075 / 2400 = 0.89583e18, collateral remains → position not closed
        assertApproxEqAbs(weth.balanceOf(liquidator), 0.89583e18, 1e15, "seized");
        assertGt(pos.collateralAmount, 0, "collateral remains");
        assertEq(pool.getUserPositionKeys(bob).length, 1, "not closed");
    }

    /// @notice Core fix #1: when collateral is insufficient, reverse-compute repay — liquidator pays for actual collateral received, remaining profitable.
    function test_liquidate_reverseCompute_badDebt() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 1800e8); // HF = 0.72, collateral < debt×(1+bonus) → triggers reverse-compute

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        // liquidator receives ALL collateral: 1 ETH
        assertEq(weth.balanceOf(liquidator), 1e18, "got all collateral");

        // reverse-compute repay = collateralValue / (1+bonus) = 1800 / 1.075 = 1674.42 USDC
        uint256 paid = liqUsdcBefore - usdc.balanceOf(liquidator);
        assertApproxEqAbs(paid, 1674.42e6, 1e6, "reverse-computed repay");

        // liquidator is profitable: pays 1674 USDC, receives ETH worth $1800
        assertLt(paid, 1800e6, "liquidator profitable");

        // residual bad-debt position: collateral=0, debt>0 → position kept open (Layer3 signal)
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.collateralAmount, 0, "collateral drained");
        assertApproxEqAbs(pos.scaledDebt, 325.58e6, 1e6, "residual bad debt");
        assertEq(pool.getUserPositionKeys(bob).length, 1, "residual position kept");
    }

    function test_liquidate_revertsWhenOraclePaused() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 2400e8);
        oracle.setPaused(address(weth), true);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(weth)));
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       Layer 3: bad-debt recapitalization
    //////////////////////////////////////////////////////////////*/

    /// @notice Core fix #2: residual bad-debt position cleared by protocol funds.
    function test_repayBadDebt_clearsResidual() public {
        // first create a bad-debt residual position
        _openEthPosition();
        oracle.setPrice(address(weth), 1800e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        // insurer injects funds to clear the bad debt
        _fund(usdc, insurer, 1_000e6);
        vm.prank(insurer);
        uint256 cleared = pool.repayBadDebt(bob, address(weth), address(usdc));

        assertApproxEqAbs(cleared, 325.58e6, 1e6, "cleared residual");
        assertEq(pool.getUserPositionKeys(bob).length, 0, "position closed");
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.totalScaledBorrow, 0, "no outstanding debt");
    }

    function test_repayBadDebt_revert_stillCollateralized() public {
        // partial liquidation still leaves collateral → bad-debt recapitalization not allowed
        _openEthPosition();
        oracle.setPrice(address(weth), 2400e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0); // 100% debt cleared but collateral remains

        _fund(usdc, insurer, 5_000e6);
        vm.prank(insurer);
        vm.expectRevert();
        pool.repayBadDebt(bob, address(weth), address(usdc));
    }

    function test_repayBadDebt_revert_notAuthorized() public {
        _openEthPosition();
        oracle.setPrice(address(weth), 1800e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        _fund(usdc, alice, 1_000e6);
        vm.prank(alice); // neither owner nor insuranceFund
        vm.expectRevert(NotAuthorized.selector);
        pool.repayBadDebt(bob, address(weth), address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                       T-1: FX E-Mode liquidation
    //////////////////////////////////////////////////////////////*/

    // USDC (collateral) → EURC (debt), FX E-Mode: LT=94%, bonus=2.5%
    // 1000 USDC collateral, borrow 800 EURC, HF_LT = 940/864 = 1.088
    function _openFxPosition() internal {
        _deposit(eurc, lender, 10_000e6); // provide EURC liquidity
        _fund(eurc, liquidator, 10_000e6); // liquidator needs EURC to repay debt
        _fund(usdc, alice, 1_000e6);
        vm.prank(alice);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);
    }

    /// @notice EURC appreciates: HF ∈ [0.98,1) → close factor 50%, liquidator repays 400 EURC and receives ~485 USDC.
    function test_fx_liquidate_partial_closeFactor50() public {
        _openFxPosition();
        oracle.setPrice(address(eurc), 1.185e8); // HF_LT = 940/948 = 0.9916 ∈ [0.98,1)

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        uint256 liqEurcBefore = eurc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice, address(usdc), address(eurc), 5_000e6, 0); // excess request, capped to maxRepay

        uint256 eurcPaid = liqEurcBefore - eurc.balanceOf(liquidator);
        uint256 usdcReceived = usdc.balanceOf(liquidator) - liqUsdcBefore;

        // close factor 50% → maxRepay = 400 EURC
        assertEq(eurcPaid, 400e6, "repaid 50% of debt");

        // seize = 400 × 1.185 × 1.025 / 1.00 ≈ 485.85 USDC
        assertApproxEqAbs(usdcReceived, 485.85e6, 1e6, "seized collateral with bonus");

        DataTypes.Position memory pos = pool.getPosition(alice, address(usdc), address(eurc));
        assertEq(pos.scaledDebt, 400e6, "half debt remains");
        assertEq(pos.collateralAmount, 1_000e6 - usdcReceived, "collateral reduced");
    }

    /// @notice EURC appreciates sharply: HF < 0.98 → close factor 100%, collateral insufficient → reverse-compute triggers.
    function test_fx_liquidate_full_reverseCompute() public {
        _openFxPosition();
        oracle.setPrice(address(eurc), 1.25e8); // HF_LT = 940/1000 = 0.94 < 0.98 → full position

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        uint256 liqEurcBefore = eurc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(alice, address(usdc), address(eurc), 5_000e6, 0);

        // seize at most 1000 USDC; reverse-compute repay ≈ 1000×1.00/1.025/1.25 ≈ 780 EURC
        uint256 eurcPaid = liqEurcBefore - eurc.balanceOf(liquidator);
        uint256 usdcReceived = usdc.balanceOf(liquidator) - liqUsdcBefore;
        assertApproxEqAbs(eurcPaid, 780e6, 2e6, "reverse-computed repay");
        assertEq(usdcReceived, 1_000e6, "seized all collateral");

        // residual bad-debt position: FX mode also produces a bad-debt residual
        DataTypes.Position memory pos = pool.getPosition(alice, address(usdc), address(eurc));
        assertEq(pos.collateralAmount, 0, "collateral drained");
        assertGt(pos.scaledDebt, 0, "residual bad debt");
    }

    /*//////////////////////////////////////////////////////////////
                       T-2: interest-driven liquidation
    //////////////////////////////////////////////////////////////*/

    /// @notice Price unchanged; interest accrual drives HF below 1 → liquidatable.
    /// @dev alice borrows 95_000 USDC first, pushing utilization to ~97% (well above kink),
    ///      annual rate ~70%; bob's position crosses the liquidation threshold in ~35 days.
    function test_interest_drivenLiquidation() public {
        // alice consumes most liquidity, pushing utilization high
        _fund(weth, alice, 50e18); // 50 ETH @ 3000 = $150,000 collateral
        vm.prank(alice);
        pool.openPosition(address(weth), 50e18, address(usdc), 95_000e6);
        // util = 95000/100000 = 95% → rate ≈ 4% + (0.15/0.20)×75% + 1% = 61.25%

        // bob borrows near the limit under the high-rate environment
        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_249e6);
        // HF_LT = 3000×0.80/2249 = 1.067; initially healthy

        // confirm position is healthy at open
        vm.expectRevert();
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 1_000e6, 0);

        // advance 40 days: at ~70% annual rate bob's debt grows ~7.7% → HF drops below 1
        vm.warp(block.timestamp + 40 days);

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertGt(pos.scaledDebt, 0, "partial liquidation - debt remains");
        assertLt(pos.scaledDebt, 2_249e6, "debt reduced after liquidation");
    }

    /*//////////////////////////////////////////////////////////////
                       T-5: boundary values
    //////////////////////////////////////////////////////////////*/

    /// @notice HF exactly equal to WAD (LTV gate): operation passes without revert.
    function test_boundary_hfExactlyWad_passes() public {
        _fund(weth, alice, 1e18);
        // colValue × LTV = 3000e8 × 75% = 2250e8 = debtValue → HF_LTV = 1.000 = WAD
        vm.prank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_250e6);

        DataTypes.Position memory pos = pool.getPosition(alice, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 2_250e6, "position opened at exact LTV limit");
    }

    /// @notice Close factor boundary:
    ///   ETH @ 2755 → collValue×LT = 2204e8, HF = 2204/2249 < 0.98 → close factor 100%
    ///   ETH @ 2756 → collValue×LT = 2204.8e8, HF = 2204.8/2249 > 0.98 → close factor 50%
    /// @dev Key: colValue × LT_bps multiplication at e8 precision retains the fractional part; no truncation at 2756.
    function test_boundary_closeFactor_below98_full() public {
        _fund(weth, alice, 1e18);
        vm.prank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_249e6);

        oracle.setPrice(address(weth), 2755e8); // collValue×0.80 = 2204e8, HF = 2204/2249 = 0.9799 < 0.98
        vm.prank(liquidator);
        pool.liquidate(alice, address(weth), address(usdc), 5_000e6, 0);

        DataTypes.Position memory pos = pool.getPosition(alice, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "closeFactor=100%: debt fully cleared");
    }

    function test_boundary_closeFactor_above98_partial() public {
        _fund(weth, alice, 1e18);
        vm.prank(alice);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_249e6);

        oracle.setPrice(address(weth), 2756e8); // collValue×0.80 = 2204.8e8, HF = 2204.8/2249 = 0.9803 ≥ 0.98
        vm.prank(liquidator);
        pool.liquidate(alice, address(weth), address(usdc), 5_000e6, 0);

        DataTypes.Position memory pos = pool.getPosition(alice, address(weth), address(usdc));
        // close factor 50%: ~50% of debt remains
        assertApproxEqAbs(pos.scaledDebt, 2_249e6 / 2, 2e6, "closeFactor=50%: half debt remains");
    }
}
