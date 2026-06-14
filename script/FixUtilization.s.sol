// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Fix pool utilization for frontend demo.
///
/// Problem: DeployArc pre-seeded 1M USDC + 500K EURC + 100 WETH as initial liquidity.
///          Our borrows (24K USDC, 7.5K EURC) give only 2-3% utilization → near-zero APY.
///
/// Fix:
///   Step 1. Deployer withdraws most of the initial seed to shrink pool supply.
///   Step 2. "You" account gets more USDC minted.
///   Step 3. "You" + Alice + Deployer open new borrow positions.
///
/// Target utilization (kink model: slope1=4%, kink=80%):
///   USDC  36K / 50K = 72%  → borrow ~3.6%,  supply ~2.3%
///   EURC  42.5K / 60K = 71% → borrow ~3.5%, supply ~2.3%  (+ fxPremium at display)
///   WETH  16 / 35 = 46%    → borrow ~2.3%,  supply ~0.9%
///
/// Run:
///   source deploy-keys/.env.deploy && \
///   export YOU_ADDRESS=0x9Aaaa925668A46fD1928b7e5AF19B502242d72F4 && \
///   export PK_YOU=0x6aa6d337dba463dec961d53ee99ce426d2e8233235fd7dddcf4bf669e8496535 && \
///   forge script script/FixUtilization.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vv
contract FixUtilization is Script {
    LendingPool pool;
    MockERC20 usdc;
    MockERC20 eurc;
    MockERC20 weth;

    uint256 pkDeployer;
    uint256 pkAlice;
    uint256 pkYou;

    address deployer;
    address alice;
    address you;

    function run() external {
        pkDeployer = vm.envUint("PRIVATE_KEY");
        pkAlice    = vm.envUint("PK_ALICE");
        pkYou      = vm.envUint("PK_YOU");

        deployer = vm.addr(pkDeployer);
        alice    = vm.addr(pkAlice);
        you      = vm.addr(pkYou);

        pool = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        usdc = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== FixUtilization ===");
        _logState("BEFORE");

        _step1_deployerWithdrawSeed();
        _step2_mintMoreToYou();
        _step3_newPositions();

        _logState("AFTER");
        console.log("[DONE] Utilization fixed for frontend demo.");
    }

    // ────────────────────────────────────────────────────────────
    // Step 1: Deployer withdraws the initial 1M USDC + 500K EURC + 100 WETH seed
    //         (DeployArc deposited these to bootstrap liquidity)
    //         Withdraw targets leave ~50K USDC, ~60K EURC, ~35 WETH in pool.
    // ────────────────────────────────────────────────────────────

    function _step1_deployerWithdrawSeed() internal {
        console.log("--- Step 1: deployer withdraws initial seed ---");

        vm.startBroadcast(pkDeployer);

        // USDC: withdraw 985,000 (pool goes 1,035K -> ~50K)
        // Available = 1,035K - 24K borrowed = 1,011K; we withdraw 985K < 1,011K ✓
        pool.withdraw(address(usdc), 985_000e6);
        console.log("[1a] deployer withdrew 985,000 USDC");

        // EURC: withdraw 500,000 (pool goes 560K -> ~60K)
        // Available = 560K - 7.5K borrowed = 552.5K; we withdraw 500K ✓
        pool.withdraw(address(eurc), 500_000e6);
        console.log("[1b] deployer withdrew 500,000 EURC");

        // WETH: withdraw 100 WETH (pool goes 135 -> ~35)
        // Available = 135 - 0 borrowed = 135 ✓
        pool.withdraw(address(weth), 100e18);
        console.log("[1c] deployer withdrew 100 WETH");

        vm.stopBroadcast();
    }

    // ────────────────────────────────────────────────────────────
    // Step 2: Mint 100K more USDC to the "You" account
    //         (they already have 50K USDC, 20K EURC, 10 WETH)
    // ────────────────────────────────────────────────────────────

    function _step2_mintMoreToYou() internal {
        console.log("--- Step 2: mint extra USDC to You ---");
        vm.startBroadcast(pkYou);
        usdc.mint(you, 100_000e6);
        vm.stopBroadcast();
        console.log("[2] You now has ~150K USDC, 20K EURC, 10 WETH");
    }

    // ────────────────────────────────────────────────────────────
    // Step 3: Open new borrow positions to push utilization
    //
    //   You:      50K USDC col  -> 25K EURC  [FX,  HF ~1.22]   EURC borrows +25K
    //   You:      40K USDC col  ->  9 WETH   [Std, HF ~1.33]   WETH borrows +9
    //   You:      15K EURC col  -> 12K USDC  [FX,  HF ~1.27]   USDC borrows +12K
    //   Alice:    30K USDC col  ->  7 WETH   [Std, HF ~1.14]   WETH borrows +7
    //   Deployer: 15K USDC col  -> 10K EURC  [FX,  HF ~1.31]   EURC borrows +10K
    //
    //   USDC: 24K + 12K = 36K / 50K = 72%
    //   EURC: 7.5K + 25K + 10K = 42.5K / 60K = 71%
    //   WETH: 0 + 9 + 7 = 16 / 35 = 46%
    // ────────────────────────────────────────────────────────────

    function _step3_newPositions() internal {
        console.log("--- Step 3: new borrow positions ---");

        // You: 50K USDC col -> 25K EURC (FX E-Mode)
        // LTV 90%; max = 50K * 1.00 * 0.90 / 1.08 = 41,667 EURC; HF = 50K*0.94/(25K*1.08) = 1.74
        vm.startBroadcast(pkYou);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.openPosition(address(usdc), 50_000e6, address(eurc), 25_000e6);
        vm.stopBroadcast();
        _logHF(you, address(usdc), address(eurc), "You USDC/EURC FX");

        // You: 40K USDC col -> 9 WETH (Standard)
        // LTV 75%; max = 40K * 0.75 / 3000 = 10 WETH; borrow 9 -> HF = 40K*0.80/(9*3000) = 1.19
        vm.startBroadcast(pkYou);
        pool.openPosition(address(usdc), 40_000e6, address(weth), 9e18);
        vm.stopBroadcast();
        _logHF(you, address(usdc), address(weth), "You USDC/WETH Standard");

        // You: 15K EURC col -> 12K USDC (FX E-Mode)
        // LTV 90%; max = 15K*1.08*0.90 = 14,580 USDC; HF = 15K*1.08*0.94/12K = 1.27
        vm.startBroadcast(pkYou);
        pool.openPosition(address(eurc), 15_000e6, address(usdc), 12_000e6);
        vm.stopBroadcast();
        _logHF(you, address(eurc), address(usdc), "You EURC/USDC FX");

        // Alice: 30K USDC col -> 7 WETH (Standard)
        // LTV 75%; max = 30K*0.75/3000 = 7.5 WETH; HF = 30K*0.80/(7*3000) = 1.14
        vm.startBroadcast(pkAlice);
        usdc.approve(address(pool), type(uint256).max);
        pool.openPosition(address(usdc), 30_000e6, address(weth), 7e18);
        vm.stopBroadcast();
        _logHF(alice, address(usdc), address(weth), "Alice USDC/WETH Standard");

        // Deployer: 15K USDC col -> 10K EURC (FX E-Mode)
        // LTV 90%; max = 15K*1.00*0.90/1.08 = 12,500 EURC; HF = 15K*0.94/(10K*1.08) = 1.31
        vm.startBroadcast(pkDeployer);
        usdc.approve(address(pool), type(uint256).max);
        pool.openPosition(address(usdc), 15_000e6, address(eurc), 10_000e6);
        vm.stopBroadcast();
        _logHF(deployer, address(usdc), address(eurc), "Deployer USDC/EURC FX");
    }

    // ────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────

    function _logState(string memory tag) internal view {
        console.log("--- State:", tag, "---");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * uint256(r.liquidityIndex)) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * uint256(r.borrowIndex))    / RAY;
        uint256 utilBps  = supplied > 0 ? (borrowed * 10_000) / supplied : 0;
        console.log("[RES]", name, "util_bps=", utilBps);
        console.log("  supplied=", supplied, "borrowed=", borrowed);
    }

    function _logHF(address user, address col, address debt, string memory tag) internal view {
        try pool.getHealthFactor(user, col, debt) returns (uint256 hf) {
            console.log("[HF]", tag, "=", hf);
        } catch {
            console.log("[HF]", tag, "-> no position");
        }
    }
}
