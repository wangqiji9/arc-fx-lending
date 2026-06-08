// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {OraclePaused} from "../../src/libraries/DataTypes.sol";

/// @notice T-M2: oracle pause gate covers withdrawCollateral but not lender withdraw.
contract OraclePauseTest is BaseTest {
    address internal lender = makeAddr("lender");
    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        oracle.setGuardian(guardian);
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 5e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);
    }

    function test_withdrawCollateral_revert_whenCollateralPaused() public {
        vm.prank(guardian);
        oracle.setPaused(address(weth), true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(weth)));
        pool.withdrawCollateral(address(weth), address(usdc), 0.1e18);
    }

    function test_withdrawCollateral_revert_whenDebtPaused() public {
        vm.prank(guardian);
        oracle.setPaused(address(usdc), true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OraclePaused.selector, address(weth)));
        pool.withdrawCollateral(address(weth), address(usdc), 0.1e18);
    }

    function test_lenderWithdraw_allowed_whenOraclePaused() public {
        vm.prank(guardian);
        oracle.setPaused(address(usdc), true);

        // lender withdraw should succeed — oracle pause must not block liquidity exit
        vm.prank(lender);
        pool.withdraw(address(usdc), 1_000e6);
    }

    function test_withdrawCollateral_succeeds_afterUnpause() public {
        vm.prank(guardian);
        oracle.setPaused(address(weth), true);

        vm.prank(guardian);
        oracle.setPaused(address(weth), false);

        vm.prank(bob);
        pool.withdrawCollateral(address(weth), address(usdc), 0.1e18);
    }
}
