// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Clear all existing positions/deposits, then re-seed with small pool + ~50% utilization.
///
/// Target state:
///   Lender deposits:
///     Alice    500 USDC
///     Bob      0.3 WETH
///     Charlie  800 EURC
///     Deployer 1,200 USDC  (replaces the 1M initial liquidity)
///
///   Borrow positions (util ~50%):
///     Alice   0.15 WETH col  ->  300 USDC   [Standard]
///     Bob     400 USDC  col  ->  250 EURC   [FX E-Mode, HF ~1.38]
///     Charlie 600 EURC  col  ->  350 USDC   [FX E-Mode, HF ~1.38]
///     Deployer 0.1 WETH col  ->  200 USDC   [Standard]
///
/// Run:
///   cd <project-root>
///   export $(grep -v '^#' deploy-keys/.env.deploy | xargs) && \
///   forge script script/Reseed.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vv
contract Reseed is Script {
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

    address constant RPC_DUMMY = address(0); // unused

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

        console.log("=== Reseed ===");
        console.log("Pool:", address(pool));

        _step1_closePositions();
        _step2_withdrawDeposits();
        _step3_newDeposits();
        _step4_newBorrows();

        console.log("[DONE] Pool re-seeded.");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    // ── Step 1: repay all debt and withdraw collateral ────────────────

    function _step1_closePositions() internal {
        console.log("--- Step 1: close all positions ---");

        // Alice: WETH/USDC — repay USDC debt
        _repayAndClose(pkAlice, alice, address(weth), address(usdc), usdc);

        // Bob: WETH/USDC — repay USDC debt
        _repayAndClose(pkBob, bob, address(weth), address(usdc), usdc);

        // Charlie: USDC/EURC — repay EURC debt
        _repayAndClose(pkCharlie, charlie, address(usdc), address(eurc), eurc);

        // Deployer: EURC/USDC — repay USDC debt
        _repayAndClose(pkDeployer, deployer, address(eurc), address(usdc), usdc);
    }

    function _repayAndClose(
        uint256 pk,
        address account,
        address colAsset,
        address debtAsset,
        MockERC20 debtToken
    ) internal {
        bytes32 key = pool.positionKey(account, colAsset, debtAsset);
        DataTypes.Position memory pos = pool.getPosition(key);
        if (pos.collateralAsset == address(0)) {
            console.log("  no position for", account);
            return;
        }

        DataTypes.ReserveData memory r = pool.getReserveData(debtAsset);
        uint256 liveDebt = (uint256(pos.scaledDebt) * uint256(r.borrowIndex)) / RAY + 1e6; // +1 USDC/EURC buffer

        // mint enough to cover debt + interest (deployer can mint)
        vm.startBroadcast(pkDeployer);
        debtToken.mint(account, liveDebt);
        vm.stopBroadcast();

        vm.startBroadcast(pk);
        debtToken.approve(address(pool), type(uint256).max);
        pool.repay(account, colAsset, debtAsset, type(uint128).max);
        // withdraw all collateral now that debt is zero
        uint256 colAmount = pool.getPosition(key).collateralAmount;
        if (colAmount > 0) {
            pool.withdrawCollateral(colAsset, debtAsset, colAmount);
        }
        vm.stopBroadcast();
        console.log("  closed position for", account);
    }

    // ── Step 2: withdraw all existing lender deposits ─────────────────

    function _step2_withdrawDeposits() internal {
        console.log("--- Step 2: withdraw all deposits ---");

        _withdrawAll(pkAlice,    alice,    address(weth), weth);
        _withdrawAll(pkBob,      bob,      address(eurc), eurc);
        _withdrawAll(pkCharlie,  charlie,  address(usdc), usdc);
        // Deployer: USDC (1M+) and EURC (500K) — pull everything
        _withdrawAll(pkDeployer, deployer, address(usdc), usdc);
        _withdrawAll(pkDeployer, deployer, address(eurc), eurc);
        _withdrawAll(pkDeployer, deployer, address(weth), weth);
    }

    function _withdrawAll(uint256 pk, address account, address asset, MockERC20 token) internal {
        uint256 scaled = pool.getScaledDeposit(asset, account);
        if (scaled == 0) return;

        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        // value = floor; withdraw that exact floor amount (avoids rounding revert)
        uint256 value = (scaled * uint256(r.liquidityIndex)) / RAY;
        if (value == 0) return;

        vm.startBroadcast(pk);
        pool.withdraw(asset, value);
        vm.stopBroadcast();
        console.log("  withdrew from", account, value);
    }

    // ── Step 3: small fresh deposits ─────────────────────────────────
    //   Alice    500 USDC
    //   Bob      0.3 WETH  (~$900)
    //   Charlie  800 EURC
    //   Deployer 1200 USDC

    function _step3_newDeposits() internal {
        console.log("--- Step 3: new small deposits ---");

        vm.startBroadcast(pkDeployer);
        usdc.mint(alice,    600e6);
        weth.mint(bob,      0.4e18);
        eurc.mint(charlie,  900e6);
        usdc.mint(deployer, 1500e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkAlice);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 500e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkBob);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 0.3e18);
        vm.stopBroadcast();

        vm.startBroadcast(pkCharlie);
        eurc.approve(address(pool), type(uint256).max);
        pool.deposit(address(eurc), 800e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkDeployer);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1200e6);
        vm.stopBroadcast();

        console.log("  deposits done: 1700 USDC, 0.3 WETH, 800 EURC");
    }

    // ── Step 4: borrow ~50% utilization ──────────────────────────────
    //   USDC pool 1700 total → borrow ~850
    //   WETH pool 0.3 → borrow 0 (used as collateral only here)
    //   EURC pool 800 → borrow ~400
    //
    //   Alice:   0.15 WETH col ($450) → 300 USDC  [Standard, HF = 450*0.8/300 = 1.20]
    //   Bob:     400 USDC col  ($400) → 250 EURC  [FX E-Mode, HF = 400*0.94/(250*1.08) ≈ 1.39]
    //   Charlie: 600 EURC col  ($648) → 350 USDC  [FX E-Mode, HF = 648*0.94/350 ≈ 1.74]
    //   Deployer:0.1  WETH col ($300) → 200 USDC  [Standard, HF = 300*0.8/200 = 1.20]
    //   Total USDC borrowed: 300+350+200 = 850  (850/1700 = 50%)
    //   Total EURC borrowed: 250            (250/800 = 31%)

    function _step4_newBorrows() internal {
        console.log("--- Step 4: new borrow positions (~50% util) ---");

        vm.startBroadcast(pkDeployer);
        weth.mint(alice,    0.2e18);
        usdc.mint(bob,      450e6);
        eurc.mint(charlie,  650e6);
        weth.mint(deployer, 0.15e18);
        vm.stopBroadcast();

        // Alice: 0.15 WETH → 300 USDC
        vm.startBroadcast(pkAlice);
        weth.approve(address(pool), type(uint256).max);
        pool.openPosition(address(weth), 0.15e18, address(usdc), 300e6);
        vm.stopBroadcast();
        _logHF(alice, address(weth), address(usdc), "alice WETH/USDC");

        // Bob: 400 USDC → 250 EURC  (FX E-Mode)
        vm.startBroadcast(pkBob);
        usdc.approve(address(pool), type(uint256).max);
        pool.openPosition(address(usdc), 400e6, address(eurc), 250e6);
        vm.stopBroadcast();
        _logHF(bob, address(usdc), address(eurc), "bob USDC/EURC FX");

        // Charlie: 600 EURC → 350 USDC  (FX E-Mode)
        vm.startBroadcast(pkCharlie);
        eurc.approve(address(pool), type(uint256).max);
        pool.openPosition(address(eurc), 600e6, address(usdc), 350e6);
        vm.stopBroadcast();
        _logHF(charlie, address(eurc), address(usdc), "charlie EURC/USDC FX");

        // Deployer: 0.1 WETH → 200 USDC
        vm.startBroadcast(pkDeployer);
        pool.openPosition(address(weth), 0.1e18, address(usdc), 200e6);
        vm.stopBroadcast();
        _logHF(deployer, address(weth), address(usdc), "deployer WETH/USDC");
    }

    function _logHF(address user, address col, address debt, string memory tag) internal view {
        try pool.getHealthFactor(user, col, debt) returns (uint256 hf) {
            console.log("  HF", tag, "=", hf);
        } catch {
            console.log("  HF", tag, "-> no position");
        }
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * uint256(r.liquidityIndex)) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * uint256(r.borrowIndex)) / RAY;
        uint256 utilBps  = supplied > 0 ? (borrowed * 10_000) / supplied : 0;
        console.log("[RES]", name, supplied, borrowed);
    }
}
