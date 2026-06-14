// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Seed realistic frontend-demo state on Arc Testnet.
///
/// Each of the 4 accounts acts as both a lender and a borrower, covering
/// Standard mode and FX E-Mode across all three assets.
///
/// Lender deposits:
///   Deployer  20,000 USDC
///   Alice         10 WETH
///   Bob       30,000 EURC
///   Charlie   15,000 USDC
///
/// Borrow positions:
///   Alice    5 WETH col  ->  10,000 USDC  [Standard,  HF ~1.20]
///   Bob      3 WETH col  ->   6,000 USDC  [Standard,  HF ~1.20]
///   Charlie 10,000 USDC  ->   7,500 EURC  [FX E-Mode, HF ~1.16]
///   Deployer 10,000 EURC ->   8,000 USDC  [FX E-Mode, HF ~1.27]
///
/// Resulting utilization:
///   USDC  24,000 / 35,000 = 68.6%  (~12% borrow APY)
///   EURC   7,500 / 30,000 = 25.0%  (~3% borrow APY)
///   WETH       0 /     10 =  0.0%  (collateral only in this demo)
///
/// Prerequisites: RestoreProtocol.s.sol has been run (clean slate).
///
/// Run:
///   source deploy-keys/.env.deploy && \
///   forge script script/SeedFrontend.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vv
contract SeedFrontend is Script {
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
        pkAlice    = vm.envUint("PK_ALICE");
        pkBob      = vm.envUint("PK_BOB");
        pkCharlie  = vm.envUint("PK_CHARLIE");

        deployer = vm.addr(pkDeployer);
        alice    = vm.addr(pkAlice);
        bob      = vm.addr(pkBob);
        charlie  = vm.addr(pkCharlie);

        pool = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        usdc = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== SeedFrontend ===");
        console.log("Pool    :", address(pool));
        console.log("Deployer:", deployer);
        console.log("Alice   :", alice);
        console.log("Bob     :", bob);
        console.log("Charlie :", charlie);

        _step1_mintTokens();
        _step2_lendDeposits();
        _step3_borrowPositions();
        _logFinalState();

        console.log("[ALL DONE] Protocol seeded for frontend demo.");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 1: Mint tokens to each account
    // ────────────────────────────────────────────────────────────────

    function _step1_mintTokens() internal {
        console.log("--- Step 1: mint tokens ---");
        vm.startBroadcast(pkDeployer);

        // Deployer: 20K USDC to deposit + 10K USDC buffer + 10K EURC as collateral
        usdc.mint(deployer, 35_000e6);
        eurc.mint(deployer, 12_000e6);

        // Alice: 15 WETH (10 deposit + 5 collateral)
        weth.mint(alice, 15e18);
        usdc.mint(alice, 1_000e6); // small buffer

        // Bob: 30K EURC to deposit + 5 WETH (3 collateral + 2 buffer) + some USDC
        eurc.mint(bob, 32_000e6);
        weth.mint(bob, 5e18);
        usdc.mint(bob, 1_000e6);

        // Charlie: 25K USDC (15K deposit + 10K collateral) + some EURC buffer
        usdc.mint(charlie, 27_000e6);
        eurc.mint(charlie, 1_000e6);

        vm.stopBroadcast();
        console.log("[1] tokens minted");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 2: Each account deposits into lending pool
    //   Deployer  20,000 USDC
    //   Alice         10 WETH
    //   Bob       30,000 EURC
    //   Charlie   15,000 USDC
    // ────────────────────────────────────────────────────────────────

    function _step2_lendDeposits() internal {
        console.log("--- Step 2: lender deposits ---");

        vm.startBroadcast(pkDeployer);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 20_000e6);
        vm.stopBroadcast();
        console.log("[2a] deployer deposited 20,000 USDC");

        vm.startBroadcast(pkAlice);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 10e18);
        vm.stopBroadcast();
        console.log("[2b] alice deposited 10 WETH");

        vm.startBroadcast(pkBob);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(eurc), 30_000e6);
        vm.stopBroadcast();
        console.log("[2c] bob deposited 30,000 EURC");

        vm.startBroadcast(pkCharlie);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 15_000e6);
        vm.stopBroadcast();
        console.log("[2d] charlie deposited 15,000 USDC");

        console.log("    USDC pool: 35,000 supplied");
        console.log("    EURC pool: 30,000 supplied");
        console.log("    WETH pool: 10 supplied");
    }

    // ────────────────────────────────────────────────────────────────
    // Step 3: Open borrow positions
    //   Alice    5 WETH     -> 10,000 USDC  [Standard]
    //   Bob      3 WETH     ->  6,000 USDC  [Standard]
    //   Charlie  10K USDC   ->  7,500 EURC  [FX E-Mode]
    //   Deployer 10K EURC   ->  8,000 USDC  [FX E-Mode]
    // ────────────────────────────────────────────────────────────────

    function _step3_borrowPositions() internal {
        console.log("--- Step 3: borrow positions ---");

        // Alice: 5 WETH @ $3000 = $15,000 col; borrow 10,000 USDC
        //   LTV 75% -> max $11,250; HF = 5*3000*0.80/10000 = 1.20
        vm.startBroadcast(pkAlice);
        pool.openPosition(address(weth), 5e18, address(usdc), 10_000e6);
        vm.stopBroadcast();
        _logHF(alice, address(weth), address(usdc), "alice WETH/USDC Standard");

        // Bob: 3 WETH @ $3000 = $9,000 col; borrow 6,000 USDC
        //   LTV 75% -> max $6,750; HF = 3*3000*0.80/6000 = 1.20
        vm.startBroadcast(pkBob);
        pool.openPosition(address(weth), 3e18, address(usdc), 6_000e6);
        vm.stopBroadcast();
        _logHF(bob, address(weth), address(usdc), "bob WETH/USDC Standard");

        // Charlie: 10,000 USDC col @ $1.00; borrow 7,500 EURC @ $1.08
        //   FX LTV 90% -> max 10000*0.90/1.08 = 8,333 EURC; HF = 10000*1.00*0.94/(7500*1.08) ~1.16
        vm.startBroadcast(pkCharlie);
        pool.openPosition(address(usdc), 10_000e6, address(eurc), 7_500e6);
        vm.stopBroadcast();
        _logHF(charlie, address(usdc), address(eurc), "charlie USDC/EURC FX");

        // Deployer: 10,000 EURC col @ $1.08; borrow 8,000 USDC
        //   FX LTV 90% -> max 10000*1.08*0.90 = $9,720; HF = 10000*1.08*0.94/8000 ~1.27
        vm.startBroadcast(pkDeployer);
        pool.openPosition(address(eurc), 10_000e6, address(usdc), 8_000e6);
        vm.stopBroadcast();
        _logHF(deployer, address(eurc), address(usdc), "deployer EURC/USDC FX");
    }

    // ────────────────────────────────────────────────────────────────
    // Final state log
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
        uint256 supplied  = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        uint256 borrowed  = (uint256(r.totalScaledBorrow) * r.borrowIndex)    / RAY;
        uint256 utilBps   = supplied > 0 ? (borrowed * 10_000) / supplied : 0;
        console.log("[RES]", name);
        console.log("  supplied=", supplied, "borrowed=", borrowed);
        console.log("  util_bps=", utilBps);
    }
}
