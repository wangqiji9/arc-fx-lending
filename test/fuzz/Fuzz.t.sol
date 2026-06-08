// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @notice T-9: Property-based fuzz tests for core protocol invariants.
/// Each test verifies one algebraic property with random inputs via bound().
/// Config used throughout: WETH LTV=75%, LT=80%; USDC $1; ETH $3000.
/// Key boundary: maxBorrowUSDC = 3000e8 * 7500/10000 * 1e6/1e8 = 2250e6.
/// Liquidation price threshold: ethPrice < 2500e8 for (1 ETH, 2000 USDC, LT 80%).
contract FuzzTest is BaseTest {
    address internal lender = makeAddr("lender");

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 100_000e6);
    }

    // -----------------------------------------------------------------------
    // Property 1: deposit → withdraw roundtrip is lossless
    // -----------------------------------------------------------------------

    /// @notice For any deposit amount in [1, 50_000e6], a full withdraw recovers
    ///         exactly the deposited amount (no rounding loss at scale index=RAY).
    function test_fuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, 1, 50_000e6);

        address user = makeAddr("user");
        _fund(usdc, user, amount);

        vm.prank(user);
        pool.deposit(address(usdc), amount);

        uint256 balBefore = usdc.balanceOf(user);

        vm.prank(user);
        pool.withdraw(address(usdc), amount);

        uint256 received = usdc.balanceOf(user) - balBefore;
        assertEq(received, amount, "roundtrip: no loss");
    }

    // -----------------------------------------------------------------------
    // Property 2: repay is clamped to actual debt (never overpays)
    // -----------------------------------------------------------------------

    /// @notice repay(repayAmount) returns at most the actual debt (2000e6 + dust).
    ///         Even if repayAmount > debt, paid <= actualDebt.
    function test_fuzz_repay_clamped_to_debt(uint256 repayAmount) public {
        repayAmount = bound(repayAmount, 1, 10_000e6);

        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // Mint extra USDC so bob can attempt any repay amount
        usdc.mint(bob, 10_000e6);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        uint256 bobBalBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), repayAmount);

        uint256 actualSpent = bobBalBefore - usdc.balanceOf(bob);

        // paid must equal what was actually pulled
        assertEq(paid, actualSpent, "repay: returned value matches token transfer");
        // paid never exceeds the original 2000e6 debt (no interest accrued in same block)
        assertLe(paid, 2_000e6, "repay: clamped to actual debt");
    }

    // -----------------------------------------------------------------------
    // Property 3: openPosition respects LTV boundary
    // -----------------------------------------------------------------------

    /// @notice 1 ETH @ $3000 with LTV 75% → maxBorrow = 2250e6 USDC exactly.
    ///         borrowAmount > 2250e6 must revert with HealthFactorTooLow.
    ///         borrowAmount <= 2250e6 must succeed.
    function test_fuzz_openPosition_ltv_enforced(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1, 5_000e6);

        _fund(weth, bob, 1e18);

        if (borrowAmount > 2_250e6) {
            vm.prank(bob);
            try pool.openPosition(address(weth), 1e18, address(usdc), borrowAmount) {
                revert("should have reverted above LTV");
            } catch (bytes memory reason) {
                assertGt(reason.length, 0, "must revert with data");
                bytes4 sel = bytes4(reason);
                assertEq(sel, bytes4(keccak256("HealthFactorTooLow(uint256)")), "wrong error");
            }
        } else {
            vm.prank(bob);
            pool.openPosition(address(weth), 1e18, address(usdc), borrowAmount);
            bytes32[] memory keys = pool.getUserPositionKeys(bob);
            assertEq(keys.length, 1, "position created");
        }
    }

    // -----------------------------------------------------------------------
    // Property 4: addCollateral never decreases health factor
    // -----------------------------------------------------------------------

    /// @notice After bob opens a position, adding any positive collateral amount
    ///         must not decrease the health factor.
    function test_fuzz_addCollateral_hf_nondecreasing(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e15, 5e18); // 0.001 ETH to 5 ETH

        _fund(weth, bob, 6e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 1_500e6);

        uint256 hfBefore = pool.getHealthFactor(bob, address(weth), address(usdc));

        vm.prank(bob);
        pool.addCollateral(address(weth), address(usdc), addAmount);

        uint256 hfAfter = pool.getHealthFactor(bob, address(weth), address(usdc));

        assertGe(hfAfter, hfBefore, "addCollateral: HF must not decrease");
    }

    // -----------------------------------------------------------------------
    // Property 5: liquidatability determined by ETH price vs threshold
    // -----------------------------------------------------------------------

    /// @notice For 1 ETH collateral and 2000 USDC debt (LT 80%):
    ///         HF < 1 iff ethPrice < 2500e8.
    ///         Below threshold → liquidate succeeds; at/above → reverts PositionHealthy.
    function test_fuzz_ethPrice_liquidatable(uint256 ethPrice) public {
        ethPrice = bound(ethPrice, 500e8, 5_000e8);

        _fund(weth, bob, 1e18);
        // Open at $3000 — safe
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // Move price to fuzz value
        ethFeed.setAnswer(int256(ethPrice));

        // Fund liquidator
        _fund(usdc, liquidator, 10_000e6);

        if (ethPrice < 2_500e8) {
            // Should be liquidatable (HF < 1)
            vm.prank(liquidator);
            pool.liquidate(bob, address(weth), address(usdc), 1_000e6);
            // If we reach here, liquidation succeeded
        } else {
            // Should revert with PositionHealthy
            vm.prank(liquidator);
            vm.expectRevert();
            pool.liquidate(bob, address(weth), address(usdc), 1_000e6);
        }
    }
}
