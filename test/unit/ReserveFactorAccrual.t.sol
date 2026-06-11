// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @notice Regression test (A-1): configureAsset MUST accrue at the OLD reserveFactor before
///         overwriting config. updateIndexes() applies reserveFactor over the whole dt since
///         lastUpdateTimestamp, so without a pre-accrue the new reserveFactor would be applied
///         retroactively to interest already earned under the old one. The fix calls _accrue()
///         inside configureAsset before the overwrite, so flipping rf at year-end leaves the
///         already-earned year of interest untouched (flipped index == baseline index).
contract ReserveFactorAccrualTest is BaseTest {
    address internal lender = makeAddr("rf_lender");
    address internal poker = makeAddr("rf_poker");
    uint256 internal constant RAY = 1e27;

    function setUp() public override {
        super.setUp();
        _deposit(usdc, lender, 10_000e6);
        _fund(weth, bob, 100e18);
        _fund(usdc, poker, 1_000e6); // spare USDC to poke accrual
    }

    /// @dev Run 1 year at util=0.8 (rate 5%), optionally flipping reserveFactor 10%->0% at the END
    ///      of the year via configureAsset. Returns liquidityIndex after poking accrual.
    function _runYear(bool flipRfToZero) internal returns (uint256) {
        vm.prank(bob);
        pool.openPosition(address(weth), 10e18, address(usdc), 8_000e6); // util 0.8, rate 5%

        vm.warp(block.timestamp + 365 days);

        if (flipRfToZero) {
            DataTypes.AssetConfig memory cfg = pool.getAssetConfig(address(usdc));
            assertEq(cfg.reserveFactor, 1000, "precondition rf=10%");
            cfg.reserveFactor = 0;
            // After the A-1 fix this accrues the past year at the OLD 10% rf BEFORE applying rf=0.
            pool.configureAsset(address(usdc), cfg);
        }

        vm.prank(poker);
        pool.deposit(address(usdc), 1); // triggers _accrue over any remaining interval (here ~0)
        return pool.getReserveData(address(usdc)).liquidityIndex;
    }

    /// @dev Baseline: rf=10% for the whole year. supplyRate = 5% * 0.8 * 0.9 = 3.6% -> index ~ 1.036 RAY.
    function test_reserveFactor_baseline() public {
        uint256 idx = _runYear(false);
        emit log_named_uint("baseline liquidityIndex (rf=10% whole year)", idx);
        assertApproxEqRel(idx, 1.036e27, 0.001e18, "baseline ~3.6%");
    }

    /// @dev FIXED: flipping rf 10%->0% at year-end no longer rewrites the past year's interest.
    ///      configureAsset accrues at the old 10% first, so the year settles at 3.6% (== baseline),
    ///      NOT the retroactive 4.0% (1.040e27) the bug produced.
    function test_reserveFactor_notAppliedRetroactively_afterFix() public {
        uint256 baseline = _runYear(false);

        // Fresh run with the year-end flip; must match the baseline exactly (interest already settled
        // at the old rf before the new rf takes effect going forward).
        setUp();
        uint256 flipped = _runYear(true);

        emit log_named_uint("flipped liquidityIndex (rf 10->0 at year end, fixed)", flipped);
        assertApproxEqRel(flipped, 1.036e27, 0.001e18, "settled at old 3.6%, not retroactive 4.0%");
        assertEq(flipped, baseline, "flipped == baseline: past interest untouched by the rf change");
        assertLt(flipped, 1.038e27, "strictly below the buggy retroactive 4.0% index");
    }
}
