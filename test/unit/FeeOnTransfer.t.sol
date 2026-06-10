// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {MockFeeToken} from "../mocks/MockFeeToken.sol";
import {TransferAmountMismatch} from "../../src/libraries/DataTypes.sol";

/// @notice T-3: _pull fee-on-transfer rejection (TransferAmountMismatch).
/// @dev MockFeeToken deducts 1% on transfer; actual amount received < requested amount → _pull balance-difference check should revert.
contract FeeOnTransferTest is Test {
    LendingPool internal pool;
    MockPriceOracle internal oracle;
    MockFeeToken internal feeToken;

    address internal alice = makeAddr("alice");
    bytes32 internal constant USD = bytes32("USD");

    function setUp() public {
        oracle = new MockPriceOracle(address(this));
        pool = new LendingPool(address(this), address(oracle));
        pool.setInsuranceFund(makeAddr("insurer"));

        feeToken = new MockFeeToken(6);

        oracle.setPrice(address(feeToken), 1e8); // $1.00
        pool.configureAsset(
            address(feeToken),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: true,
                decimals: 6,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                reserveFactor: 1000,
                fxPremium: 0,
                currency: USD,
                oracle: address(oracle),
                borrowCap: 10_000_000e6,
                collateralCap: 10_000_000e6,
                depositCap: 0
            })
        );

        feeToken.mint(alice, 10_000e6);
        vm.prank(alice);
        feeToken.approve(address(pool), type(uint256).max);
    }

    /// @notice On deposit, _pull check: actual received 990 (1% deducted) < requested 1000 → TransferAmountMismatch.
    function test_pull_revert_feeOnTransferDeposit() public {
        vm.prank(alice);
        vm.expectRevert(TransferAmountMismatch.selector);
        pool.deposit(address(feeToken), 1_000e6);
    }

    /// @notice Verify the fee actually applies: mint has no fee, transfer deducts 1%.
    function test_feeToken_actualFee() public {
        address recipient = makeAddr("recipient");
        feeToken.mint(recipient, 1_000e6);
        assertEq(feeToken.balanceOf(recipient), 1_000e6, "mint: no fee");

        address recipient2 = makeAddr("recipient2");
        vm.prank(recipient);
        feeToken.transfer(recipient2, 1_000e6);
        assertEq(feeToken.balanceOf(recipient2), 990e6, "transfer: 1% fee deducted");
    }
}
