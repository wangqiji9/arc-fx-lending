// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {StalePrice, InvalidPrice, FeedNotSet, NotAuthorized} from "../../src/libraries/DataTypes.sol";

/// @notice T-4: PriceOracle unit tests — staleness / InvalidPrice / decimal normalization / guardian authorization.
contract PriceOracleTest is Test {
    PriceOracle internal oracle;
    MockAggregator internal feed8;  // 8-decimal feed (standard)
    MockAggregator internal feed6;  // 6-decimal feed (low precision)
    MockAggregator internal feed18; // 18-decimal feed (high precision)

    address internal asset = makeAddr("asset");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        oracle = new PriceOracle(address(this));
        oracle.setGuardian(guardian);

        feed8  = new MockAggregator(8, 1e8);    // $1.00, 8 decimals
        feed6  = new MockAggregator(6, 1e6);    // $1.00 in 6 decimals
        feed18 = new MockAggregator(18, 1e18);  // $1.00 in 18 decimals
    }

    /*//////////////////////////////////////////////////////////////
                              staleness
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revert_stalePrice() public {
        oracle.setFeed(asset, address(feed8), 1 hours);
        vm.warp(block.timestamp + 1 hours + 1); // exceeds heartbeat
        vm.expectRevert(abi.encodeWithSelector(StalePrice.selector, address(feed8)));
        oracle.getPrice(asset);
    }

    function test_getPrice_passes_atHeartbeatBoundary() public {
        oracle.setFeed(asset, address(feed8), 1 hours);
        vm.warp(block.timestamp + 1 hours); // exactly at heartbeat (≤ heartbeat, no revert)
        uint256 price = oracle.getPrice(asset);
        assertEq(price, 1e8, "price at heartbeat boundary");
    }

    /*//////////////////////////////////////////////////////////////
                           InvalidPrice(answer <= 0)
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revert_zeroPriceAnswer() public {
        feed8.setAnswer(0);
        oracle.setFeed(asset, address(feed8), 1 days);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, asset));
        oracle.getPrice(asset);
    }

    function test_getPrice_revert_negativePriceAnswer() public {
        feed8.setAnswer(-1);
        oracle.setFeed(asset, address(feed8), 1 days);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, asset));
        oracle.getPrice(asset);
    }

    /*//////////////////////////////////////////////////////////////
                           FeedNotSet
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revert_feedNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(FeedNotSet.selector, asset));
        oracle.getPrice(asset);
    }

    /*//////////////////////////////////////////////////////////////
                       decimal normalization to 1e8
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_normalizes_6decimals_to_8() public {
        // feed reports 1e6 (6-decimal precision), normalized result should be 1e8
        oracle.setFeed(asset, address(feed6), 1 days);
        uint256 price = oracle.getPrice(asset);
        assertEq(price, 1e8, "6-decimal feed normalized to 1e8");
    }

    function test_getPrice_normalizes_18decimals_to_8() public {
        // feed reports 1e18 (18-decimal precision), normalized result should be 1e8
        oracle.setFeed(asset, address(feed18), 1 days);
        uint256 price = oracle.getPrice(asset);
        assertEq(price, 1e8, "18-decimal feed normalized to 1e8");
    }

    function test_getPrice_8decimals_passthrough() public {
        feed8.setAnswer(3000e8); // ETH $3000
        oracle.setFeed(asset, address(feed8), 1 days);
        assertEq(oracle.getPrice(asset), 3000e8, "8-decimal feed passes through");
    }

    /*//////////////////////////////////////////////////////////////
                           guardian authorization
    //////////////////////////////////////////////////////////////*/

    function test_setPaused_guardian_canPause() public {
        oracle.setFeed(asset, address(feed8), 1 days);
        assertFalse(oracle.isPaused(asset), "initially not paused");

        vm.prank(guardian);
        oracle.setPaused(asset, true);

        assertTrue(oracle.isPaused(asset), "guardian can pause");
    }

    function test_setPaused_owner_canPause() public {
        oracle.setFeed(asset, address(feed8), 1 days);
        oracle.setPaused(asset, true); // owner (address(this))
        assertTrue(oracle.isPaused(asset), "owner can pause");
    }

    function test_setPaused_attacker_revert() public {
        oracle.setFeed(asset, address(feed8), 1 days);
        vm.prank(attacker);
        vm.expectRevert(NotAuthorized.selector);
        oracle.setPaused(asset, true);
    }

    function test_setFeed_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(); // OZ Ownable error
        oracle.setFeed(asset, address(feed8), 1 days);
    }

    /// @notice isPaused is just a flag: getPrice itself does not read paused → a paused asset can still be priced (LendingPool layer intercepts it).
    function test_getPrice_notBlockedByPausedFlag() public {
        oracle.setFeed(asset, address(feed8), 1 days);
        oracle.setPaused(asset, true);
        uint256 price = oracle.getPrice(asset); // does not revert
        assertEq(price, 1e8, "getPrice ignores paused flag");
    }
}
