// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Simulate realistic protocol activity on Arc Testnet after DeployArc.s.sol.
/// @dev Prerequisites:
///      1. Run DeployArc.s.sol first, fill deploy-keys/.env.deploy with output addresses.
///      2. Alice/Bob/Charlie need Arc testnet USDC for gas (a few cents each is enough).
///         Deployer sends them small amounts from faucet balance — see _step1_distributeTokens.
///      3. Set env vars (see deploy-keys/.env.deploy):
///           PRIVATE_KEY=0x<deployer>
///           PK_ALICE=0x<alice>
///           PK_BOB=0x<bob>
///           PK_CHARLIE=0x<charlie>
///           LENDING_POOL_ADDRESS=0x...
///           MOCK_USDC_ADDRESS=0x...
///           MOCK_EURC_ADDRESS=0x...
///           MOCK_WETH_ADDRESS=0x...
///           MOCK_ORACLE_ADDRESS=0x...
///
/// Run:
///   forge script script/SeedArc.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vv
///
/// Scenarios:
///   A. Normal ops: supply, open Standard + FX positions, repay
///   B. Price crash → liquidation (Standard)
///   C. FX position liquidation (EURC appreciates)
contract SeedArc is Script {
    LendingPool pool;
    MockPriceOracle oracle;
    MockERC20 usdc;
    MockERC20 eurc;
    MockERC20 weth;

    uint256 pkDeployer;
    uint256 pkAlice;
    uint256 pkBob;
    uint256 pkCharlie;

    address deployer;
    address alice;
    address bob;
    address charlie;

    function run() external {
        pkDeployer = vm.envUint("PRIVATE_KEY");
        pkAlice    = vm.envUint("PK_ALICE");
        pkBob      = vm.envUint("PK_BOB");
        pkCharlie  = vm.envUint("PK_CHARLIE");

        deployer = vm.addr(pkDeployer);
        alice    = vm.addr(pkAlice);
        bob      = vm.addr(pkBob);
        charlie  = vm.addr(pkCharlie);

        pool   = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        oracle = MockPriceOracle(vm.envAddress("MOCK_ORACLE_ADDRESS"));
        usdc   = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc   = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth   = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== arc-fx-lending seed activity on Arc Testnet ===");
        console.log("Pool    :", address(pool));
        console.log("Alice   :", alice);
        console.log("Bob     :", bob);
        console.log("Charlie :", charlie);

        _step1_distributeTokens();
        _step2_normalOps();
        _step3_standardLiquidation();
        _step4_fxLiquidation();

        console.log("[ALL DONE]");
    }

    // ─────────────────────────────────────────────────────────────
    // Step 1: Deployer distributes mock tokens to all actors
    // ─────────────────────────────────────────────────────────────

    function _step1_distributeTokens() internal {
        console.log("--- Step 1: distribute tokens ---");

        vm.startBroadcast(pkDeployer);

        // All tokens are MockERC20 — mint freely, no faucet dependency
        usdc.mint(deployer, 50_000e6);  //  50,000 USDC for deployer liquidations
        usdc.mint(alice,   100_000e6);  // 100,000 USDC
        usdc.mint(bob,     100_000e6);
        usdc.mint(charlie,  50_000e6);

        eurc.mint(deployer, 20_000e6);  //  20,000 EURC for deployer liquidations
        eurc.mint(alice,   50_000e6);   //  50,000 EURC
        eurc.mint(bob,     50_000e6);
        eurc.mint(charlie, 10_000e6);

        weth.mint(alice,   10e18);      //     10 WETH
        weth.mint(bob,      6e18);      //      6 WETH (5 collateral + 1 for addCollateral)
        weth.mint(charlie, 20e18);

        // Pre-approve pool for deployer (used in liquidation steps)
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);

        vm.stopBroadcast();
        console.log("[1] tokens distributed to alice, bob, charlie and deployer");
    }

    // ─────────────────────────────────────────────────────────────
    // Step 2: Normal operations — supply + open positions
    // ─────────────────────────────────────────────────────────────

    function _step2_normalOps() internal {
        console.log("--- Step 2: normal ops ---");

        // Alice: supply 10 WETH, open FX E-Mode EURC/USDC position
        vm.startBroadcast(pkAlice);
        weth.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        pool.deposit(address(weth), 10e18);
        // Alice opens EURC col → borrow USDC (FX E-Mode: LTV 90%)
        // 10,000 EURC @ $1.08 = $10,800 col; max borrow = $10,800 * 0.90 = $9,720 USDC
        pool.openPosition(address(eurc), 10_000e6, address(usdc), 9_000e6);
        vm.stopBroadcast();
        _logHF(alice, address(eurc), address(usdc), "2-alice-EURC/USDC-FX");
        console.log("[2a] alice: deposited 10 WETH, opened EURC/USDC FX position");

        // Bob: supply 30,000 EURC, open WETH/USDC Standard position
        vm.startBroadcast(pkBob);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        pool.deposit(address(eurc), 30_000e6);
        // Bob: 5 WETH col @ $3000 = $15,000; borrow 10,000 USDC (LTV 75%, max $11,250)
        pool.openPosition(address(weth), 5e18, address(usdc), 10_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(weth), address(usdc), "2-bob-WETH/USDC-Standard");
        console.log("[2b] bob: deposited 30,000 EURC, opened WETH/USDC position");

        // Charlie: supply 20 WETH, open USDC/EURC FX position
        vm.startBroadcast(pkCharlie);
        weth.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        pool.deposit(address(weth), 15e18);
        // Charlie: 10,000 USDC col → borrow 8,000 EURC / $1.08 ≈ 7,407 (LTV 90% → max 8,333 EURC)
        pool.openPosition(address(usdc), 10_000e6, address(eurc), 8_000e6);
        vm.stopBroadcast();
        _logHF(charlie, address(usdc), address(eurc), "2-charlie-USDC/EURC-FX");
        console.log("[2c] charlie: deposited 15 WETH, opened USDC/EURC FX position");

        // Bob: add more collateral + partial repay to show those actions
        vm.startBroadcast(pkBob);
        pool.addCollateral(address(weth), address(usdc), 1e18);
        pool.repay(bob, address(weth), address(usdc), 1_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(weth), address(usdc), "2-bob-after-addCol+repay");
        console.log("[2d] bob: added 1 WETH collateral, repaid 1,000 USDC");

        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    // ─────────────────────────────────────────────────────────────
    // Step 3: ETH crash → liquidate Bob's Standard position
    // ─────────────────────────────────────────────────────────────

    function _step3_standardLiquidation() internal {
        console.log("--- Step 3: ETH crash -> liquidate bob ---");

        // ETH $3000 -> $1700: bob HF = 6*1700*0.80 / 9000 = 8160/9000 = 0.907 -> liquidatable
        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(weth), 1700e8);
        vm.stopBroadcast();
        console.log("[3a] WETH -> $1,700");
        _logHF(bob, address(weth), address(usdc), "3-bob-after-crash");

        // Deployer liquidates bob (USDC balance + approval set in step 1)
        vm.startBroadcast(pkDeployer);
        pool.liquidate(bob, address(weth), address(usdc), 9_000e6, 0);
        vm.stopBroadcast();
        console.log("[3b] deployer liquidated bob");
        _logHF(bob, address(weth), address(usdc), "3-bob-post-liquidation");

        // Restore price
        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(weth), 3000e8);
        vm.stopBroadcast();
        console.log("[3c] WETH restored $3,000");
    }

    // ─────────────────────────────────────────────────────────────
    // Step 4: EURC appreciates → liquidate Alice's FX position
    // ─────────────────────────────────────────────────────────────

    function _step4_fxLiquidation() internal {
        console.log("--- Step 4: EURC appreciates -> liquidate alice FX ---");

        // Alice: 10,000 EURC col @ $1.08 → borrow 9,000 USDC
        // FX LT = 94%; HF = 10000*1.08*0.94 / 9000 = 10152/9000 = 1.128 (healthy at $1.08)
        // Push EURC to $1.35: HF = 10000*1.35*0.94 / 9000 = 12690/9000 = 1.41 (still healthy)
        // Actually we need HF < 1: push EURC to $1.50:
        //   HF = 10000*1.50*0.94 / 9000 = 14100/9000 = 1.57 still healthy (col up too)
        // FX liquidation happens when EURC drops vs USD while borrowing USDC:
        // Flip: Alice borrows USDC (USD stable), col is EURC (EUR stable)
        // If EURC drops: col value drops, HF drops
        // EURC -> $0.80: HF = 10000*0.80*0.94 / 9000 = 7520/9000 = 0.836 -> liquidatable
        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(eurc), 80000000); // $0.80 — EUR weakens
        vm.stopBroadcast();
        console.log("[4a] EURC -> $0.80 (EUR weakens)");
        _logHF(alice, address(eurc), address(usdc), "4-alice-after-eurc-drop");

        // Deployer liquidates alice
        vm.startBroadcast(pkDeployer);
        pool.liquidate(alice, address(eurc), address(usdc), type(uint256).max, 0);
        vm.stopBroadcast();
        console.log("[4b] deployer liquidated alice FX position");
        _logHF(alice, address(eurc), address(usdc), "4-alice-post-liquidation");

        // Restore price
        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(eurc), 1_08000000);
        vm.stopBroadcast();
        console.log("[4c] EURC restored $1.08");

        console.log("--- Final reserve state ---");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _logHF(address user, address col, address debt, string memory tag) internal view {
        try pool.getHealthFactor(user, col, debt) returns (uint256 hf) {
            console.log("[HF] %s = %d (WAD)", tag, hf);
        } catch {
            console.log("[HF] %s -> no position or no debt", tag);
        }
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
        console.log("[RES] %s supplied=%d borrowed=%d", name, supplied, borrowed);
    }
}
