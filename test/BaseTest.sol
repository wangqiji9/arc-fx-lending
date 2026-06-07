// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice 测试地基:部署 pool + oracle + USDC/EURC/ETH,配好资产与 USD↔EUR FX 对。
/// @dev 价格:USDC=$1、EURC=$1.08、ETH=$3000(全 1e8 base)。USDC/EURC 6 位,ETH 18 位。
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

        // USDC:可借可抵押,USD 货币
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

        // EURC:可借可抵押,EUR 货币
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

        // WETH:仅抵押,ETH 货币(Standard 模式)
        pool.configureAsset(
            address(weth),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: false,
                decimals: 18,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 750,
                reserveFactor: 1000,
                fxPremium: 0,
                currency: ETHC,
                oracle: address(ethFeed),
                borrowCap: 0,
                collateralCap: 2000e18,
                depositCap: 0
            })
        );

        // FX E-Mode:USD↔EUR,90/94/2.5
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

    /// @notice 给 who mint 代币并对 pool 授权满额。
    function _fund(MockERC20 token, address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(pool), type(uint256).max);
    }

    /// @notice who 存入 amount 的 asset(已资助 + 授权)。
    function _deposit(MockERC20 token, address who, uint256 amount) internal {
        _fund(token, who, amount);
        vm.prank(who);
        pool.deposit(address(token), amount);
    }
}
