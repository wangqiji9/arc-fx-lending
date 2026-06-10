// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @notice T-10: Multi-actor scenario tests covering full business lifecycles
///         with price fluctuation. These are deterministic integration tests,
///         distinct from invariant tests (random sequences) and fuzz tests (random properties).
///
/// Scenario 1 — Multi-lender lifecycle: multiple lenders deposit, borrower takes
///   high-utilization loan, time passes accruing interest, price drops below
///   liquidation threshold, liquidation occurs, all lenders can withdraw principal.
///
/// Scenario 2 — ETH price crash to bad debt: extreme price drop leaves the
///   position undercollateralized even after full collateral seizure; residual
///   debt cleared via repayBadDebt.
///
/// Scenario 3 — FX E-Mode EURC appreciation: EUR strengthens vs USD, pushing
///   debt value above the FX liquidation threshold, triggering liquidation.
contract ScenarioTest is BaseTest {
    address internal lender1 = makeAddr("lender1");
    address internal lender2 = makeAddr("lender2");
    address internal eurcLender = makeAddr("eurcLender");

    /*//////////////////////////////////////////////////////////////
                    Scenario 1: Multi-lender + price drop + liquidation
    //////////////////////////////////////////////////////////////*/

    /// @notice Two lenders deposit USDC. Bob opens a position at high (but sub-kink)
    ///         utilization, accrues 30 days of interest, ETH crashes, gets liquidated.
    ///         Both lenders can still withdraw their full principal.
    ///
    /// Params:
    ///   Supply: lender1 5000 + lender2 5000 = 10000 USDC
    ///   Bob borrows 2000 USDC with 1 WETH collateral -> util ≈ 20% -> rate ≈ 1% APY
    ///   30-day warp -> debt ≈ 2001.6 USDC (minimal interest)
    ///   ETH price: $3000 -> $2200 -> HF = (2200*0.8)/2001.6 ≈ 0.88 WAD (< 0.98 -> 100% close)
    ///   Liquidation: liquidator repays ~2001.6 USDC, seizes ~0.977 ETH
    function test_scenario_multiLender_lifecycle() public {
        // ── Setup: two lenders provide USDC ──────────────────────────────────
        _deposit(usdc, lender1, 5_000e6);
        _deposit(usdc, lender2, 5_000e6);

        // ── Bob opens position: 1 WETH collateral, 2000 USDC borrowed ────────
        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // ── 30 days pass ──────────────────────────────────────────────────────
        vm.warp(block.timestamp + 30 days);

        // ── ETH price crashes from $3000 -> $2200 (below liquidation threshold) ──
        // Threshold: ETH price where HF=1 with LT=80%, ~2501 USDC debt -> $3126.25
        // At $2200 and ~2001 USDC debt: HF = (2200*0.8)/2001 ≈ 0.879 < 1 -> liquidatable
        oracle.setPrice(address(weth), 2200e8);

        uint256 hf = pool.getHealthFactor(bob, address(weth), address(usdc));
        assertLt(hf, 1e18, "HF must be below 1 after price drop");

        // ── Liquidator repays up to actual debt (which grew slightly with interest) ──
        _fund(usdc, liquidator, 5_000e6);
        uint256 liquidatorEthBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0); // request >> debt -> capped

        // Liquidator received WETH
        uint256 ethSeized = weth.balanceOf(liquidator) - liquidatorEthBefore;
        assertGt(ethSeized, 0, "liquidator must receive collateral");

        // ── Both lenders can withdraw their full principal ────────────────────
        // Pool has: (10000 - 2000) + repaid_amount ≈ 8000 + ~2001 = ~10001 USDC
        vm.prank(lender1);
        pool.withdraw(address(usdc), 5_000e6);
        assertGe(usdc.balanceOf(lender1), 5_000e6, "lender1 recovers principal");

        vm.prank(lender2);
        pool.withdraw(address(usdc), 5_000e6);
        assertGe(usdc.balanceOf(lender2), 5_000e6, "lender2 recovers principal");
    }

    /*//////////////////////////////////////////////////////////////
              Scenario 2: ETH price crash -> bad debt -> repayBadDebt
    //////////////////////////////////////////////////////////////*/

    /// @notice ETH crashes so severely that seizing all collateral cannot cover the
    ///         full debt. Residual unsecured debt is cleared by the insurance fund.
    ///
    /// Params:
    ///   Bob: 1 WETH collateral, 2200 USDC debt at $3000 (HF = 3000*0.8/2200 ≈ 1.09 ✓)
    ///   ETH crashes to $1000:
    ///     HF = (1000*0.8)/2200 ≈ 0.364 WAD -> 100% close factor
    ///     Full seize = (2200 * 1.075) / 1000 = 2.365 ETH > 1 ETH -> collateral capped
    ///     Actual: seize = 1 ETH, repay = 1000 / 1.075 ≈ 930.23 USDC
    ///     Bad debt = 2200 - 930.23 ≈ 1269.77 USDC remains with 0 collateral
    ///   Insurance fund calls repayBadDebt to clear residual.
    function test_scenario_ethCrash_badDebt() public {
        // ── Setup ─────────────────────────────────────────────────────────────
        _deposit(usdc, lender1, 10_000e6);

        // Bob: 1 ETH collateral, 2200 USDC debt — valid at $3000 (LTV 75% -> max 2250)
        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_200e6);

        DataTypes.Position memory posBefore = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(posBefore.collateralAmount, 1e18, "initial collateral");

        // ── ETH crashes to $1000 -> position is severely undercollateralized ──
        oracle.setPrice(address(weth), 1000e8);

        uint256 hf = pool.getHealthFactor(bob, address(weth), address(usdc));
        assertLt(hf, 0.98e18, "HF well below 0.98 -> 100% close factor");

        // ── Liquidator seizes ALL collateral (constrained by 1 ETH) ──────────
        _fund(usdc, liquidator, 5_000e6);
        uint256 liquidatorEthBefore = weth.balanceOf(liquidator);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6, 0);

        uint256 ethSeized = weth.balanceOf(liquidator) - liquidatorEthBefore;
        uint256 usdcPaid = liquidatorUsdcBefore - usdc.balanceOf(liquidator);

        // Liquidator received exactly 1 ETH (all collateral) and paid < 2200 USDC
        assertEq(ethSeized, 1e18, "all collateral seized");
        assertLt(usdcPaid, 2_200e6, "liquidator paid less than full debt (bad debt scenario)");

        // ── Position now has 0 collateral but remaining debt (bad debt) ───────
        DataTypes.Position memory posAfterLiquidation = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(posAfterLiquidation.collateralAmount, 0, "collateral fully seized");
        assertGt(posAfterLiquidation.scaledDebt, 0, "residual bad debt remains");

        // ── Insurance fund repays the residual debt ───────────────────────────
        // repayBadDebt requires collateralAmount == 0 (verified above)
        usdc.mint(insurer, 2_000e6);
        vm.prank(insurer);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(insurer);
        pool.repayBadDebt(bob, address(weth), address(usdc));

        // Position should now be fully closed
        bytes32[] memory keys = pool.getUserPositionKeys(bob);
        assertEq(keys.length, 0, "position closed after repayBadDebt");
    }

    /*//////////////////////////////////////////////////////////////
              Scenario 3: FX E-Mode — EURC appreciates -> liquidation
    //////////////////////////////////////////////////////////////*/

    /// @notice EUR strengthens from $1.08 to $1.20, making the EURC debt more expensive
    ///         in USD terms and pushing the FX E-Mode position below the liquidation threshold.
    ///
    /// Params:
    ///   FX E-Mode USD↔EUR: LTV=90%, LT=94%, bonus=2.5%
    ///   Bob: 1000 USDC collateral, 800 EURC debt at $1.08
    ///     collValue = $1000, debtValue = $864 -> HF = (940/864) ≈ 1.088 WAD ✓
    ///   EURC -> $1.20:
    ///     debtValue = 800 * 1.20 = $960 -> HF = (940/960) ≈ 0.979 WAD < 0.98 -> 100% close factor
    ///   Liquidation: repay 800 EURC, seize 984 USDC (< 1000 -> no cap, no bad debt)
    ///   Remaining: 16 USDC in position (bob can retrieve), debt = 0
    function test_scenario_fx_eurcAppreciation_liquidation() public {
        // ── Setup: provide EURC liquidity for bob to borrow ───────────────────
        _deposit(eurc, eurcLender, 5_000e6);

        // ── Bob: 1000 USDC collateral -> borrow 800 EURC at $1.08 (FX E-Mode) ──
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);

        // Confirm position is healthy at $1.08
        uint256 hfInitial = pool.getHealthFactor(bob, address(usdc), address(eurc));
        assertGt(hfInitial, 1e18, "HF must be healthy at $1.08 EURC");

        // ── EURC appreciates from $1.08 -> $1.20 ──────────────────────────────
        // At $1.20: debtValue = 800 * 1.20e8 = 960e8, riskAdjColl = 1000e8 * 94% = 940e8
        // HF = 940/960 ≈ 0.979 WAD < 1 -> liquidatable
        oracle.setPrice(address(eurc), 1.2e8);

        uint256 hfAfter = pool.getHealthFactor(bob, address(usdc), address(eurc));
        assertLt(hfAfter, 1e18, "HF must be below 1 after EURC appreciation");
        assertLt(hfAfter, 0.98e18, "HF below 0.98 -> 100% close factor");

        // ── Liquidator repays full EURC debt, receives USDC + 2.5% bonus ──────
        // Expected seize: 800 EURC * 1.20 * 1.025 / 1.0 USDC_price = 984 USDC
        _fund(eurc, liquidator, 1_000e6);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(liquidator);
        uint256 liquidatorEurcBefore = eurc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(bob, address(usdc), address(eurc), 800e6, 0);

        uint256 usdcReceived = usdc.balanceOf(liquidator) - liquidatorUsdcBefore;
        uint256 eurcPaid = liquidatorEurcBefore - eurc.balanceOf(liquidator);

        // Liquidator paid 800 EURC and received ~984 USDC
        assertEq(eurcPaid, 800e6, "liquidator paid full EURC debt");
        assertGt(usdcReceived, 0, "liquidator received USDC collateral");

        // Received USDC worth more than EURC paid (profit = bonus)
        // usdcReceived in USD = usdcReceived * 1 = usdcReceived
        // eurcPaid in USD = 800e6 * 1.20 = 960e6
        assertGt(usdcReceived, 960e6, "liquidator profitable: USDC > EURC value paid");

        // ── Bob's position: debt cleared, small collateral remains ────────────
        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(eurc));
        assertEq(pos.scaledDebt, 0, "bob's debt fully cleared");
        assertGt(pos.collateralAmount, 0, "residual collateral in position (bob can withdraw)");
        assertLt(pos.collateralAmount, 1_000e6, "seized portion removed from collateral");
    }
}
