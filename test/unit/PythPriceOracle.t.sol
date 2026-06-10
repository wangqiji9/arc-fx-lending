// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PythPriceOracle} from "../../src/oracles/PythPriceOracle.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {StalePrice, InvalidPrice, FeedNotSet, NotAuthorized, ZeroAddress} from "../../src/libraries/DataTypes.sol";

/// @notice PythPriceOracle unit tests — exponent normalization / staleness / InvalidPrice / guardian authorization.
/// @dev Real Pyth feed ids (chain-agnostic). ETH/USD carries expo=-8 on Arc, confirmed on-chain.
contract PythPriceOracleTest is Test {
    PythPriceOracle internal oracle;
    MockPyth internal pyth;

    address internal asset = makeAddr("asset");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");

    // ETH/USD price id (same value across all chains)
    bytes32 internal constant ETH_USD =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function setUp() public {
        pyth = new MockPyth();
        oracle = new PythPriceOracle(address(this), address(pyth));
        oracle.setGuardian(guardian);
    }

    /*//////////////////////////////////////////////////////////////
                              constructor
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revert_zeroPyth() public {
        vm.expectRevert(ZeroAddress.selector);
        new PythPriceOracle(address(this), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                       exponent normalization to 1e8
    //////////////////////////////////////////////////////////////*/

    /// @notice expo == -8 is the typical USD crypto feed → raw value already equals 1e8 base (passthrough).
    function test_getPrice_expoMinus8_passthrough() public {
        pyth.setPrice(ETH_USD, 169131500000, 0, -8, block.timestamp); // $1691.315
        oracle.setFeed(asset, ETH_USD, 1 hours);
        assertEq(oracle.getPrice(asset), 169131500000, "expo -8 passthrough");
    }

    /// @notice expo < -8 (higher precision) → divide down to 1e8 base.
    function test_getPrice_expoMinus10_dividesDown() public {
        // real = 1691.315; at expo -10 raw = 16913150000000; to 1e8 base = 169131500000
        pyth.setPrice(ETH_USD, 16913150000000, 0, -10, block.timestamp);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        assertEq(oracle.getPrice(asset), 169131500000, "expo -10 normalized to 1e8");
    }

    /// @notice expo > -8 (lower precision) → multiply up to 1e8 base.
    function test_getPrice_expoMinus6_multipliesUp() public {
        // real = 1691.315; at expo -6 raw = 1691315000; to 1e8 base = 169131500000
        pyth.setPrice(ETH_USD, 1691315000, 0, -6, block.timestamp);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        assertEq(oracle.getPrice(asset), 169131500000, "expo -6 normalized to 1e8");
    }

    /*//////////////////////////////////////////////////////////////
                              staleness
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revert_stalePrice() public {
        pyth.setPriceE8(ETH_USD, 1691e8);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        vm.warp(block.timestamp + 1 hours + 1); // exceeds maxAge
        vm.expectRevert(abi.encodeWithSelector(StalePrice.selector, address(pyth)));
        oracle.getPrice(asset);
    }

    function test_getPrice_passes_atMaxAgeBoundary() public {
        pyth.setPriceE8(ETH_USD, 1691e8);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        vm.warp(block.timestamp + 1 hours); // exactly at maxAge (≤ maxAge, no revert)
        assertEq(oracle.getPrice(asset), 1691e8, "price at maxAge boundary");
    }

    /// @notice publishTime slightly ahead of block.timestamp must not underflow/revert.
    function test_getPrice_futurePublishTime_noRevert() public {
        oracle.setFeed(asset, ETH_USD, 1 hours);
        pyth.setPrice(ETH_USD, 1691e8, 0, -8, block.timestamp + 5);
        assertEq(oracle.getPrice(asset), 1691e8, "future publishTime treated as fresh");
    }

    /*//////////////////////////////////////////////////////////////
                           InvalidPrice(price <= 0)
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_revert_zeroPrice() public {
        pyth.setPrice(ETH_USD, 0, 0, -8, block.timestamp);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, asset));
        oracle.getPrice(asset);
    }

    function test_getPrice_revert_negativePrice() public {
        pyth.setPrice(ETH_USD, -1, 0, -8, block.timestamp);
        oracle.setFeed(asset, ETH_USD, 1 hours);
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

    function test_setFeed_revert_zeroPriceId() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, asset));
        oracle.setFeed(asset, bytes32(0), 1 hours);
    }

    function test_setFeed_revert_zeroMaxAge() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, asset));
        oracle.setFeed(asset, ETH_USD, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       guardian authorization (shared base)
    //////////////////////////////////////////////////////////////*/

    function test_setPaused_guardian_canPause() public {
        oracle.setFeed(asset, ETH_USD, 1 hours);
        vm.prank(guardian);
        oracle.setPaused(asset, true);
        assertTrue(oracle.isPaused(asset), "guardian can pause");
    }

    function test_setPaused_attacker_revert() public {
        vm.prank(attacker);
        vm.expectRevert(NotAuthorized.selector);
        oracle.setPaused(asset, true);
    }

    function test_setFeed_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(); // OZ Ownable error
        oracle.setFeed(asset, ETH_USD, 1 hours);
    }

    /// @notice getPrice ignores the paused flag (repay/liquidate still need prices during a pause).
    function test_getPrice_notBlockedByPausedFlag() public {
        pyth.setPriceE8(ETH_USD, 1691e8);
        oracle.setFeed(asset, ETH_USD, 1 hours);
        oracle.setPaused(asset, true);
        assertEq(oracle.getPrice(asset), 1691e8, "getPrice ignores paused flag");
    }
}
