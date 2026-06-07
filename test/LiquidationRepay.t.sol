// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {
    InvalidAmount,
    PositionNotFound,
    PositionHealthy,
    PositionStillCollateralized,
    NotAuthorized
} from "../src/libraries/DataTypes.sol";

/// @notice repay + liquidate(含动态 closeFactor、抵押约束反推、坏账残仓 + Layer3)。
/// @dev 用 ETH→USDC(Standard,LT 80% / bonus 7.5%),改 ETH 价造各种 HF。
contract LiquidationRepayTest is BaseTest {
    address internal lender = makeAddr("lender");

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 100_000e6); // USDC 出借流动性
        _fund(weth, bob, 10e18); // bob 抵押 ETH
        _fund(usdc, liquidator, 100_000e6); // 清算人备 USDC
    }

    /// @notice bob 开 1 ETH($3000) → 借 2000 USDC,HF(LT)=1.2。
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
        usdc.approve(address(pool), type(uint256).max); // 用借到的 USDC 还

        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), 500e6);

        assertEq(paid, 500e6, "paid");
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_500e6, "debt reduced");
    }

    function test_repay_truncatesOverpay() public {
        _openEthPosition();
        _fund(usdc, bob, 5_000e6); // 多给点钱

        vm.prank(bob);
        uint256 paid = pool.repay(bob, address(weth), address(usdc), 5_000e6); // 想还 5000

        assertEq(paid, 2_000e6, "truncated to actual debt");
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "debt cleared");
    }

    function test_repay_byThirdParty() public {
        _openEthPosition();
        // 任何人可替还:liquidator 替 bob 还
        vm.prank(liquidator);
        pool.repay(bob, address(weth), address(usdc), 1_000e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_000e6, "third party repaid");
    }

    function test_repay_thenWithdrawAll_closesPosition() public {
        _openEthPosition();
        _fund(usdc, bob, 5_000e6);

        vm.startPrank(bob);
        pool.repay(bob, address(weth), address(usdc), 2_000e6); // 还清
        pool.withdrawCollateral(address(weth), address(usdc), 1e18); // 取走全部抵押
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
        ethFeed.setAnswer(2500e8); // HF = 2500*0.8/2000 = 1.0,不可清算

        vm.prank(liquidator);
        vm.expectRevert();
        pool.liquidate(bob, address(weth), address(usdc), 1_000e6);
    }

    function test_liquidate_partial_closeFactor50() public {
        _openEthPosition();
        ethFeed.setAnswer(2490e8); // HF = 0.996 ∈ [0.98,1) → closeFactor 50%

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6); // 请求超额,被 maxRepay 截断

        // 50% × 2000 = 1000 USDC 偿还
        uint256 repaid = liqUsdcBefore - usdc.balanceOf(liquidator);
        assertEq(repaid, 1_000e6, "repaid 50%");

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 1_000e6, "half debt remains");

        // seize = 1000 ×1.075 / 2490 ETH = 0.43172e18
        assertApproxEqAbs(weth.balanceOf(liquidator), 0.43172e18, 1e15, "seized collateral");
    }

    function test_liquidate_full_closeFactor100() public {
        _openEthPosition();
        ethFeed.setAnswer(2400e8); // HF = 0.96 < 0.98 → closeFactor 100%

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "full debt cleared");
        // seize = 2000 ×1.075 / 2400 = 0.89583e18,仍有剩余抵押 → 仓位未关
        assertApproxEqAbs(weth.balanceOf(liquidator), 0.89583e18, 1e15, "seized");
        assertGt(pos.collateralAmount, 0, "collateral remains");
        assertEq(pool.getUserPositionKeys(bob).length, 1, "not closed");
    }

    /// @notice 核心修复①:抵押不足时反推 repay —— 清算人按实际能拿到的抵押付款,有利可图。
    function test_liquidate_reverseCompute_badDebt() public {
        _openEthPosition();
        ethFeed.setAnswer(1800e8); // HF = 0.72,且抵押 < 债务×(1+bonus) → 触发反推

        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6);

        // 清算人拿走【全部】抵押 1 ETH
        assertEq(weth.balanceOf(liquidator), 1e18, "got all collateral");

        // 反推 repay = collateralValue/(1+bonus) = 1800/1.075 = 1674.42 USDC
        uint256 paid = liqUsdcBefore - usdc.balanceOf(liquidator);
        assertApproxEqAbs(paid, 1674.42e6, 1e6, "reverse-computed repay");

        // 清算人有利可图:付 1674 USDC 拿 1800 USD 的 ETH
        assertLt(paid, 1800e6, "liquidator profitable");

        // 残债仓位:抵押=0、债务>0 → 不关仓(Layer3 信号)
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.collateralAmount, 0, "collateral drained");
        assertApproxEqAbs(pos.scaledDebt, 325.58e6, 1e6, "residual bad debt");
        assertEq(pool.getUserPositionKeys(bob).length, 1, "residual position kept");
    }

    function test_liquidate_worksWhenOraclePaused() public {
        _openEthPosition();
        ethFeed.setAnswer(2400e8);
        oracle.setPaused(address(weth), true); // 脱锚熔断,但清算永远放行

        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6); // 不 revert

        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        assertEq(pos.scaledDebt, 0, "liquidated despite pause");
    }

    /*//////////////////////////////////////////////////////////////
                       Layer 3:坏账注资
    //////////////////////////////////////////////////////////////*/

    /// @notice 核心修复②:坏账残仓由协议资金清掉。
    function test_repayBadDebt_clearsResidual() public {
        // 先造一个坏账残仓
        _openEthPosition();
        ethFeed.setAnswer(1800e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6);

        // insurer 注资清账
        _fund(usdc, insurer, 1_000e6);
        vm.prank(insurer);
        uint256 cleared = pool.repayBadDebt(bob, address(weth), address(usdc));

        assertApproxEqAbs(cleared, 325.58e6, 1e6, "cleared residual");
        assertEq(pool.getUserPositionKeys(bob).length, 0, "position closed");
        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        assertEq(r.totalScaledBorrow, 0, "no outstanding debt");
    }

    function test_repayBadDebt_revert_stillCollateralized() public {
        // 部分清算后仍有抵押 → 不能走坏账注资
        _openEthPosition();
        ethFeed.setAnswer(2400e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6); // 100% 清债但留抵押

        _fund(usdc, insurer, 5_000e6);
        vm.prank(insurer);
        vm.expectRevert();
        pool.repayBadDebt(bob, address(weth), address(usdc));
    }

    function test_repayBadDebt_revert_notAuthorized() public {
        _openEthPosition();
        ethFeed.setAnswer(1800e8);
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), 5_000e6);

        _fund(usdc, alice, 1_000e6);
        vm.prank(alice); // 非 owner / 非 insuranceFund
        vm.expectRevert(NotAuthorized.selector);
        pool.repayBadDebt(bob, address(weth), address(usdc));
    }
}
