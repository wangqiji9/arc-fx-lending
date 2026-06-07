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

        // 清算 HF(LT 94%):1000*0.94 / (500*1.08) = 940/540 = 1.7407
        uint256 hf = pool.getHealthFactor(bob, address(usdc), address(eurc));
        assertApproxEqAbs(hf, 1.7407e18, 1e15, "liquidation HF");
    }

    function test_openPosition_FX_gatedByLTV_not_LT() public {
        // 抵押 1000 USDC,LTV 90% → 可借价值上限 $900。
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);

        // 借 800 EURC($864) → LTV-HF = 900/864 = 1.04 ≥ 1,通过
        vm.prank(bob);
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 800e6);
        assertEq(eurc.balanceOf(bob), 800e6);
    }

    function test_openPosition_revert_exceedsLTV() public {
        _seedEurc(10_000e6);
        _fund(usdc, bob, 1_000e6);

        // 借 840 EURC($907.2) → LTV-HF = 900/907.2 = 0.992 < 1 → revert
        // (注意:用 LT 94% 算 HF=940/907=1.036 是“健康”的,证明门控确实是 LTV 而非 LT)
        vm.prank(bob);
        vm.expectRevert();
        pool.openPosition(address(usdc), 1_000e6, address(eurc), 840e6);
    }

    function test_openPosition_standard_ETH() public {
        _seedUsdc(10_000e6);
        _fund(weth, bob, 1e18);

        // ETH→USDC 走 Standard(无 FX 对):LTV 75%,LT 80%
        vm.prank(bob);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);

        // 清算 HF(LT 80%):3000*0.8/2000 = 1.2
        uint256 hf = pool.getHealthFactor(bob, address(weth), address(usdc));
        assertEq(hf, 1.2e18, "standard liquidation HF");
    }

    function test_openPosition_standard_revert_exceedsLTV() public {
        _seedUsdc(10_000e6);
        _fund(weth, bob, 1e18);

        // 借 2300 USDC:LTV 75% → 上限 $2250 < $2300 → revert
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

    function test_openPosition_revert_notBorrowable() public {
        _fund(usdc, bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AssetNotBorrowable.selector, address(weth)));
        pool.openPosition(address(usdc), 1_000e6, address(weth), 1e15);
    }

    function test_openPosition_revert_borrowCapExceeded() public {
        // EURC borrowCap = 5_000_000e6;cap 检查在流动性/HF 之前,无需准备这些
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
        _seedEurc(100e6); // 池里只有 100 EURC
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

        // 再借 100 → 总 900 EURC($972) 远超 LTV 上限 $900
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

        // 再加 1001 → 2001 > 2000 cap
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

        // 多存的抵押可取一部分仍健康
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

        // 取走 200 抵押 → 剩 800 USDC,LTV 上限 $720 < 债务 $864 → revert
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
