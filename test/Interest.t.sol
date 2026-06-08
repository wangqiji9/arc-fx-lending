// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";

/// @notice Interest rate and accrual: compound index, kink rate, lender earnings, reserveFactor cut.
/// @dev USDC fxPremium=100bps(1%), reserveFactor=1000bps(10%).
///      Uses ETH collateral to borrow USDC, touching only the USDC reserve's rate/index.
contract InterestTest is BaseTest {
    address internal lender = makeAddr("lender");

    uint256 internal constant RAY = 1e27;

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 10_000e6); // lend 10000 USDC
        _fund(weth, bob, 100e18); // bob has ample collateral
    }

    /// @notice util=0.8 (kink): rate = 4% (slope1) + 1% (fxPremium) = 5%.
    function test_rate_atKink() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6); // util 0.8

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.currentBorrowRate, 0.05e27, "rate at kink = 5%");
    }

    /// @notice util=0.9 (above kink): rate = 4% + (0.1/0.2)*75% + 1% = 42.5%.
    function test_rate_aboveKink() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 9_000e6); // util 0.9

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.currentBorrowRate, 0.425e27, "rate above kink = 42.5%");
    }

    /// @notice After one year the borrower owes more: 8000 × (1 + 5%) = 8400.
    function test_interest_borrowerOwesMore() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6); // top up to cover interest
        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        assertEq(paid, 8_400e6, "debt grew by 5%");
    }

    /// @notice After one year the lender earns interest: supplyRate = 5% × 0.8 × (1−10%) = 3.6% → 10000 → 10360.
    function test_interest_lenderEarns() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        // bob repays in full; pool returns to 10400 USDC, lender can withdraw everything
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        vm.prank(lender);
        pool.withdraw(address(usdc), 10_360e6);
        assertEq(usdc.balanceOf(lender), 10_360e6, "lender earned 3.6%");
    }

    /// @notice reserveFactor cut = interest paid by borrower − interest earned by lender = 400 − 360 = 40.
    function test_reserveFactor_cut() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        uint256 borrowerInterest = paid - 8_000e6; // 400
        // lender principal + interest
        uint256 lenderBalance =
            (pool.getScaledDeposit(address(usdc), lender) * pool.getReserveData(address(usdc)).liquidityIndex) / RAY;
        uint256 lenderInterest = lenderBalance - 10_000e6; // 360

        assertEq(borrowerInterest, 400e6, "borrower paid 400");
        assertEq(lenderInterest, 360e6, "lender earned 360");
        assertEq(borrowerInterest - lenderInterest, 40e6, "reserve cut = 10% of interest");
    }

    /// @notice No borrows → no interest accrual: withdraw exactly what was deposited.
    function test_noBorrow_noInterest() public {
        vm.warp(block.timestamp + 365 days);
        vm.prank(lender);
        pool.withdraw(address(usdc), 10_000e6);
        assertEq(usdc.balanceOf(lender), 10_000e6, "no interest without borrows");
    }

    /// @notice borrow index is monotonically non-decreasing (interest only accumulates, never decreases).
    function test_borrowIndex_monotonic() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        uint256 i0 = pool.getReserveData(address(usdc)).borrowIndex;

        vm.warp(block.timestamp + 30 days);
        // trigger a USDC accrual via a small repay
        _fund(usdc, bob, 1e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 1e6);

        uint256 i1 = pool.getReserveData(address(usdc)).borrowIndex;
        assertGt(i1, i0, "borrowIndex grew");
    }
}
