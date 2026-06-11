// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes, WAD} from "../../src/libraries/DataTypes.sol";
import {AgentTypes} from "../../src/libraries/AgentTypes.sol";

/// @notice Regression for A-2: previewPosition.openable must mirror EVERY gate the on-chain
///         openPosition enforces (LTV health, liquidity, borrowable, oracle pause on BOTH legs,
///         borrowCap, collateralCap). If preview reports openable=true on a request that would
///         revert, the agent acts on a lie and wastes gas. Each test sets up exactly one blocking
///         condition that the OLD openable formula ignored, then asserts both that openable is now
///         false AND that a real open with the same params reverts (parity).
contract PreviewOpenableGatesTest is BaseTest {
    address internal lender = makeAddr("po_lender");

    function setUp() public override {
        super.setUp();
        // Deep liquidity so the liquidity gate never accidentally masks the gate under test.
        _deposit(usdc, lender, 5_000_000e6);
        _deposit(weth, lender, 1000e18);
    }

    /// @dev A request that is healthy + liquid + within every cap -> openable, and a real open succeeds.
    function test_openable_true_whenAllGatesPass() public {
        AgentTypes.PreviewResult memory pre = pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);
        assertTrue(pre.openable, "all gates pass -> openable");

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6); // must not revert
    }

    /// @dev borrowCap exceeded: shrink USDC borrowCap below the requested borrow. OLD formula missed this.
    function test_openable_false_whenBorrowCapExceeded() public {
        _setBorrowCap(address(usdc), 10_000e6); // cap below the 15k request

        AgentTypes.PreviewResult memory pre = pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);
        assertFalse(pre.openable, "over borrowCap -> not openable");

        // Parity: a real open with identical params reverts.
        _fund(weth, bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(); // BorrowCapExceeded
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);
    }

    /// @dev collateralCap exceeded: shrink WETH collateralCap below the deposited collateral.
    function test_openable_false_whenCollateralCapExceeded() public {
        _setCollateralCap(address(weth), 5e18); // cap below the 10 ETH request

        AgentTypes.PreviewResult memory pre = pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);
        assertFalse(pre.openable, "over collateralCap -> not openable");

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(); // CollateralCapExceeded
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);
    }

    /// @dev Oracle paused on the debt leg blocks the real open; preview must reflect it.
    function test_openable_false_whenDebtOraclePaused() public {
        oracle.setPaused(address(usdc), true);

        AgentTypes.PreviewResult memory pre = pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);
        assertFalse(pre.openable, "debt oracle paused -> not openable");

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(); // OraclePaused
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);
    }

    /// @dev Oracle paused on the collateral leg likewise blocks the open.
    function test_openable_false_whenCollateralOraclePaused() public {
        oracle.setPaused(address(weth), true);

        AgentTypes.PreviewResult memory pre = pool.previewPosition(address(weth), 10e18, address(usdc), 15_000e6);
        assertFalse(pre.openable, "collateral oracle paused -> not openable");

        _fund(weth, bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(); // OraclePaused
        pool.openPosition(address(weth), 10e18, address(usdc), 15_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _setBorrowCap(address asset, uint128 cap) internal {
        DataTypes.AssetConfig memory cfg = pool.getAssetConfig(asset);
        cfg.borrowCap = cap;
        pool.configureAsset(asset, cfg);
    }

    function _setCollateralCap(address asset, uint128 cap) internal {
        DataTypes.AssetConfig memory cfg = pool.getAssetConfig(asset);
        cfg.collateralCap = cap;
        pool.configureAsset(asset, cfg);
    }
}
