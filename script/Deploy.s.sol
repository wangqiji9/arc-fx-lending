// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Full local-Anvil deployment script.
/// @dev Run with:
///   anvil &
///   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast -vvvv
///
/// Deploys:
///   - MockPriceOracle (deployer is owner + guardian) — settable 1e8 prices for local demos
///   - MockERC20: USDC(6)/EURC(6)/WETH(18)
///   - Initial prices: USDC=$1.00 / EURC=$1.08 / WETH=$3000
///   - LendingPool (deployer is owner + insuranceFund)
///   - Asset config + FX E-Mode USD<->EUR
///   - Initial liquidity: deployer mints and deposits into the pool
///
/// @dev For a real Arc testnet deployment, swap MockPriceOracle for PythPriceOracle
///      (constructor takes the Pyth contract 0x2880aB155794e7179c9eE2e38200202908C17B43)
///      and configure feeds with the Pyth price ids instead of setPrice.
contract Deploy is Script {
    bytes32 internal constant USD = bytes32("USD");
    bytes32 internal constant EUR = bytes32("EUR");
    bytes32 internal constant ETHC = bytes32("ETH");

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // ── 1. Oracle ──────────────────────────────────────────────
        MockPriceOracle oracle = new MockPriceOracle(deployer);
        oracle.setGuardian(deployer);

        // ── 2. Mock tokens ────────────────────────────────────────
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 eurc = new MockERC20("Euro Coin", "EURC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // ── 3. Prices (1e8 USD base) ──────────────────────────────
        oracle.setPrice(address(usdc), 1.00e8);
        oracle.setPrice(address(eurc), 1.08e8);
        oracle.setPrice(address(weth), 3000e8);

        // ── 4. LendingPool ────────────────────────────────────────
        LendingPool pool = new LendingPool(deployer, address(oracle));
        pool.setInsuranceFund(deployer);

        // ── 5. Asset config ───────────────────────────────────────
        pool.configureAsset(
            address(usdc),
            DataTypes.AssetConfig({
                configured:            true,
                borrowable:            true,
                decimals:              6,
                ltv:                   7500,
                liquidationThreshold:  8000,
                liquidationBonus:      500,
                reserveFactor:         1000,
                fxPremium:             100,
                currency:              USD,
                oracle:                address(oracle),
                borrowCap:             10_000_000e6,
                collateralCap:         10_000_000e6,
                depositCap:            0
            })
        );

        pool.configureAsset(
            address(eurc),
            DataTypes.AssetConfig({
                configured:            true,
                borrowable:            true,
                decimals:              6,
                ltv:                   7500,
                liquidationThreshold:  8000,
                liquidationBonus:      500,
                reserveFactor:         1000,
                fxPremium:             200,
                currency:              EUR,
                oracle:                address(oracle),
                borrowCap:             5_000_000e6,
                collateralCap:         5_000_000e6,
                depositCap:            0
            })
        );

        pool.configureAsset(
            address(weth),
            DataTypes.AssetConfig({
                configured:            true,
                borrowable:            true,
                decimals:              18,
                ltv:                   7500,
                liquidationThreshold:  8000,
                liquidationBonus:      750,
                reserveFactor:         1000,
                fxPremium:             0,
                currency:              ETHC,
                oracle:                address(oracle),
                borrowCap:             1000e18,
                collateralCap:         2000e18,
                depositCap:            0
            })
        );

        // ── 6. FX E-Mode USD<->EUR ────────────────────────────────
        pool.configureFxCategory(
            USD,
            EUR,
            DataTypes.FxCategory({
                enabled:               true,
                ltv:                   9000,
                liquidationThreshold:  9400,
                liquidationBonus:      250
            })
        );

        // ── 7. Initial liquidity ──────────────────────────────────
        uint256 usdcSeed = 1_000_000e6;   // 1,000,000 USDC
        uint256 eurcSeed = 500_000e6;     // 500,000 EURC
        uint256 wethSeed = 100e18;        // 100 WETH

        usdc.mint(deployer, usdcSeed);
        eurc.mint(deployer, eurcSeed);
        weth.mint(deployer, wethSeed);

        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);

        pool.deposit(address(usdc), usdcSeed);
        pool.deposit(address(eurc), eurcSeed);
        pool.deposit(address(weth), wethSeed);

        vm.stopBroadcast();

        // ── Output ────────────────────────────────────────────────
        console.log("=== arc-fx-lending deployed on Anvil ===");
        console.log("MockPriceOracle:", address(oracle));
        console.log("LendingPool  :", address(pool));
        console.log("USDC         :", address(usdc));
        console.log("EURC         :", address(eurc));
        console.log("WETH         :", address(weth));
        console.log("Deployer     :", deployer);
        console.log("--- initial liquidity deposited ---");
        console.log("USDC:", usdcSeed / 1e6, "e6 units");
        console.log("EURC:", eurcSeed / 1e6, "e6 units");
        console.log("WETH:", wethSeed / 1e18, "ether");
    }
}
