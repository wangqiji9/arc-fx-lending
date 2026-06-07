// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";

/// @notice 利率与计息:index 复利、kink 利率、出借人收益、reserveFactor 抽成。
/// @dev USDC fxPremium=100bps(1%),reserveFactor=1000bps(10%)。
///      用 ETH 抵押借 USDC,只动 USDC reserve 的利率/index。
contract InterestTest is BaseTest {
    address internal lender = makeAddr("lender");

    uint256 internal constant RAY = 1e27;

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 10_000e6); // 出借 10000 USDC
        _fund(weth, bob, 100e18); // bob 充足抵押
    }

    /// @notice util=0.8(kink):rate = 4%(slope1) + 1%(fxPremium) = 5%。
    function test_rate_atKink() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6); // util 0.8

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.currentBorrowRate, 0.05e27, "rate at kink = 5%");
    }

    /// @notice util=0.9(kink 之上):rate = 4% + (0.1/0.2)*75% + 1% = 42.5%。
    function test_rate_aboveKink() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 9_000e6); // util 0.9

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.currentBorrowRate, 0.425e27, "rate above kink = 42.5%");
    }

    /// @notice 一年后借款人欠更多:8000 × (1 + 5%) = 8400。
    function test_interest_borrowerOwesMore() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6); // 补够利息
        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        assertEq(paid, 8_400e6, "debt grew by 5%");
    }

    /// @notice 一年后出借人赚息:supplyRate = 5% × 0.8 × (1−10%) = 3.6% → 10000 → 10360。
    function test_interest_lenderEarns() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);

        vm.warp(block.timestamp + 365 days);

        // bob 还清,池子回到 10400 USDC,出借人可全额提
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        vm.prank(lender);
        pool.withdraw(address(usdc), 10_360e6);
        assertEq(usdc.balanceOf(lender), 10_360e6, "lender earned 3.6%");
    }

    /// @notice reserveFactor 抽成 = 借款人付的息 − 出借人得的息 = 400 − 360 = 40。
    function test_reserveFactor_cut() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        vm.warp(block.timestamp + 365 days);

        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), type(uint128).max);

        uint256 borrowerInterest = paid - 8_000e6; // 400
        // 出借人本息
        uint256 lenderBalance =
            (pool.getScaledDeposit(address(usdc), lender) * pool.getReserveData(address(usdc)).liquidityIndex) / RAY;
        uint256 lenderInterest = lenderBalance - 10_000e6; // 360

        assertEq(borrowerInterest, 400e6, "borrower paid 400");
        assertEq(lenderInterest, 360e6, "lender earned 360");
        assertEq(borrowerInterest - lenderInterest, 40e6, "reserve cut = 10% of interest");
    }

    /// @notice 无借款 → 无计息:存入多少取出多少。
    function test_noBorrow_noInterest() public {
        vm.warp(block.timestamp + 365 days);
        vm.prank(lender);
        pool.withdraw(address(usdc), 10_000e6);
        assertEq(usdc.balanceOf(lender), 10_000e6, "no interest without borrows");
    }

    /// @notice index 单调不减(滚息只增不减)。
    function test_borrowIndex_monotonic() public {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6);
        uint256 i0 = pool.getReserveData(address(usdc)).borrowIndex;

        vm.warp(block.timestamp + 30 days);
        // 触发一次 USDC accrue(小额 repay)
        _fund(usdc, bob, 1e6);
        vm.prank(bob);
        pool.repay(bob, address(weth), address(usdc), 1e6);

        uint256 i1 = pool.getReserveData(address(usdc)).borrowIndex;
        assertGt(i1, i0, "borrowIndex grew");
    }
}
