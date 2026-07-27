// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Scale the live Arc Testnet demo state up to a ~$105K TVL for the hackathon deck.
///
/// Additive on top of the existing seeded state (does NOT reset). `openPosition` is
/// accumulative when a position key already exists, so growing an existing position and
/// opening a new one use the same call.
///
/// Target reserves:
///   USDC  61,000 supplied / ~39,100 borrowed  (64% util)
///   EURC  30,000 supplied / ~10,180 borrowed  (34% util)
///   WETH       4 supplied /      2.4 borrowed (60% util)
///   TVL = 61,000 + 30,000*1.08 + 4*3,000 = ~$105,400
///
/// Oracle prices assumed: USDC $1.00, EURC $1.08, WETH $3,000.
///
/// Run:
///   source deploy-keys/.env.deploy && \
///   forge script script/ScaleUp.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast --slow -vv
contract ScaleUp is Script {
    LendingPool pool;
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
        pkAlice = vm.envUint("PK_ALICE");
        pkBob = vm.envUint("PK_BOB");
        pkCharlie = vm.envUint("PK_CHARLIE");

        deployer = vm.addr(pkDeployer);
        alice = vm.addr(pkAlice);
        bob = vm.addr(pkBob);
        charlie = vm.addr(pkCharlie);

        pool = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        usdc = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== ScaleUp: target ~$105K TVL ===");

        _step1_mint();
        _step2_approve();
        _step3_deposits();
        _step4_positions();
        _logFinalState();

        console.log("[ALL DONE]");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 1: top up balances (deployer already holds ~1M USDC / 512K EURC)
    // ────────────────────────────────────────────────────────────────

    function _step1_mint() internal {
        console.log("--- Step 1: mint ---");
        vm.startBroadcast(pkDeployer);
        usdc.mint(alice, 10_000e6); // 14.5K deposit + 5K collateral
        eurc.mint(alice, 10_000e6); // EURC/USDC FX collateral
        usdc.mint(bob, 23_000e6); // 20K deposit + 5.5K + 5K collateral
        eurc.mint(charlie, 20_000e6); // 17.5K deposit + 10K collateral
        vm.stopBroadcast();
        console.log("[1] minted");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 2: refresh allowances (earlier scripts used a finite uint128 max)
    // ────────────────────────────────────────────────────────────────

    function _step2_approve() internal {
        console.log("--- Step 2: approve ---");
        uint256[4] memory pks = [pkDeployer, pkAlice, pkBob, pkCharlie];
        for (uint256 i = 0; i < pks.length; i++) {
            vm.startBroadcast(pks[i]);
            usdc.approve(address(pool), type(uint256).max);
            eurc.approve(address(pool), type(uint256).max);
            weth.approve(address(pool), type(uint256).max);
            vm.stopBroadcast();
        }
        console.log("[2] approved");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 3: lender deposits — liquidity must land before the borrows
    //   USDC 2,100 -> 61,000   EURC 500 -> 30,000   WETH 0.2 -> 4.0
    // ────────────────────────────────────────────────────────────────

    function _step3_deposits() internal {
        console.log("--- Step 3: deposits ---");

        vm.startBroadcast(pkDeployer);
        pool.deposit(address(usdc), 24_400e6);
        vm.stopBroadcast();
        console.log("[3a] deployer +24,400 USDC");

        vm.startBroadcast(pkAlice);
        pool.deposit(address(usdc), 14_500e6);
        pool.deposit(address(weth), 3.8e18);
        vm.stopBroadcast();
        console.log("[3b] alice +14,500 USDC, +3.8 WETH");

        vm.startBroadcast(pkBob);
        pool.deposit(address(usdc), 20_000e6);
        pool.deposit(address(eurc), 12_000e6);
        vm.stopBroadcast();
        console.log("[3c] bob +20,000 USDC, +12,000 EURC");

        vm.startBroadcast(pkCharlie);
        pool.deposit(address(eurc), 17_500e6);
        vm.stopBroadcast();
        console.log("[3d] charlie +17,500 EURC");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 4: borrow positions (10 total across 3 risk paths)
    //
    // Standard long (WETH col -> USDC debt), LTV 75% / LT 80%:
    //   alice    +5 WETH   -> +10,000 USDC   HF ~1.20
    //   deployer +3 WETH   ->  +6,000 USDC   HF ~1.20
    //   bob       3 WETH   ->   6,000 USDC   HF ~1.20  [new]
    //
    // FX E-Mode (USDC <-> EURC), LTV 90% / LT 94%:
    //   bob      +5,500 USDC -> +4,000 EURC  HF ~1.21
    //   charlie +10,000 EURC -> +8,000 USDC  HF ~1.28
    //   alice     5,000 USDC ->  3,500 EURC  HF ~1.24  [new]
    //   deployer  3,600 USDC ->  2,500 EURC  HF ~1.25  [new]
    //   alice    10,000 EURC ->  8,000 USDC  HF ~1.27  [new]
    //
    // Standard short (USDC col -> WETH debt), LTV 75% / LT 80%:
    //   charlie   8,000 USDC ->    1.5 WETH  HF ~1.42  [new]
    //   bob       5,000 USDC ->    0.9 WETH  HF ~1.48  [new]
    // ────────────────────────────────────────────────────────────────

    function _step4_positions() internal {
        console.log("--- Step 4: positions ---");

        // Standard long
        vm.startBroadcast(pkAlice);
        pool.openPosition(address(weth), 5e18, address(usdc), 10_000e6);
        vm.stopBroadcast();
        _logHF(alice, address(weth), address(usdc), "alice WETH/USDC std");

        vm.startBroadcast(pkDeployer);
        pool.openPosition(address(weth), 3e18, address(usdc), 6_000e6);
        vm.stopBroadcast();
        _logHF(deployer, address(weth), address(usdc), "deployer WETH/USDC std");

        vm.startBroadcast(pkBob);
        pool.openPosition(address(weth), 3e18, address(usdc), 6_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(weth), address(usdc), "bob WETH/USDC std");

        // FX E-Mode
        vm.startBroadcast(pkBob);
        pool.openPosition(address(usdc), 5_500e6, address(eurc), 4_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(usdc), address(eurc), "bob USDC/EURC fx");

        vm.startBroadcast(pkCharlie);
        pool.openPosition(address(eurc), 10_000e6, address(usdc), 8_000e6);
        vm.stopBroadcast();
        _logHF(charlie, address(eurc), address(usdc), "charlie EURC/USDC fx");

        vm.startBroadcast(pkAlice);
        pool.openPosition(address(usdc), 5_000e6, address(eurc), 3_500e6);
        pool.openPosition(address(eurc), 10_000e6, address(usdc), 8_000e6);
        vm.stopBroadcast();
        _logHF(alice, address(usdc), address(eurc), "alice USDC/EURC fx");
        _logHF(alice, address(eurc), address(usdc), "alice EURC/USDC fx");

        vm.startBroadcast(pkDeployer);
        pool.openPosition(address(usdc), 3_600e6, address(eurc), 2_500e6);
        vm.stopBroadcast();
        _logHF(deployer, address(usdc), address(eurc), "deployer USDC/EURC fx");

        // Standard short (borrow WETH)
        vm.startBroadcast(pkCharlie);
        pool.openPosition(address(usdc), 8_000e6, address(weth), 1.5e18);
        vm.stopBroadcast();
        _logHF(charlie, address(usdc), address(weth), "charlie USDC/WETH short");

        vm.startBroadcast(pkBob);
        pool.openPosition(address(usdc), 5_000e6, address(weth), 0.9e18);
        vm.stopBroadcast();
        _logHF(bob, address(usdc), address(weth), "bob USDC/WETH short");
    }

    // ────────────────────────────────────────────────────────────────

    function _logFinalState() internal view {
        console.log("--- Final State ---");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    function _logHF(address user, address col, address debt, string memory tag) internal view {
        try pool.getHealthFactor(user, col, debt) returns (uint256 hf) {
            console.log("[HF]", tag);
            console.log("     =", hf);
        } catch {
            console.log("[HF]", tag, "-> no position");
        }
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
        uint256 utilBps = supplied > 0 ? (borrowed * 10_000) / supplied : 0;
        console.log("[RES]", name);
        console.log("  supplied=", supplied, "borrowed=", borrowed);
        console.log("  util_bps=", utilBps);
    }
}
