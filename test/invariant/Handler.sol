// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Invariant fuzz operation driver: random deposit/withdraw/borrow/repay/liquidate/price change/time warp.
/// @dev All calls are wrapped in try/catch — invalid inputs naturally revert without changing state, which does not count as an invariant violation.
contract Handler is Test {
    LendingPool public pool;
    MockPriceOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public eurc;
    MockERC20 public weth;

    address[3] public actors;
    address public immutable liquidator;

    constructor(
        LendingPool _pool,
        MockPriceOracle _oracle,
        MockERC20 _usdc,
        MockERC20 _eurc,
        MockERC20 _weth,
        address[3] memory _actors,
        address _liquidator
    ) {
        pool = _pool;
        oracle = _oracle;
        usdc = _usdc;
        eurc = _eurc;
        weth = _weth;
        actors = _actors;
        liquidator = _liquidator;

        // mint sufficient tokens and grant unlimited approval to all actors
        for (uint256 i = 0; i < actors.length; i++) {
            _fundAll(actors[i]);
        }
        _fundAll(_liquidator);
    }

    function _fundAll(address who) internal {
        usdc.mint(who, 1e12); // 1,000,000 USDC
        eurc.mint(who, 1e12);
        weth.mint(who, 10_000e18);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// @dev 4 (collateral, debt) pairs, consistent with the enumeration used in invariant re-computation.
    function _pair(uint256 s) internal view returns (address col, address debt) {
        uint256 i = s % 4;
        if (i == 0) return (address(weth), address(usdc));
        if (i == 1) return (address(weth), address(eurc));
        if (i == 2) return (address(usdc), address(eurc));
        return (address(eurc), address(usdc));
    }

    function _colBound(address col, uint256 amt) internal view returns (uint256) {
        if (col == address(weth)) return bound(amt, 1e15, 100e18);
        return bound(amt, 1e6, 100_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                              lending side
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 t = useUsdc ? usdc : eurc;
        amount = bound(amount, 1e6, 100_000e6);
        vm.prank(actor);
        try pool.deposit(address(t), amount) {} catch {}
    }

    function withdraw(uint256 actorSeed, bool useUsdc, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 t = useUsdc ? usdc : eurc;
        amount = bound(amount, 1, 200_000e6);
        vm.prank(actor);
        try pool.withdraw(address(t), amount) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              borrowing side
    //////////////////////////////////////////////////////////////*/

    function openPosition(uint256 actorSeed, uint256 pairSeed, uint256 colAmt, uint256 borrowAmt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        colAmt = _colBound(col, colAmt);
        borrowAmt = bound(borrowAmt, 1e6, 50_000e6);

        // T-8: snapshot before
        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.openPosition(col, colAmt, debt, borrowAmt) {
            // T-8: collateral in — both increase by same amount
            uint256 deltaBalance = MockERC20(col).balanceOf(address(pool)) - balBefore;
            uint256 deltaTotal = pool.getTotalCollateral(col) - totBefore;
            assertEq(deltaBalance, deltaTotal, "openPosition: delta balance == delta totalCollateral");
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 pairSeed, uint256 borrowAmt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        borrowAmt = bound(borrowAmt, 1e6, 50_000e6);
        vm.prank(actor);
        try pool.borrow(col, debt, borrowAmt) {} catch {}
    }

    function addCollateral(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _colBound(col, amt);

        // T-8: snapshot before
        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.addCollateral(col, debt, amt) {
            // T-8: Δbalance must equal ΔtotalCollateral (both increase by same amount)
            uint256 deltaBalance = MockERC20(col).balanceOf(address(pool)) - balBefore;
            uint256 deltaTotal = pool.getTotalCollateral(col) - totBefore;
            assertEq(deltaBalance, deltaTotal, "addCollateral: delta balance == delta totalCollateral");
        } catch {}
    }

    function withdrawCollateral(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _colBound(col, amt);

        // T-8: snapshot before
        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.withdrawCollateral(col, debt, amt) {
            // T-8: both decrease by same amount
            uint256 deltaBalance = balBefore - MockERC20(col).balanceOf(address(pool));
            uint256 deltaTotal = totBefore - pool.getTotalCollateral(col);
            assertEq(deltaBalance, deltaTotal, "withdrawCollateral: delta balance == delta totalCollateral");
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = bound(amt, 1e6, 60_000e6);
        vm.prank(actor);
        try pool.repay(actor, col, debt, amt) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                          liquidation / price / time
    //////////////////////////////////////////////////////////////*/

    function liquidate(uint256 targetSeed, uint256 pairSeed, uint256 amt) external {
        address target = _actor(targetSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = bound(amt, 1e6, 60_000e6);

        // T-8: snapshot collateral side before liquidation
        uint256 colBalBefore = MockERC20(col).balanceOf(address(pool));
        uint256 colTotBefore = pool.getTotalCollateral(col);

        vm.prank(liquidator);
        try pool.liquidate(target, col, debt, amt, 0) {
            // T-8: seized collateral leaves pool — both decrease by same amount
            uint256 deltaBalance = colBalBefore - MockERC20(col).balanceOf(address(pool));
            uint256 deltaTotal = colTotBefore - pool.getTotalCollateral(col);
            assertEq(deltaBalance, deltaTotal, "liquidate: delta balance == delta totalCollateral");
        } catch {}
    }

    function movePrice(uint256 feedSeed, uint256 price) external {
        uint256 i = feedSeed % 3;
        if (i == 0) {
            oracle.setPrice(address(usdc), bound(price, 0.85e8, 1.15e8));
        } else if (i == 1) {
            oracle.setPrice(address(eurc), bound(price, 0.8e8, 1.5e8));
        } else {
            oracle.setPrice(address(weth), bound(price, 500e8, 6000e8));
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
    }
}
