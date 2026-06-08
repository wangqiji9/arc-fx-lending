// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {RateEngine} from "../../src/libraries/RateEngine.sol";

/// @notice Rate system dynamic behavior tests:
///   1. Rate jump when utilization crosses kink
///   2. Segmented warp accrual vs once-off warp
///   3. Utilization drops to zero boundary
///   4. Long-duration index precision (no overflow)
///   5. Lazy accrue timing verification
/// @dev Verifies that key system parameters (util, borrowRate, supplyRate, indexes) are
///      correctly updated immediately after each operation.
contract RateDynamicsTest is BaseTest {
    address internal lender = makeAddr("lender");

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 100_000e6); // large pool for utilization tests
        _fund(weth, bob, 200e18);
    }

    /*//////////////////////////////////////////////////////////////
        #1  Utilization crosses kink — rate jumps correctly
    //////////////////////////////////////////////////////////////*/

    /// @notice 70%->85%: rate moves from slope1 (below kink) into slope2 (above kink).
    function test_rateCrossesKink_borrowPushesAbove() public {
        // borrow 70_000 -> util=0.7 -> rate = (0.7/0.8)*4% + 1% = 4.5%
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 70_000e6);

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));
        uint256 expectedRate70 = _calcRate(0.7e27);
        assertEq(r0.currentBorrowRate, expectedRate70, "rate at 70% util");

        // additional borrow 15_000 -> util=0.85 -> rate = 4% + (0.05/0.2)*75% + 1% = 23.75%
        vm.prank(bob);
        pool.borrow(address(weth), address(usdc), 15_000e6);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        uint256 expectedRate85 = _calcRate(0.85e27);
        assertEq(r1.currentBorrowRate, expectedRate85, "rate at 85% util");
        assertGt(r1.currentBorrowRate, r0.currentBorrowRate, "rate jumped crossing kink");
    }

    /// @notice 85%->75%: repayment pushes utilization back below kink.
    function test_rateCrossesKink_repayPushesBelow() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 85_000e6); // util=0.85

        DataTypes.ReserveData memory rAbove = pool.getReserveData(address(usdc));
        assertGt(rAbove.currentBorrowRate, 0.05e27, "above kink: rate > 5%");

        // repay 10_000 -> util ~ 0.75 (below kink)
        _fund(usdc, bob, 10_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 10_000e6);

        DataTypes.ReserveData memory rBelow = pool.getReserveData(address(usdc));
        assertLt(rBelow.currentBorrowRate, rAbove.currentBorrowRate, "rate dropped after repay");
        assertLt(rBelow.currentBorrowRate, 0.05e27, "back below kink: rate < 5%");
    }

    /// @notice Deposit increases supply, lowers utilization, rate drops.
    function test_rateDropsOnDeposit() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 80_000e6); // util=0.8

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));
        assertEq(r0.currentBorrowRate, 0.05e27, "rate at kink = 5%");

        // new lender deposits 20_000 -> supply=120_000, borrow=80_000 -> util=0.667
        _deposit(usdc, makeAddr("lender2"), 20_000e6);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        assertLt(r1.currentBorrowRate, r0.currentBorrowRate, "rate drops when supply increases");
    }

    /// @notice Withdraw reduces supply, raises utilization, rate rises.
    function test_rateRisesOnWithdraw() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 70_000e6); // util=0.7

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));

        // lender withdraws 10_000 -> supply=90_000, borrow=70_000 -> util~0.778
        vm.prank(lender);
        pool.withdraw(address(usdc), 10_000e6);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        assertGt(r1.currentBorrowRate, r0.currentBorrowRate, "rate rises when supply decreases");
    }

    /*//////////////////////////////////////////////////////////////
        #2  Segmented warp accrual vs once-off warp — precision
    //////////////////////////////////////////////////////////////*/

    /// @notice Linear approximation: segmented accrual (12x30d) >= once-off (365d), small deviation.
    /// @dev util is set well below kink (0.5) to isolate the "linear vs compound" variable.
    ///      At the kink (0.8), compounding pushes util into slope2 and amplifies deviation
    ///      to ~2.5% — that's real protocol behavior, not a bug.
    function test_segmented_vs_onceOff_accrual() public {
        // util = 50_000/100_000 = 0.5 -> rate = (0.5/0.8)*4% + 1% = 3.5%, stable in slope1
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 50_000e6);

        uint256 snapshot = vm.snapshot();
        uint256 startTs = block.timestamp;

        // Path A: once-off warp 365 days -> accrue
        vm.warp(startTs + 365 days);
        _fund(usdc, bob, 10_000e6);
        vm.prank(bob);
        uint256 paidOnce = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        // Path B: segmented warp 12x30 days + 5 days
        vm.revertTo(snapshot);
        uint256 ts = startTs;
        for (uint256 i; i < 12; i++) {
            ts += 30 days;
            vm.warp(ts);
            // trigger accrue: small operation
            _fund(usdc, bob, 1e6);
            vm.prank(bob);
            pool.repay(bob, address(weth), address(usdc), 1e6);
        }
        ts += 5 days; // remaining 5 days (12x30+5 = 365)
        vm.warp(ts);
        _fund(usdc, bob, 10_000e6);
        vm.prank(bob);
        uint256 paidSegmented = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        // linear approx: segmented >= once-off (compound (1+r*dt)^n > 1+r*n*dt)
        assertGe(paidSegmented, paidOnce, "segmented accrual >= once-off");
        // slope1 flat region: deviation < 0.5% relative
        uint256 diff = paidSegmented - paidOnce;
        assertLt(diff * 10_000 / paidOnce, 50, "deviation < 0.5% when far from kink");
    }

    /*//////////////////////////////////////////////////////////////
        #3  Utilization drops to zero — boundary behavior
    //////////////////////////////////////////////////////////////*/

    /// @notice Full repayment: rate drops to fxPremium (USDC fxPremium = 1%).
    function test_fullRepay_rateDropsToFxPremium() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 5_000e6);

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));
        assertGt(r0.currentBorrowRate, 0, "rate > 0 with borrows");

        // full repay
        _fund(usdc, bob, 5_000e6); // ensure sufficient balance
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        // util=0 -> rate = BASE_RATE + fxPremium = 0 + 1% = 1%
        uint256 fxPremiumRay = (uint256(100) * RAY) / BPS; // 1% in ray
        assertEq(r1.currentBorrowRate, fxPremiumRay, "rate = fxPremium when util=0");
        assertEq(r1.totalScaledBorrow, 0, "no outstanding borrows");
    }

    /// @notice Zero utilization: warp does not accrue interest (indexes unchanged).
    function test_zeroUtil_noAccrual() public {
        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));
        uint256 borrowIdx0 = r0.borrowIndex;
        uint256 liqIdx0 = r0.liquidityIndex;

        vm.warp(block.timestamp + 365 days);

        // trigger accrue (deposit calls _accrue)
        _deposit(usdc, makeAddr("trigger"), 1e6);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        assertEq(r1.borrowIndex, borrowIdx0, "borrowIndex unchanged at zero util");
        assertEq(r1.liquidityIndex, liqIdx0, "liquidityIndex unchanged at zero util");
    }

    /*//////////////////////////////////////////////////////////////
        #4  Long duration — high rate for 10 years, no overflow
    //////////////////////////////////////////////////////////////*/

    /// @notice 42.5% annual rate (util=0.9) for 10 years: index ~ 28e27, well within uint128.
    function test_highRate_10years_noOverflow() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 90_000e6); // util=0.9

        uint256 ts = block.timestamp;
        // 10 years, accrue once per year
        for (uint256 y; y < 10; y++) {
            ts += 365 days;
            vm.warp(ts);
            _fund(usdc, bob, 1e6);
            vm.prank(bob);
            pool.repay(bob, address(weth), address(usdc), 1e6);
        }

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        // borrowIndex should be ~1e27 * 1.425^10 ~ 28e27, far below uint128.max ~ 3.4e38
        assertGt(r.borrowIndex, 20e27, "index grew significantly");
        assertLt(uint256(r.borrowIndex), type(uint128).max, "no overflow");
        // liquidityIndex also grows
        assertGt(r.liquidityIndex, r.borrowIndex / 2, "liquidityIndex grew proportionally");
    }

    /*//////////////////////////////////////////////////////////////
        #5  Lazy accrue — index stale until operation triggers it
    //////////////////////////////////////////////////////////////*/

    /// @notice After warp, index remains stale until an operation triggers accrue.
    function test_lazyAccrue_indexStaleUntilOperation() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        DataTypes.ReserveData memory rBefore = pool.getReserveData(address(usdc));
        uint256 idxBefore = rBefore.borrowIndex;

        // warp 30 days — no operation
        vm.warp(block.timestamp + 30 days);

        // read directly: index is still the old value (storage not updated)
        DataTypes.ReserveData memory rStale = pool.getReserveData(address(usdc));
        assertEq(rStale.borrowIndex, idxBefore, "index stale before accrue");

        // operation triggers accrue
        _fund(usdc, bob, 1e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 1e6);

        DataTypes.ReserveData memory rFresh = pool.getReserveData(address(usdc));
        assertGt(rFresh.borrowIndex, idxBefore, "index updated after accrue");
    }

    /// @notice currentBorrowRate does not change by time alone — only by operations that call _refreshRate.
    function test_lazyAccrue_rateUnchangedByTimeAlone() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));

        vm.warp(block.timestamp + 180 days);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));
        assertEq(r1.currentBorrowRate, r0.currentBorrowRate, "rate unchanged by time alone");
    }

    /*//////////////////////////////////////////////////////////////
        #6  Supply vs borrow index growth ratio
    //////////////////////////////////////////////////////////////*/

    /// @notice liquidityIndex growth = borrowIndex growth * util * (1 - reserveFactor).
    function test_supplyIndex_lessThan_borrowIndex_growth() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 80_000e6); // util=0.8

        DataTypes.ReserveData memory r0 = pool.getReserveData(address(usdc));

        vm.warp(block.timestamp + 365 days);
        _fund(usdc, bob, 1e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 1e6);

        DataTypes.ReserveData memory r1 = pool.getReserveData(address(usdc));

        // borrowIndex growth
        uint256 borrowGrowth = r1.borrowIndex - r0.borrowIndex;
        // liquidityIndex growth
        uint256 liqGrowth = r1.liquidityIndex - r0.liquidityIndex;
        // expected: liqGrowth ~ borrowGrowth * 0.8 * 0.9 = borrowGrowth * 0.72
        uint256 expectedLiqGrowth = borrowGrowth * 72 / 100;
        assertApproxEqRel(liqGrowth, expectedLiqGrowth, 0.01e18, "liquidityIndex growth ~ 72% of borrowIndex growth");
    }

    /// @notice After operations, liquidityIndex <= borrowIndex (always holds).
    function test_liquidityIndex_leq_borrowIndex() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 100e18, address(usdc), 80_000e6);

        for (uint256 i; i < 6; i++) {
            vm.warp(block.timestamp + 60 days);
            _fund(usdc, bob, 1e6);
            vm.prank(bob);
            pool.repay(bob, address(weth), address(usdc), 1e6);

            DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
            assertLe(r.liquidityIndex, r.borrowIndex, "liquidityIndex <= borrowIndex");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Mirror of RateEngine.calculateBorrowRate logic for test assertions.
    function _calcRate(uint256 util) internal pure returns (uint256) {
        uint256 rate;
        uint256 KINK = 0.8e27;
        uint256 SLOPE1 = 0.04e27;
        uint256 SLOPE2 = 0.75e27;
        if (util <= KINK) {
            rate = (util * SLOPE1) / KINK;
        } else {
            uint256 excess = util - KINK;
            rate = SLOPE1 + (excess * SLOPE2) / (RAY - KINK);
        }
        // USDC fxPremium = 100bps = 1%
        rate += (uint256(100) * RAY) / BPS;
        return rate;
    }
}
