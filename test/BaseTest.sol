// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice Test foundation: deploys pool + oracle + USDC/EURC/ETH, configures assets and the USD↔EUR FX pair.
/// @dev Prices: USDC=$1, EURC=$1.08, ETH=$3000 (all 1e8 base). USDC/EURC 6 decimals, ETH 18 decimals.
abstract contract BaseTest is Test {
    LendingPool internal pool;
    PriceOracle internal oracle;

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal eurcFeed;
    MockAggregator internal ethFeed;

    bytes32 internal constant USD = bytes32("USD");
    bytes32 internal constant EUR = bytes32("EUR");
    bytes32 internal constant ETHC = bytes32("ETH"); // currency code for ETH

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");
    address internal insurer = makeAddr("insurer");

    function setUp() public virtual {
        oracle = new PriceOracle(address(this));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        usdcFeed = new MockAggregator(8, 1e8); // $1.00
        eurcFeed = new MockAggregator(8, 1.08e8); // $1.08
        ethFeed = new MockAggregator(8, 3000e8); // $3000

        oracle.setFeed(address(usdc), address(usdcFeed), 1 days);
        oracle.setFeed(address(eurc), address(eurcFeed), 1 days);
        oracle.setFeed(address(weth), address(ethFeed), 1 days);

        pool = new LendingPool(address(this), address(oracle));
        pool.setInsuranceFund(insurer);

        // USDC: borrowable and collateralizable, USD currency
        pool.configureAsset(
            address(usdc),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: true,
                decimals: 6,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                reserveFactor: 1000, // 10%
                fxPremium: 100, // 1%
                currency: USD,
                oracle: address(usdcFeed),
                borrowCap: 10_000_000e6,
                collateralCap: 10_000_000e6,
                depositCap: 0
            })
        );

        // EURC: borrowable and collateralizable, EUR currency
        pool.configureAsset(
            address(eurc),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: true,
                decimals: 6,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                reserveFactor: 1000,
                fxPremium: 200, // 2%
                currency: EUR,
                oracle: address(eurcFeed),
                borrowCap: 5_000_000e6,
                collateralCap: 5_000_000e6,
                depositCap: 0
            })
        );

        // WETH: collateralizable and borrowable, ETH currency (Standard mode)
        pool.configureAsset(
            address(weth),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: true,
                decimals: 18,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 750,
                reserveFactor: 1000,
                fxPremium: 0,
                currency: ETHC,
                oracle: address(ethFeed),
                borrowCap: 1000e18,
                collateralCap: 2000e18,
                depositCap: 0
            })
        );

        // FX E-Mode: USD↔EUR, LTV/LT/bonus = 90/94/2.5
        pool.configureFxCategory(
            USD,
            EUR,
            DataTypes.FxCategory({
                enabled: true,
                ltv: 9000,
                liquidationThreshold: 9400,
                liquidationBonus: 250
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints tokens to `who` and grants unlimited approval to the pool.
    function _fund(MockERC20 token, address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(pool), type(uint256).max);
    }

    /// @notice Funds `who` with `amount` of `asset` (minted + approved) and then deposits into the pool.
    function _deposit(MockERC20 token, address who, uint256 amount) internal {
        _fund(token, who, amount);
        vm.prank(who);
        pool.deposit(address(token), amount);
    }
}
