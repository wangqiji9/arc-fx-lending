// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Continues SeedArc from where it failed (after alice/bob/charlie opened positions).
/// @dev SeedArc.s.sol step 1-2c already completed on-chain.
///      This script runs: bob addCollateral+repay, step3 (liquidation), step4 (FX liquidation).
contract ContinueSeedArc is Script {
    LendingPool pool;
    MockPriceOracle oracle;
    MockERC20 usdc;
    MockERC20 eurc;
    MockERC20 weth;

    uint256 pkDeployer;
    uint256 pkAlice;
    uint256 pkBob;

    address deployer;
    address alice;
    address bob;

    function run() external {
        pkDeployer = vm.envUint("PRIVATE_KEY");
        pkAlice    = vm.envUint("PK_ALICE");
        pkBob      = vm.envUint("PK_BOB");

        deployer = vm.addr(pkDeployer);
        alice    = vm.addr(pkAlice);
        bob      = vm.addr(pkBob);

        pool   = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        oracle = MockPriceOracle(vm.envAddress("MOCK_ORACLE_ADDRESS"));
        usdc   = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc   = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth   = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== ContinueSeedArc ===");

        // ── Bob needs 1 more WETH for addCollateral ───────────────
        vm.startBroadcast(pkDeployer);
        weth.mint(bob, 1e18);
        vm.stopBroadcast();
        console.log("[fix] minted 1 WETH to bob");

        // ── Bob: addCollateral + repay ─────────────────────────────
        vm.startBroadcast(pkBob);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.addCollateral(address(weth), address(usdc), 1e18);
        pool.repay(bob, address(weth), address(usdc), 1_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(weth), address(usdc), "bob-after-addCol+repay");
        console.log("[2d] bob: addCollateral 1 WETH + repay 1,000 USDC");

        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");

        // ── Step 3: ETH crash -> liquidate Bob ─────────────────────
        console.log("--- Step 3: ETH crash -> liquidate bob ---");

        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(weth), 1700e8);
        vm.stopBroadcast();
        console.log("[3a] WETH -> $1,700");
        _logHF(bob, address(weth), address(usdc), "3-bob-after-crash");

        vm.startBroadcast(pkDeployer);
        usdc.mint(deployer, 15_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.liquidate(bob, address(weth), address(usdc), 9_000e6, 0);
        vm.stopBroadcast();
        console.log("[3b] deployer liquidated bob");
        _logHF(bob, address(weth), address(usdc), "3-bob-post-liquidation");

        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(weth), 3000e8);
        vm.stopBroadcast();
        console.log("[3c] WETH restored $3,000");

        // ── Step 4: EURC drops -> liquidate Alice FX position ──────
        console.log("--- Step 4: EURC drops -> liquidate alice FX ---");

        // Alice: 10,000 EURC col @ $1.08, borrowed 9,000 USDC
        // FX LT=94%; HF = 10000*0.80*0.94 / 9000 = 0.836 at $0.80
        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(eurc), 80000000); // $0.80
        vm.stopBroadcast();
        console.log("[4a] EURC -> $0.80 (EUR weakens)");
        _logHF(alice, address(eurc), address(usdc), "4-alice-after-eurc-drop");

        vm.startBroadcast(pkDeployer);
        usdc.mint(deployer, 10_000e6);
        pool.liquidate(alice, address(eurc), address(usdc), type(uint256).max, 0);
        vm.stopBroadcast();
        console.log("[4b] deployer liquidated alice FX position");
        _logHF(alice, address(eurc), address(usdc), "4-alice-post-liquidation");

        vm.startBroadcast(pkDeployer);
        oracle.setPrice(address(eurc), 108000000); // restore $1.08
        vm.stopBroadcast();
        console.log("[4c] EURC restored $1.08");

        console.log("--- Final reserve state ---");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");

        console.log("[ALL DONE]");
    }

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
