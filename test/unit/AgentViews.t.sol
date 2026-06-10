// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes, RAY, WAD, BPS} from "../../src/libraries/DataTypes.sol";
import {RateEngine} from "../../src/libraries/RateEngine.sol";
import {AgentTypes} from "../../src/libraries/AgentTypes.sol";
import {Keys} from "../../src/libraries/Keys.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// @notice Tests for the agent-facing read-only decision layer + Multicall (docs/findings.md §D-1).
/// @dev Covers: viewRates parity with the accrual formula, getAvailableMarkets enumeration,
///      getPositionRisk / batchGetPositionRisk (Standard vs FX), previewPosition consistency with a
///      real open, the D-1 "feed the reported liquidation price back -> real liquidation triggers"
///      consistency test, and Multicall atomicity + msg.sender preservation.
contract AgentViewsTest is BaseTest {
    address internal lender = makeAddr("agentLender");

    function setUp() public override {
        super.setUp();
        // Deep liquidity so utilization stays controllable.
        _deposit(usdc, lender, 1_000_000e6);
        _deposit(eurc, lender, 1_000_000e6);
        _deposit(weth, lender, 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                                viewRates
    //////////////////////////////////////////////////////////////*/

    function test_viewRates_matchesStoredRateAndSupplyFormula() public {
        // Borrow USDC against WETH to create non-zero utilization.
        // 100 ETH = $300k collateral, LTV 75% -> max ~$225k. Borrow $150k (util = 0.15, healthy).
        _fund(weth, bob, 100e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 150_000e6); // util = 0.15

        (uint256 borrowRate, uint256 supplyRate) = pool.viewRates(address(usdc));

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(borrowRate, r.currentBorrowRate, "borrowRate == stored currentBorrowRate");

        // Recompute supplyRate independently: borrowRate x util x (1 - reserveFactor).
        uint256 util = (uint256(r.totalScaledBorrow) * r.borrowIndex / RAY) * RAY
            / (uint256(r.totalScaledSupply) * r.liquidityIndex / RAY);
        uint256 oneMinusRf = RAY - (uint256(1000) * RAY) / BPS; // USDC reserveFactor = 1000bps
        uint256 expectedSupply = _rayMul(_rayMul(borrowRate, util), oneMinusRf);
        assertApproxEqAbs(supplyRate, expectedSupply, 1e12, "supplyRate matches formula");
        assertLt(supplyRate, borrowRate, "supplyRate < borrowRate (reserve cut + util<1)");
    }

    function test_viewRates_zeroUtilization() public {
        // No borrows on EURC yet -> utilization 0 -> supplyRate 0; borrowRate = fxPremium baseline.
        (uint256 borrowRate, uint256 supplyRate) = pool.viewRates(address(eurc));
        assertEq(supplyRate, 0, "supplyRate 0 at zero utilization");
        // currentBorrowRate was last refreshed on deposit (util 0): base 0 + fxPremium 200bps.
        assertEq(borrowRate, (uint256(200) * RAY) / BPS, "borrowRate = fxPremium at util 0");
    }

    /*//////////////////////////////////////////////////////////////
                          getAvailableMarkets
    //////////////////////////////////////////////////////////////*/

    function test_getAvailableMarkets_enumeratesValidPairs() public view {
        AgentTypes.MarketInfo[] memory markets = pool.getAvailableMarkets();

        // 3 assets, all borrowable & ltv>0 -> 3*2 = 6 ordered pairs, none same-asset.
        assertEq(markets.length, 6, "6 ordered (col,debt) pairs");

        for (uint256 i; i < markets.length; ++i) {
            assertTrue(markets[i].collateralAsset != markets[i].debtAsset, "no same-asset market");
            assertGt(markets[i].ltv, 0, "ltv > 0");
        }
    }

    function test_getAvailableMarkets_fxPairResolvesEMode() public view {
        AgentTypes.MarketInfo[] memory markets = pool.getAvailableMarkets();

        bool sawFx;
        bool sawStandard;
        for (uint256 i; i < markets.length; ++i) {
            AgentTypes.MarketInfo memory m = markets[i];
            if (m.collateralAsset == address(usdc) && m.debtAsset == address(eurc)) {
                // USDC<->EURC -> FX E-Mode 90/94
                assertTrue(m.isFxMode, "USDC->EURC is FX");
                assertEq(m.ltv, 9000, "FX ltv 90%");
                assertEq(m.liquidationThreshold, 9400, "FX LT 94%");
                sawFx = true;
            }
            if (m.collateralAsset == address(weth) && m.debtAsset == address(usdc)) {
                // WETH->USDC -> Standard 75/80
                assertFalse(m.isFxMode, "WETH->USDC is Standard");
                assertEq(m.ltv, 7500, "Standard ltv 75%");
                assertEq(m.liquidationThreshold, 8000, "Standard LT 80%");
                sawStandard = true;
            }
        }
        assertTrue(sawFx && sawStandard, "saw both an FX and a Standard market");
    }

    function test_getAvailableMarkets_availableLiquidity() public view {
        AgentTypes.MarketInfo[] memory markets = pool.getAvailableMarkets();
        for (uint256 i; i < markets.length; ++i) {
            if (markets[i].debtAsset == address(usdc)) {
                // Only lender deposit, no borrows / locked collateral yet -> full balance available.
                assertEq(markets[i].availableLiquidity, 1_000_000e6, "USDC liquidity = deposit");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            getPositionRisk
    //////////////////////////////////////////////////////////////*/

    function test_getPositionRisk_standardMatchesGetHealthFactor() public {
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6); // $30k coll, $15k debt

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        AgentTypes.PositionRisk memory risk = pool.getPositionRisk(key);

        assertTrue(risk.exists, "position exists");
        assertEq(
            risk.healthFactor,
            pool.getHealthFactor(bob, address(weth), address(usdc)),
            "HF matches getHealthFactor (same RiskEngine path)"
        );
        assertTrue(risk.liquidationPriceApplicable, "Standard -> liquidationPrice applicable");
        assertGt(risk.liquidationPrice, 0, "Standard liquidationPrice > 0");
        assertEq(risk.currentDebt, 15_000e6, "currentDebt = borrowed");
        assertEq(risk.collateralValue, 30_000e8, "collateralValue = 10 ETH x $3000");
        assertEq(risk.debtValue, 15_000e8, "debtValue = $15k");
    }

    function test_getPositionRisk_fxReportsBufferNotPrice() public {
        // USDC collateral, borrow EURC -> FX E-Mode.
        _fund(usdc, bob, 20_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 20_000e6, address(eurc), 10_000e6);

        bytes32 key = pool.positionKey(bob, address(usdc), address(eurc));
        AgentTypes.PositionRisk memory risk = pool.getPositionRisk(key);

        assertTrue(risk.exists, "position exists");
        assertFalse(risk.liquidationPriceApplicable, "FX -> liquidationPrice NOT applicable");
        assertEq(risk.liquidationPrice, 0, "FX liquidationPrice sentinel 0");
        assertGt(risk.bufferBps, 0, "FX reports a positive buffer");
        // Sanity: bufferBps derived from HF.
        assertEq(risk.bufferBps, ((risk.healthFactor - WAD) * BPS) / WAD, "bufferBps = (HF-1)xBPS/WAD");
    }

    function test_getPositionRisk_nonexistent() public view {
        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        AgentTypes.PositionRisk memory risk = pool.getPositionRisk(key);
        assertFalse(risk.exists, "nonexistent position -> exists false");
        assertEq(risk.healthFactor, 0, "all fields zero");
    }

    function test_batchGetPositionRisk() public {
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);
        _fund(usdc, bob, 20_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 20_000e6, address(eurc), 10_000e6);

        bytes32[] memory keys = new bytes32[](3);
        keys[0] = pool.positionKey(bob, address(weth), address(usdc));
        keys[1] = pool.positionKey(bob, address(usdc), address(eurc));
        keys[2] = pool.positionKey(alice, address(weth), address(usdc)); // nonexistent

        AgentTypes.PositionRisk[] memory out = pool.batchGetPositionRisk(keys);
        assertEq(out.length, 3, "batch length");
        assertTrue(out[0].exists && out[0].liquidationPriceApplicable, "0: standard exists");
        assertTrue(out[1].exists && !out[1].liquidationPriceApplicable, "1: fx exists");
        assertFalse(out[2].exists, "2: nonexistent");
    }

    /*//////////////////////////////////////////////////////////////
                            previewPosition
    //////////////////////////////////////////////////////////////*/

    function test_previewPosition_matchesRealOpen() public {
        AgentTypes.PreviewResult memory pre =
            pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);

        assertTrue(pre.openable, "preview says openable");
        assertGt(pre.ltvHealthFactor, WAD, "LTV HF > 1");

        // Actually open with the same parameters and compare.
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);

        uint256 realHf = pool.getHealthFactor(bob, address(weth), address(usdc));
        assertEq(pre.healthFactor, realHf, "preview LT-HF == real post-open HF");
    }

    function test_previewPosition_unhealthyNotOpenable() public view {
        // Borrow far beyond LTV: 10 ETH = $30k, LTV 75% -> max ~$22.5k. Ask for $25k.
        AgentTypes.PreviewResult memory pre =
            pool.previewPosition(address(weth), 10e18, address(usdc), 25_000e6);
        assertFalse(pre.openable, "over-LTV -> not openable");
        assertLt(pre.ltvHealthFactor, WAD, "LTV HF < 1");
    }

    function test_previewPosition_illiquidNotOpenable() public view {
        // Request more USDC than is available (deposit is 1_000_000e6).
        AgentTypes.PreviewResult memory pre =
            pool.previewPosition(address(weth), 10_000e18, address(usdc), 2_000_000e6);
        assertFalse(pre.openable, "insufficient liquidity -> not openable");
    }

    /*//////////////////////////////////////////////////////////////
        D-1 consistency: reported liquidationPrice feeds back to a real liquidation
    //////////////////////////////////////////////////////////////*/

    /// @notice The crux of D-1 ②: the liquidationPrice a Standard position reports is the safe boundary
    ///         -- AT that price the SAME RiskEngine.calculateHealthFactor gives exactly 1e18 (healthy, not
    ///         liquidatable, since liquidate requires HF strictly < 1e18); any price strictly BELOW it
    ///         drives HF < 1e18 so a real liquidate() succeeds. Reported price rounds UP, so it never
    ///         understates the danger zone (the agent is never told "safe" at a price that is liquidatable).
    function test_D1_standardLiquidationPriceTriggersRealLiquidation() public {
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 20_000e6); // $30k coll, $20k debt

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        AgentTypes.PositionRisk memory risk = pool.getPositionRisk(key);
        uint256 liqPrice = risk.liquidationPrice;
        assertGt(liqPrice, 0, "have a liquidation price");

        _fund(usdc, liquidator, 20_000e6);

        // (a) AT the reported price -> HF >= 1e18 (boundary, healthy) -> liquidate reverts.
        oracle.setPrice(address(weth), liqPrice);
        assertGe(pool.getHealthFactor(bob, address(weth), address(usdc)), WAD, "at price: HF >= 1");
        vm.prank(liquidator);
        vm.expectRevert(); // PositionHealthy
        pool.liquidate(bob, address(weth), address(usdc), 1_000e6, 0);

        // (b) One tick BELOW the reported price -> HF < 1e18 -> real liquidation succeeds.
        oracle.setPrice(address(weth), liqPrice - 1);
        assertLt(pool.getHealthFactor(bob, address(weth), address(usdc)), WAD, "below price: HF < 1");
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 1_000e6, 0); // does not revert
    }

    /*//////////////////////////////////////////////////////////////
                                Multicall
    //////////////////////////////////////////////////////////////*/

    function test_multicall_atomicAddCollateralAndBorrow() public {
        // Open a small position first.
        _fund(weth, bob, 20e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 5e18, address(usdc), 5_000e6);

        // Batch: addCollateral(+10 ETH) then borrow(+10_000 USDC) in one atomic call.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            LendingPool.addCollateral, (address(weth), address(usdc), 10e18)
        );
        calls[1] = abi.encodeCall(
            LendingPool.borrow, (address(weth), address(usdc), 10_000e6)
        );

        vm.prank(bob);
        pool.multicall(calls);

        // msg.sender preserved across the batch -> position attributed to bob.
        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        DataTypes.Position memory pos = pool.getPosition(key);
        assertEq(pos.collateralAmount, 15e18, "collateral = 5 + 10");
        assertEq(pos.scaledDebt > 0, true, "debt drawn");
        AgentTypes.PositionRisk memory risk = pool.getPositionRisk(key);
        assertEq(risk.currentDebt, 15_000e6, "debt = 5k + 10k");
    }

    function test_multicall_revertsAtomically() public {
        _fund(weth, bob, 20e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 5e18, address(usdc), 5_000e6);

        // Second call over-borrows (exceeds LTV) -> whole batch reverts, first call rolled back.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(LendingPool.addCollateral, (address(weth), address(usdc), 1e18));
        calls[1] = abi.encodeCall(LendingPool.borrow, (address(weth), address(usdc), 1_000_000e6));

        vm.prank(bob);
        vm.expectRevert();
        pool.multicall(calls);

        // First call must NOT have persisted (atomic rollback): collateral still 5 ETH.
        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        DataTypes.Position memory pos = pool.getPosition(key);
        assertEq(pos.collateralAmount, 5e18, "addCollateral rolled back with the batch");
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 0.5e27) / RAY;
    }
}
