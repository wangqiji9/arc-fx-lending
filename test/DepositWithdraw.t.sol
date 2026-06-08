// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {
    InvalidAmount,
    AssetNotConfigured,
    InsufficientBalance,
    InsufficientLiquidity,
    OraclePaused
} from "../src/libraries/DataTypes.sol";

contract DepositWithdrawTest is BaseTest {
    function test_deposit_mintsScaledShares() public {
        _deposit(usdc, alice, 1_000e6);

        // when index = RAY, scaled == amount
        assertEq(pool.getScaledDeposit(address(usdc), alice), 1_000e6, "scaled deposit");
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.totalScaledSupply, 1_000e6, "total scaled supply");
        assertEq(usdc.balanceOf(address(pool)), 1_000e6, "pool balance");
    }

    function test_deposit_revert_zeroAmount() public {
        _fund(usdc, alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(InvalidAmount.selector);
        pool.deposit(address(usdc), 0);
    }

    function test_deposit_revert_notConfigured() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AssetNotConfigured.selector, address(0xdead)));
        pool.deposit(address(0xdead), 1e6);
    }

    function test_deposit_revert_whenPaused() public {
        oracle.setPaused(address(usdc), true);
        _fund(usdc, alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(usdc)));
        pool.deposit(address(usdc), 1_000e6);
    }

    function test_withdraw_returnsPrincipal() public {
        _deposit(usdc, alice, 1_000e6);

        vm.prank(alice);
        pool.withdraw(address(usdc), 400e6);

        assertEq(usdc.balanceOf(alice), 400e6, "alice received");
        assertEq(pool.getScaledDeposit(address(usdc), alice), 600e6, "remaining scaled");
        assertEq(usdc.balanceOf(address(pool)), 600e6, "pool balance");
    }

    function test_withdraw_full_clearsShares() public {
        _deposit(usdc, alice, 1_000e6);

        vm.prank(alice);
        pool.withdraw(address(usdc), 1_000e6);

        assertEq(pool.getScaledDeposit(address(usdc), alice), 0, "scaled cleared");
        assertEq(usdc.balanceOf(alice), 1_000e6, "full principal back");
    }

    function test_withdraw_revert_exceedsBalance() public {
        _deposit(usdc, alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        pool.withdraw(address(usdc), 1_000e6 + 1);
    }

    function test_withdraw_revert_insufficientLiquidity() public {
        // alice lends 1000 USDC, bob uses ETH as collateral to borrow 800 USDC → only 200 left in pool
        _deposit(usdc, alice, 1_000e6);

        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 800e6);

        // alice wants to withdraw 300, but only 200 physically available → InsufficientLiquidity
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(usdc)));
        pool.withdraw(address(usdc), 300e6);

        // withdrawing 200 succeeds
        vm.prank(alice);
        pool.withdraw(address(usdc), 200e6);
        assertEq(usdc.balanceOf(alice), 200e6, "withdrew available");
    }

    function test_withdraw_excludesCollateralFromLiquidity() public {
        // Goal: prove that available liquidity = balanceOf − totalCollateral; collateral is not withdrawable.
        // Construct: alice balance (1000) > available amount (400), so the liquidity check is the binding constraint.
        address carol = makeAddr("carol");
        _deposit(usdc, alice, 1_000e6); // alice balance 1000, physical USDC 1000
        _deposit(eurc, carol, 1_000e6); // provide EURC liquidity for bob to borrow

        // bob position 1: 1000 USDC collateral, borrow 500 EURC → physical USDC 2000, totalCollateral[usdc]=1000
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);

        // bob position 2: ETH collateral, borrow 600 USDC → physical USDC 1400
        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 600e6);

        // Available = 1400 − 1000 (collateral) = 400. alice balance 1000 but can only withdraw 400.
        assertEq(usdc.balanceOf(address(pool)), 1_400e6, "physical balance");
        assertEq(pool.getTotalCollateral(address(usdc)), 1_000e6, "locked collateral");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(usdc)));
        pool.withdraw(address(usdc), 500e6); // would pass if collateral were incorrectly counted as liquid

        vm.prank(alice);
        pool.withdraw(address(usdc), 400e6); // exactly equal to available liquidity
        assertEq(usdc.balanceOf(alice), 400e6, "withdrew exactly available");
    }
}
