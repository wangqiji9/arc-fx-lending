// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {OraclePaused} from "../../src/libraries/DataTypes.sol";

/// @notice Oracle pause must block liquidation — if the price is untrustworthy,
///         liquidators must not be allowed to seize collateral at a potentially wrong price.
contract LiquidatePauseTest is BaseTest {
    address internal lender = makeAddr("lender");
    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        oracle.setGuardian(guardian);

        // lender provides USDC liquidity
        _deposit(usdc, lender, 100_000e6);

        // bob opens WETH→USDC position: 1 WETH collateral, borrow 2000 USDC
        _fund(weth, bob, 5e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // crash ETH price to make bob liquidatable (HF < 1)
        ethFeed.setAnswer(2_000e8); // $3000 → $2000, HF ≈ 0.8

        // fund liquidator
        _fund(usdc, liquidator, 50_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_liquidate_reverts_whenCollateralPaused() public {
        vm.prank(guardian);
        oracle.setPaused(address(weth), true);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(weth)));
        pool.liquidate(bob, address(weth), address(usdc), type(uint256).max);
    }

    function test_liquidate_reverts_whenDebtPaused() public {
        vm.prank(guardian);
        oracle.setPaused(address(usdc), true);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(weth)));
        pool.liquidate(bob, address(weth), address(usdc), type(uint256).max);
    }

    function test_liquidate_succeeds_afterUnpause() public {
        // pause then unpause
        vm.prank(guardian);
        oracle.setPaused(address(weth), true);
        vm.prank(guardian);
        oracle.setPaused(address(weth), false);

        // liquidation should go through
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), type(uint256).max);
    }

    function test_liquidate_succeeds_whenNothingPaused() public {
        // sanity: liquidation works normally without pause
        vm.prank(liquidator);
        pool.liquidate(bob, address(weth), address(usdc), type(uint256).max);
    }
}
