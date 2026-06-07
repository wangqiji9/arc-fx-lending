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

        // index = RAY 时 scaled == amount
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
        // alice 出借 1000 USDC,bob 抵押 ETH 借走 800 USDC → 池里只剩 200
        _deposit(usdc, alice, 1_000e6);

        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 800e6);

        // alice 想取 300,但物理可借只剩 200 → InsufficientLiquidity
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(usdc)));
        pool.withdraw(address(usdc), 300e6);

        // 取 200 可以
        vm.prank(alice);
        pool.withdraw(address(usdc), 200e6);
        assertEq(usdc.balanceOf(alice), 200e6, "withdrew available");
    }

    function test_withdraw_excludesCollateralFromLiquidity() public {
        // 目标:证明可借流动性 = balanceOf − totalCollateral,抵押那部分不算可提取。
        // 构造 alice 余额(1000) > 可借量(400),让流动性检查成为绑定约束。
        address carol = makeAddr("carol");
        _deposit(usdc, alice, 1_000e6); // alice 余额 1000,物理 USDC 1000
        _deposit(eurc, carol, 1_000e6); // 给 bob 借 EURC 用

        // bob 仓位1:抵押 1000 USDC 借 500 EURC → 物理 USDC 2000,totalCollateral[usdc]=1000
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);

        // bob 仓位2:抵押 ETH 借 600 USDC → 物理 USDC 1400
        _fund(weth, bob, 1e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 600e6);

        // 可借 = 1400 − 1000(抵押) = 400。alice 余额 1000 但只能取 400。
        assertEq(usdc.balanceOf(address(pool)), 1_400e6, "physical balance");
        assertEq(pool.getTotalCollateral(address(usdc)), 1_000e6, "locked collateral");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(usdc)));
        pool.withdraw(address(usdc), 500e6); // 若抵押被错误计入,500 会通过

        vm.prank(alice);
        pool.withdraw(address(usdc), 400e6); // 恰好等于可借量
        assertEq(usdc.balanceOf(alice), 400e6, "withdrew exactly available");
    }
}
