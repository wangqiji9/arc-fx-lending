// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Arc Testnet deployment script — all three tokens are MockERC20.
/// @dev Prerequisites:
///      1. Deployer funded with Arc testnet USDC (only for gas, ~0.5 USDC is enough).
///         Faucet: https://faucet.testnet.arc.network
///      2. Set env: PRIVATE_KEY=0x<deployer-pk>  (see deploy-keys/.env.deploy)
///
/// Run:
///   source deploy-keys/.env.deploy && \
///   forge script script/DeployArc.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vvvv
///
/// Why all MockERC20?
///   Arc native USDC is the gas token — 20 USDC from faucet covers ~50 txs of gas.
///   Using real USDC inside the protocol would eat into that gas budget.
///   MockERC20 allows unlimited minting so protocol interactions are free of constraints.
contract DeployArc is Script {
    bytes32 internal constant USD  = bytes32("USD");
    bytes32 internal constant EUR  = bytes32("EUR");
    bytes32 internal constant ETHC = bytes32("ETH");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Deploying arc-fx-lending on Arc Testnet ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // ── 1. Oracle ──────────────────────────────────────────────
        MockPriceOracle oracle = new MockPriceOracle(deployer);
        oracle.setGuardian(deployer);

        // ── 2. Mock tokens (all three mintable) ───────────────────
        MockERC20 usdc = new MockERC20("USD Coin (Test)",    "USDC", 6);
        MockERC20 eurc = new MockERC20("Euro Coin (Test)",   "EURC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether (Test)","WETH", 18);

        // ── 3. Prices ─────────────────────────────────────────────
        oracle.setPrice(address(usdc), 1_00000000);       // $1.00
        oracle.setPrice(address(eurc), 1_08000000);       // $1.08
        oracle.setPrice(address(weth), 3000_00000000);    // $3,000

        // ── 4. LendingPool ────────────────────────────────────────
        LendingPool pool = new LendingPool(deployer, address(oracle));
        pool.setInsuranceFund(deployer);

        // ── 5. Asset config ───────────────────────────────────────
        pool.configureAsset(
            address(usdc),
            DataTypes.AssetConfig({
                configured: true,
                borrowable: true,
                decimals: 6,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                reserveFactor: 1000,
                fxPremium: 100,
                currency: USD,
                oracle: address(oracle),
                borrowCap: 10_000_000e6,
                collateralCap: 10_000_000e6,
                depositCap: 0
            })
        );

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
                fxPremium: 200,
                currency: EUR,
                oracle: address(oracle),
                borrowCap: 5_000_000e6,
                collateralCap: 5_000_000e6,
                depositCap: 0
            })
        );

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
                oracle: address(oracle),
                borrowCap: 1000e18,
                collateralCap: 2000e18,
                depositCap: 0
            })
        );

        // ── 6. FX E-Mode USD<->EUR ────────────────────────────────
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

        // ── 7. Seed initial liquidity (all minted, no faucet USDC needed) ──
        uint256 usdcSeed = 1_000_000e6;  // 1,000,000 USDC
        uint256 eurcSeed =   500_000e6;  //   500,000 EURC
        uint256 wethSeed =       100e18; //       100 WETH

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
        console.log("\n=== Deployment complete ===");
        console.log("MockPriceOracle :", address(oracle));
        console.log("LendingPool     :", address(pool));
        console.log("USDC (mock)     :", address(usdc));
        console.log("EURC (mock)     :", address(eurc));
        console.log("WETH (mock)     :", address(weth));
        console.log("");
        console.log(">>> Copy into frontend/.env.local:");
        console.log("NEXT_PUBLIC_LENDING_POOL_ADDRESS=", address(pool));
        console.log("NEXT_PUBLIC_USDC_ADDRESS=", address(usdc));
        console.log("NEXT_PUBLIC_EURC_ADDRESS=", address(eurc));
        console.log("NEXT_PUBLIC_WETH_ADDRESS=", address(weth));
        console.log("");
        console.log(">>> Copy into deploy-keys/.env.deploy:");
        console.log("LENDING_POOL_ADDRESS=", address(pool));
        console.log("MOCK_USDC_ADDRESS=", address(usdc));
        console.log("MOCK_EURC_ADDRESS=", address(eurc));
        console.log("MOCK_WETH_ADDRESS=", address(weth));
        console.log("MOCK_ORACLE_ADDRESS=", address(oracle));
    }
}
