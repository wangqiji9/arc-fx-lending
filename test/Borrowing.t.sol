// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {
    InvalidAmount,
    SameAsset,
    AssetNotBorrowable,
    BorrowCapExceeded,
    CollateralCapExceeded,
    InsufficientLiquidity,
    InsufficientCollateral,
    HealthFactorTooLow,
    PositionNotFound
} from "../src/libraries/DataTypes.sol";

contract BorrowingTest is BaseTest {
    address internal lender = makeAddr("lender");

    function _seedEurc(uint256 amount) internal {
        _deposit(eurc, lender, amount);
    }

    function _seedUsdc(uint256 amount) internal {
        _deposit(usdc, lender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              openPosition
    //////////////////////////////////////////////////////////////*/

    function test_openPosition_FX_createsPosition() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);

        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 500e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(eurc));
        assertEq(pos.collateralAmount, 1_000e6, "collateral");
        assertEq(pos.scaledDebt, 500e6, "scaled debt (index=RAY)");
        assertEq(pos.collateralAsset, address(usdc));
        assertEq(pos.debtAsset, address(eurc));

        assertEq(pool.getTotalCollateral(address(usdc)), 1_000e6, "total collateral");
        assertEq(pool.getUserPositionKeys(bob).length, 1, "one position key");
        assertEq(eurc.balanceOf(bob), 500e6, "borrowed eurc received");

        // Liquidation HF (LT 94%): 1000×0.94 / (500×1.08) = 940/540 = 1.7407
        uint256 hf = pool.getHealthFactor(bob, address(usdc), address(eurc));
        assertApproxEqAbs(hf, 1.7407e18, 1e15, "liquidation HF");
    }

    function test_openPosition_FX_gatedByLTV_not_LT() public {
        // 1000 USDC collateral, LTV 90% → max borrowable value $900.
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);

        // Borrow 800 EURC ($864) → LTV-HF = 900/864 = 1.04 ≥ 1, passes
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);
        assertEq(eurc.balanceOf(bob), 800e6);
    }

    function test_openPosition_revert_exceedsLTV() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);

        // Borrow 840 EURC ($907.2) → LTV-HF = 900/907.2 = 0.992 < 1 → revert
        // (Note: using LT 94% gives HF=940/907=1.036, which is “healthy” — confirming the gate is LTV, not LT)
        vm.prank(bob);
        vm.expectRevert();
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 840e6);
    }

    function test_openPosition_standard_ETH() public {
        _seedUsdc(10_000e6);
        _fund(weth, bob, 1e18);

        // ETH→USDC uses Standard mode (no FX pair): LTV 75%, LT 80%
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // Liquidation HF (LT 80%): 3000*0.8/2000 = 1.2
        uint256 hf = pool.getHealthFactor(bob, address(weth), address(usdc));
        assertEq(hf, 1.2e18, "standard liquidation HF");
    }

    function test_openPosition_standard_revert_exceedsLTV() public {
        _seedUsdc(10_000e6);
        _fund(weth, bob, 1e18);

        // Borrow 2300 USDC: LTV 75% → cap $2250 < $2300 → revert
        vm.prank(bob);
        vm.expectRevert();
        pool.openPosition(address(weth), 1e18, address(usdc), 2_300e6);
    }

    function test_openPosition_revert_sameAsset() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(SameAsset.selector);
        pool.openPosition(address(usdc), 1_000e6, address(usdc), 100e6);
    }

    // WETH is now borrowable; verify that borrowing fails without WETH liquidity in the pool.
    function test_openPosition_revert_insufficientLiquidity_weth() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(weth)));
        pool.openPosition(address(usdc), 1_000e6, address(weth), 1e15);
    }

    function test_openPosition_revert_borrowCapExceeded() public {
        // EURC borrowCap = 5_000_000e6; cap check happens before liquidity/HF checks, no setup needed
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorrowCapExceeded.selector, address(eurc)));
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 5_000_001e6);
    }

    function test_openPosition_revert_collateralCapExceeded() public {
        // WETH collateralCap = 2000e18
        _fund(weth, bob, 2_001e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, address(weth)));
        pool.openPosition(address(weth), 2_001e18, address(usdc), 1e6);
    }

    function test_openPosition_revert_insufficientLiquidity() public {
        _seedEurc(100e6); // only 100 EURC in the pool
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, address(eurc)));
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 200e6);
    }

    /*//////////////////////////////////////////////////////////////
                                borrow
    //////////////////////////////////////////////////////////////*/

    function test_borrow_addsDebt() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 300e6);

        vm.prank(bob);
        pool.borrow(address(usdc), address(eurc), 100e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(eurc));
        assertEq(pos.scaledDebt, 400e6, "debt increased");
        assertEq(eurc.balanceOf(bob), 400e6, "total borrowed 400");
    }

    function test_borrow_revert_positionNotFound() public {
        _seedEurc(10_000e6);
        vm.prank(bob);
        vm.expectRevert();
        pool.borrow(address(usdc), address(eurc), 100e6);
    }

    function test_borrow_revert_exceedsLTV() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);

        // Borrow 100 more → total 900 EURC ($972) far exceeds LTV cap of $900
        vm.prank(bob);
        vm.expectRevert();
        pool.borrow(address(usdc), address(eurc), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                             addCollateral
    //////////////////////////////////////////////////////////////*/

    function test_addCollateral_improvesHF() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 2_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);
        uint256 hfBefore = pool.getHealthFactor(bob, address(usdc), address(eurc));

        vm.prank(bob);
        pool.addCollateral(address(usdc), address(eurc), 1_000e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(eurc));
        assertEq(pos.collateralAmount, 2_000e6, "collateral increased");
        uint256 hfAfter = pool.getHealthFactor(bob, address(usdc), address(eurc));
        assertGt(hfAfter, hfBefore, "HF improved");
    }

    function test_addCollateral_revert_positionNotFound() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert();
        pool.addCollateral(address(usdc), address(eurc), 1_000e6);
    }

    function test_addCollateral_revert_capExceeded() public {
        _seedUsdc(10_000e6);
        _fund(weth, bob, 2_001e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 1_000e18, address(usdc), 1_000e6);

        // Add 1001 more → total 2001 > collateralCap of 2000
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, address(weth)));
        pool.addCollateral(address(weth), address(usdc), 1_001e18);
    }

    /*//////////////////////////////////////////////////////////////
                          withdrawCollateral
    //////////////////////////////////////////////////////////////*/

    function test_withdrawCollateral_ok_whenHealthy() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 2_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 2_000e6, address(eurc), 500e6);

        // Extra collateral can be partially withdrawn while still healthy
        vm.prank(bob);
        pool.withdrawCollateral(address(usdc), address(eurc), 800e6);

        DataTypes.Position memory pos = pool.getPosition(bob, address(usdc), address(eurc));
        assertEq(pos.collateralAmount, 1_200e6, "remaining collateral");
        assertEq(usdc.balanceOf(bob), 800e6, "collateral returned");
    }

    function test_withdrawCollateral_revert_exceedsLTV() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);

        // Withdraw 200 collateral → remaining 800 USDC, LTV cap $720 < debt $864 → revert
        vm.prank(bob);
        vm.expectRevert();
        pool.withdrawCollateral(address(usdc), address(eurc), 200e6);
    }

    function test_withdrawCollateral_revert_insufficientCollateral() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 100e6);

        vm.prank(bob);
        vm.expectRevert(InsufficientCollateral.selector);
        pool.withdrawCollateral(address(usdc), address(eurc), 1_000e6 + 1);
    }
}
