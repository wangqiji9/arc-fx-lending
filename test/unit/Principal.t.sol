// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Keys} from "../../src/libraries/Keys.sol";

/// @notice Tests for principal cost-basis tracking (lender + borrow sides) and live index views.
/// @dev Reference numbers from Interest.t.sol:
///      util=0.8 (kink): borrowRate = 5%, supplyRate = 3.6%
///      After 1 year: 8000 USDC borrowed -> 8400 (5% up), 10000 USDC lent → 10360 (3.6% up).
contract PrincipalTest is BaseTest {
    uint256 internal constant RAY = 1e27;

    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                          Lending side — principal
    //////////////////////////////////////////////////////////////*/

    // 1. Single deposit -> principal == amount
    function test_lend_principal_singleDeposit() public {
        _deposit(usdc, lender, 10_000e6);
        assertEq(pool.getLenderPrincipal(address(usdc), lender), 10_000e6);
    }

    // 2. Multi-deposit at different indexes -> principal == sum of deposits (not a function of index)
    function test_lend_principal_multiDeposit() public {
        _deposit(usdc, lender, 10_000e6);

        // Create borrow to make index grow
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 182 days); // half year, index grows

        // trigger accrual (makes liquidityIndex update in storage)
        _fund(usdc, bob, 1e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 1e6);

        // second deposit at a higher index
        _deposit(usdc, lender, 5_000e6);

        // principal is simply the sum of cash put in; not affected by index
        assertEq(pool.getLenderPrincipal(address(usdc), lender), 15_000e6);
    }

    // 3. Partial withdraw -> principal reduced pro-rata; earned stays >= 0
    // Use lender2 to ensure enough pool liquidity after borrow so lender can withdraw half.
    function test_lend_principal_partialWithdraw() public {
        // lender deposits 10000, lender2 deposits 10000 as extra liquidity buffer
        _deposit(usdc, lender, 10_000e6);
        _deposit(usdc, lender2, 10_000e6);

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        // accrue via repay so liquidityIndex is fresh in storage
        _fund(usdc, bob, 500e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 500e6);

        uint256 principalBefore = pool.getLenderPrincipal(address(usdc), lender);
        uint256 scaledBefore = pool.getScaledDeposit(address(usdc), lender);
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));

        // withdraw 4000 (well within available liquidity: pool has 20000 − 8000 + 500 = 12500 available)
        uint256 withdrawAmt = 4_000e6;
        vm.prank(lender);
        pool.withdraw(address(usdc), withdrawAmt);

        uint256 principalAfter = pool.getLenderPrincipal(address(usdc), lender);
        uint256 scaledAfter = pool.getScaledDeposit(address(usdc), lender);

        // principal reduced proportionally to shares burned
        uint256 expectedPrincipal = (principalBefore * scaledAfter) / scaledBefore;
        assertApproxEqAbs(principalAfter, expectedPrincipal, 1, "principal pro-rata");

        // earned >= 0 always
        r = pool.getReserveData(address(usdc));
        uint256 valueAfter = (scaledAfter * r.liquidityIndex) / RAY;
        assertGe(valueAfter, principalAfter, "earned >= 0 after partial withdraw");
    }

    // 4. Full withdraw -> principal zeroed
    function test_lend_principal_fullWithdraw() public {
        _deposit(usdc, lender, 10_000e6);

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        // withdraw everything
        vm.prank(lender);
        pool.withdraw(address(usdc), 10_360e6);

        assertEq(pool.getLenderPrincipal(address(usdc), lender), 0, "principal zeroed after full withdraw");
    }

    // 5. getLenderPosition: earned == currentValue - principal; numbers match 3.6% year
    function test_lend_getLenderPosition_earned() public {
        _deposit(usdc, lender, 10_000e6);

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        // getLenderPosition uses live liquidityIndex (previewIndexes), no accrual needed
        (uint256 value, uint256 principal, uint256 earned) = pool.getLenderPosition(address(usdc), lender);

        assertEq(principal, 10_000e6, "principal == initial deposit");
        // value ~= 10360e6 (3.6% on 10000), allow 1 wei rounding
        assertApproxEqAbs(value, 10_360e6, 1, "live value == 10360");
        assertEq(earned, value - principal, "earned == value - principal");
        assertApproxEqAbs(earned, 360e6, 1, "earned ~= 360 USDC");
    }

    /*//////////////////////////////////////////////////////////////
                          Borrow side — principal
    //////////////////////////////////////////////////////////////*/

    // 6. openPosition -> borrowPrincipal == borrowAmount
    function test_borrow_principal_openPosition() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        assertEq(pool.getBorrowPrincipal(key), 8_000e6, "principal == borrow amount");
    }

    // 7. Multiple borrows cumulate principal
    function test_borrow_principal_multiBorrow() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 4_000e6);

        // borrow more (still within LTV / cap)
        vm.prank(bob);
        pool.borrow(address(weth), address(usdc), 2_000e6);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        assertEq(pool.getBorrowPrincipal(key), 6_000e6, "principal == total borrowed");
    }

    // 8. getBorrowInterest warp -> accruedInterest == liveDebt − principal ~= 5% year
    function test_borrow_getBorrowInterest_oneYear() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        (uint256 liveDebt, uint256 principal, uint256 accruedInterest) = pool.getBorrowInterest(key);

        assertEq(principal, 8_000e6, "principal == 8000");
        assertApproxEqAbs(liveDebt, 8_400e6, 1, "live debt ~= 8400");
        assertEq(accruedInterest, liveDebt - principal, "accruedInterest == liveDebt - principal");
        assertApproxEqAbs(accruedInterest, 400e6, 1, "accrued ~= 400 USDC");
    }

    // 9. Partial repay -> principal pro-rata reduced; remaining accruedInterest ≥ 0
    function test_borrow_principal_partialRepay() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        uint256 principalBefore = pool.getBorrowPrincipal(key);
        uint256 scaledBefore = pool.getPosition(key).scaledDebt;

        // repay 4000 (roughly half the debt)
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 4_000e6);

        uint256 principalAfter = pool.getBorrowPrincipal(key);
        uint256 scaledAfter = pool.getPosition(key).scaledDebt;

        // principal reduced proportionally to shares burned
        uint256 expectedPrincipal = (principalBefore * scaledAfter) / scaledBefore;
        assertApproxEqAbs(principalAfter, expectedPrincipal, 1, "borrow principal pro-rata");

        // accruedInterest still ≥ 0
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        uint256 remaining = (scaledAfter * r.borrowIndex) / RAY;
        assertGe(remaining, principalAfter, "accrued >= 0 after partial repay");
    }

    // 10. Full repay -> principal zeroed
    function test_borrow_principal_fullRepay() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        assertEq(pool.getBorrowPrincipal(key), 0, "principal zeroed after full repay");
    }

    // 11. Liquidation -> borrowPrincipal pro-rata reduced; no negative earned
    function test_borrow_principal_liquidation() public {
        _deposit(usdc, lender, 10_000e6);

        // bob opens position at 75% LTV, then price drops to trigger liquidation
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 7_500e6); // 75% LTV of $30000

        // price drop: ETH $3000 -> $600 → HF = 10×600×0.8/7500 = 0.64 < 1
        oracle.setPrice(address(weth), 600e8);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));
        uint256 principalBefore = pool.getBorrowPrincipal(key);
        uint256 scaledBefore = pool.getPosition(key).scaledDebt;

        // partial liquidation: repay 3000
        _fund(usdc, liquidator, 10_000e6);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 3_000e6, 0);

        uint256 principalAfter = pool.getBorrowPrincipal(key);
        uint256 scaledAfter = pool.getPosition(key).scaledDebt;

        // principal reduced pro-rata
        uint256 expectedPrincipal = (principalBefore * scaledAfter) / scaledBefore;
        assertApproxEqAbs(principalAfter, expectedPrincipal, 1, "liq: principal pro-rata");

        // accruedInterest ≥ 0
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        uint256 remaining = (scaledAfter * r.borrowIndex) / RAY;
        assertGe(remaining, principalAfter, "liq: accrued >= 0");
    }

    // 12. repayBadDebt -> borrowPrincipal zeroed
    function test_borrow_principal_repayBadDebt() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 7_500e6);

        // price crashes to 0 — make position collateral worthless, then liquidate all collateral
        oracle.setPrice(address(weth), 100e8); // very low
        _fund(usdc, liquidator, 10_000e6);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), type(uint128).max, 0);

        // position now has collateral==0 and debt>0 (bad debt)
        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));

        // insurer covers bad debt
        _fund(usdc, insurer, 10_000e6);
        vm.prank(insurer);
        pool.repayBadDebt(bob, address(weth), address(usdc));

        assertEq(pool.getBorrowPrincipal(key), 0, "bad debt: principal zeroed");
    }

    /*//////////////////////////////////////////////////////////////
                          Live index view tests
    //////////////////////////////////////////////////////////////*/

    // 13. getLiveReserveData == actual accrued values
    function test_liveReserveData_matchesAccrual() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        // read live values BEFORE any state-changing operation
        (uint256 liveBorrow, uint256 liveLiquidity) = pool.getLiveReserveData(address(usdc));

        // trigger actual accrual by depositing 1 wei (the smallest possible state change)
        _deposit(usdc, lender2, 1);

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));

        // previewIndexes must match the accrual within 1 ray (single rayMul rounding)
        assertApproxEqAbs(liveBorrow, r.borrowIndex, 1, "live borrowIndex matches accrual");
        assertApproxEqAbs(liveLiquidity, r.liquidityIndex, 1, "live liquidityIndex matches accrual");
    }

    // 14. getPositionRisk uses live borrowIndex -> currentDebt matches actual accrual
    function test_getPositionRisk_liveDebt() public {
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        bytes32 key = pool.positionKey(bob, address(weth), address(usdc));

        // live view debt (no accrual)
        uint256 liveDebt = pool.getPositionRisk(key).currentDebt;

        // trigger actual accrual
        _fund(usdc, bob, 500e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 500e6);

        // actual debt after partial repay = accrual − 500
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        uint256 scaledNow = pool.getPosition(key).scaledDebt;
        uint256 debtAfterRepay = (scaledNow * r.borrowIndex) / RAY;

        // liveDebt − 500 ~= debtAfterRepay (within 1 wei rounding)
        assertApproxEqAbs(liveDebt, debtAfterRepay + 500e6, 1, "getPositionRisk live debt matches");
    }
}
