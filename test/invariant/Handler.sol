// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice invariant fuzz 的操作驱动:随机 deposit/withdraw/借贷/还/清算/改价/推进时间。
/// @dev 所有调用 try/catch 包裹——非法输入自然 revert、状态不变,不算违反不变量。
contract Handler is Test {
    LendingPool public pool;
    PriceOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public eurc;
    MockERC20 public weth;
    MockAggregator public usdcFeed;
    MockAggregator public eurcFeed;
    MockAggregator public ethFeed;

    address[3] public actors;
    address public immutable liquidator;

    constructor(
        LendingPool _pool,
        PriceOracle _oracle,
        MockERC20 _usdc,
        MockERC20 _eurc,
        MockERC20 _weth,
        MockAggregator _usdcFeed,
        MockAggregator _eurcFeed,
        MockAggregator _ethFeed,
        address[3] memory _actors,
        address _liquidator
    ) {
        pool = _pool;
        oracle = _oracle;
        usdc = _usdc;
        eurc = _eurc;
        weth = _weth;
        usdcFeed = _usdcFeed;
        eurcFeed = _eurcFeed;
        ethFeed = _ethFeed;
        actors = _actors;
        liquidator = _liquidator;

        // 给所有参与者充分 mint + 授权
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

    /// @dev 4 个 (抵押,债务) 组合,与 invariant 重算枚举保持一致。
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
                              出借侧
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
                              借款侧
    //////////////////////////////////////////////////////////////*/

    function openPosition(uint256 actorSeed, uint256 pairSeed, uint256 colAmt, uint256 borrowAmt)
        external
    {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        colAmt = _colBound(col, colAmt);
        borrowAmt = bound(borrowAmt, 1e6, 50_000e6);
        vm.prank(actor);
        try pool.openPosition(col, colAmt, debt, borrowAmt) {} catch {}
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
        vm.prank(actor);
        try pool.addCollateral(col, debt, amt) {} catch {}
    }

    function withdrawCollateral(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _colBound(col, amt);
        vm.prank(actor);
        try pool.withdrawCollateral(col, debt, amt) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = bound(amt, 1e6, 60_000e6);
        vm.prank(actor);
        try pool.repay(actor, col, debt, amt) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                          清算 / 价格 / 时间
    //////////////////////////////////////////////////////////////*/

    function liquidate(uint256 targetSeed, uint256 pairSeed, uint256 amt) external {
        address target = _actor(targetSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = bound(amt, 1e6, 60_000e6);
        vm.prank(liquidator);
        try pool.liquidate(target, col, debt, amt) {} catch {}
    }

    function movePrice(uint256 feedSeed, uint256 price) external {
        uint256 i = feedSeed % 3;
        if (i == 0) {
            usdcFeed.setAnswer(int256(bound(price, 0.85e8, 1.15e8)));
        } else if (i == 1) {
            eurcFeed.setAnswer(int256(bound(price, 0.80e8, 1.50e8)));
        } else {
            ethFeed.setAnswer(int256(bound(price, 500e8, 6000e8)));
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
    }
}
