// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";

/// @notice Restore protocol to clean state after SeedArc seeding.
///
/// What this does:
///   1. Deployer repays Alice's bad debt (collateral=0, ~1195 USDC residual)
///   2. Deployer repays Bob's dust debt (~0.00008 USDC) on Bob's behalf
///   3. Bob withdraws his remaining collateral (~0.309 WETH)
///   4. Charlie repays his EURC debt (~8000 EURC + accrued interest)
///   5. Charlie withdraws his 10,000 USDC collateral
///
/// Result: no open borrow positions, no bad debt. Lender deposits stay.
///
/// Run:
///   source deploy-keys/.env.deploy && \
///   forge script script/RestoreProtocol.s.sol \
///     --rpc-url https://rpc.testnet.arc.network \
///     --broadcast -vv
contract RestoreProtocol is Script {
    LendingPool pool;
    MockERC20 usdc;
    MockERC20 eurc;
    MockERC20 weth;

    uint256 pkDeployer;
    uint256 pkBob;
    uint256 pkCharlie;

    address deployer;
    address alice;
    address bob;
    address charlie;

    function run() external {
        pkDeployer = vm.envUint("PRIVATE_KEY");
        pkBob      = vm.envUint("PK_BOB");
        pkCharlie  = vm.envUint("PK_CHARLIE");

        deployer = vm.addr(pkDeployer);
        alice    = vm.envAddress("ALICE_ADDRESS");
        bob      = vm.addr(pkBob);
        charlie  = vm.addr(pkCharlie);

        pool = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        usdc = MockERC20(vm.envAddress("MOCK_USDC_ADDRESS"));
        eurc = MockERC20(vm.envAddress("MOCK_EURC_ADDRESS"));
        weth = MockERC20(vm.envAddress("MOCK_WETH_ADDRESS"));

        console.log("=== RestoreProtocol ===");
        console.log("Pool    :", address(pool));
        console.log("Deployer:", deployer);
        console.log("Alice   :", alice);
        console.log("Bob     :", bob);
        console.log("Charlie :", charlie);

        _logState("BEFORE");

        _step1_repayAliceBadDebt();
        _step2_closeBobPosition();
        _step3_closeCharliePosition();

        _logState("AFTER");
        console.log("[ALL DONE] Protocol restored to clean state.");
    }

    // ────────────────────────────────────────────────────────────
    // Step 1: Deployer clears Alice's bad debt via repayBadDebt
    // ────────────────────────────────────────────────────────────

    function _step1_repayAliceBadDebt() internal {
        DataTypes.Position memory pos = pool.getPosition(alice, address(eurc), address(usdc));
        if (pos.collateralAsset == address(0)) {
            console.log("[1] Alice has no position, skipping.");
            return;
        }
        if (pos.collateralAmount != 0) {
            console.log("[1] Alice still has collateral - not bad debt, skipping.");
            return;
        }

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        uint256 actualDebt = (uint256(pos.scaledDebt) * uint256(r.borrowIndex)) / RAY;
        console.log("[1] Alice bad debt (USDC):", actualDebt);

        vm.startBroadcast(pkDeployer);
        // Ensure allowance (deployer approved max at deploy, but re-approve to be safe)
        usdc.approve(address(pool), type(uint256).max);
        pool.repayBadDebt(alice, address(eurc), address(usdc));
        vm.stopBroadcast();
        console.log("[1] Alice bad debt cleared.");
    }

    // ────────────────────────────────────────────────────────────
    // Step 2: Close Bob's dust position
    //   2a. Deployer repays Bob's dust USDC debt (on Bob's behalf)
    //   2b. Bob withdraws remaining WETH collateral
    // ────────────────────────────────────────────────────────────

    function _step2_closeBobPosition() internal {
        DataTypes.Position memory pos = pool.getPosition(bob, address(weth), address(usdc));
        if (pos.collateralAsset == address(0)) {
            console.log("[2] Bob has no position, skipping.");
            return;
        }

        DataTypes.ReserveData memory r = pool.getReserveData(address(usdc));
        uint256 actualDebt = (uint256(pos.scaledDebt) * uint256(r.borrowIndex)) / RAY;
        console.log("[2a] Bob dust debt (USDC):", actualDebt);
        console.log("[2b] Bob collateral (WETH):", uint256(pos.collateralAmount));

        // Deployer pays Bob's dust debt (amount is tiny, < 1 USDC unit)
        if (pos.scaledDebt > 0) {
            vm.startBroadcast(pkDeployer);
            usdc.approve(address(pool), type(uint256).max);
            pool.repay(bob, address(weth), address(usdc), type(uint256).max);
            vm.stopBroadcast();
            console.log("[2a] Bob dust debt repaid by deployer.");
        }

        // Bob withdraws his remaining WETH collateral
        if (pos.collateralAmount > 0) {
            vm.startBroadcast(pkBob);
            pool.withdrawCollateral(address(weth), address(usdc), uint256(pos.collateralAmount));
            vm.stopBroadcast();
            console.log("[2b] Bob withdrew remaining WETH collateral.");
        }
    }

    // ────────────────────────────────────────────────────────────
    // Step 3: Close Charlie's healthy USDC→EURC position
    //   3a. Charlie repays all EURC debt (type(uint256).max caps to actual)
    //   3b. Charlie withdraws 10,000 USDC collateral
    // ────────────────────────────────────────────────────────────

    function _step3_closeCharliePosition() internal {
        DataTypes.Position memory pos = pool.getPosition(charlie, address(usdc), address(eurc));
        if (pos.collateralAsset == address(0)) {
            console.log("[3] Charlie has no position, skipping.");
            return;
        }

        DataTypes.ReserveData memory r = pool.getReserveData(address(eurc));
        uint256 actualDebt = (uint256(pos.scaledDebt) * uint256(r.borrowIndex)) / RAY;
        console.log("[3a] Charlie debt (EURC):", actualDebt);
        console.log("[3b] Charlie collateral (USDC):", uint256(pos.collateralAmount));

        vm.startBroadcast(pkCharlie);
        eurc.approve(address(pool), type(uint256).max);
        pool.repay(charlie, address(usdc), address(eurc), type(uint256).max);
        pool.withdrawCollateral(address(usdc), address(eurc), uint256(pos.collateralAmount));
        vm.stopBroadcast();
        console.log("[3] Charlie position closed.");
    }

    // ────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────

    function _logState(string memory tag) internal view {
        console.log("--- State:", tag, "---");

        _logPosition("Alice", alice, address(eurc), address(usdc), "EURC/USDC");
        _logPosition("Bob",   bob,   address(weth), address(usdc), "WETH/USDC");
        _logPosition("Charlie", charlie, address(usdc), address(eurc), "USDC/EURC");

        DataTypes.ReserveData memory ru = pool.getReserveData(address(usdc));
        DataTypes.ReserveData memory re = pool.getReserveData(address(eurc));
        DataTypes.ReserveData memory rw = pool.getReserveData(address(weth));

        console.log("USDC totalBorrow:",
            (uint256(ru.totalScaledBorrow) * uint256(ru.borrowIndex)) / RAY);
        console.log("EURC totalBorrow:",
            (uint256(re.totalScaledBorrow) * uint256(re.borrowIndex)) / RAY);
        console.log("WETH totalBorrow:",
            (uint256(rw.totalScaledBorrow) * uint256(rw.borrowIndex)) / RAY);
    }

    function _logPosition(
        string memory name,
        address user,
        address col,
        address debt,
        string memory pair
    ) internal view {
        DataTypes.Position memory pos = pool.getPosition(user, col, debt);
        if (pos.collateralAsset == address(0)) {
            console.log(name, pair, "no position");
            return;
        }
        DataTypes.ReserveData memory r = pool.getReserveData(debt);
        uint256 actualDebt = (uint256(pos.scaledDebt) * uint256(r.borrowIndex)) / RAY;
        console.log(name, pair);
        console.log("  col=", uint256(pos.collateralAmount), "debt=", actualDebt);
    }
}
