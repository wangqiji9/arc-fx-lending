// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Nuclear reset: repay all debt → withdraw all collateral → withdraw all deposits → reseed small.
contract Reset is Script {
    LendingPool pool;
    MockERC20 usdc;
    MockERC20 eurc;
    MockERC20 weth;

    uint256 pkDeployer; uint256 pkAlice; uint256 pkBob; uint256 pkCharlie;
    address deployer;   address alice;   address bob;   address charlie;

    uint256 constant MAXU128 = type(uint128).max;

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

        // ── 1. Mint enough tokens to each account to repay all debt ──────
        // Conservative: mint 10x liveDebt to every account so repay always succeeds.
        vm.startBroadcast(pkDeployer);
        usdc.mint(alice,    2000e6);
        eurc.mint(bob,      2000e6);
        usdc.mint(charlie,  2000e6);
        usdc.mint(deployer, 2000e6);
        vm.stopBroadcast();

        // ── 2. Each account repays their own position ────────────────────
        _repayAndExitCollateral(pkAlice,   alice,   address(weth), address(usdc), usdc);
        _repayAndExitCollateral(pkBob,     bob,     address(usdc), address(eurc), eurc);
        _repayAndExitCollateral(pkCharlie, charlie, address(eurc), address(usdc), usdc);
        _repayAndExitCollateral(pkDeployer,deployer,address(weth), address(usdc), usdc);

        // ── 3. Withdraw all lender deposits (debt is zero now → full liquidity) ──
        _withdrawAll(pkAlice,    alice,    address(usdc), usdc);
        _withdrawAll(pkAlice,    alice,    address(weth), weth);
        _withdrawAll(pkBob,      bob,      address(eurc), eurc);
        _withdrawAll(pkBob,      bob,      address(weth), weth);
        _withdrawAll(pkCharlie,  charlie,  address(usdc), usdc);
        _withdrawAll(pkCharlie,  charlie,  address(eurc), eurc);
        _withdrawAll(pkDeployer, deployer, address(usdc), usdc);
        _withdrawAll(pkDeployer, deployer, address(eurc), eurc);
        _withdrawAll(pkDeployer, deployer, address(weth), weth);

        console.log("All positions closed and deposits withdrawn.");

        // ── 4. Re-seed: small deposits, ~65% utilization ────────────────
        // Target deposits:
        //   Alice    400 USDC
        //   Bob      0.1 WETH  (~$300)
        //   Charlie  500 EURC  (~$540)
        //   Deployer 600 USDC
        //   Total USDC supply = 1000, WETH supply = 0.1, EURC supply = 500
        //
        // Borrow positions (~65% util):
        //   Alice   0.08 WETH col ($240) → 150 USDC  [Standard, HF=240*0.8/150=1.28]
        //   Bob     350 USDC col  ($350) → 210 EURC  [FX E-Mode, HF=350*0.94/(210*1.08)=1.45]
        //   Charlie 400 EURC col  ($432) → 260 USDC  [FX E-Mode, HF=432*0.94/260=1.56]
        //   Deployer 0.06 WETH col($180)→ 120 USDC   [Standard, HF=180*0.8/120=1.20]
        //   USDC borrowed: 150+260+120=530  (530/1000=53%)
        //   EURC borrowed: 210             (210/500=42%)

        vm.startBroadcast(pkDeployer);
        usdc.mint(alice,    500e6);
        weth.mint(bob,      0.15e18);
        eurc.mint(charlie,  600e6);
        usdc.mint(deployer, 800e6);
        // collateral buffers
        weth.mint(alice,    0.12e18);
        usdc.mint(bob,      400e6);
        eurc.mint(charlie,  450e6);
        weth.mint(deployer, 0.09e18);
        vm.stopBroadcast();

        // deposits
        vm.startBroadcast(pkAlice);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 400e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkBob);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 0.1e18);
        vm.stopBroadcast();

        vm.startBroadcast(pkCharlie);
        eurc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(eurc), 500e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkDeployer);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 600e6);
        vm.stopBroadcast();

        // borrow positions
        vm.startBroadcast(pkAlice);
        pool.openPosition(address(weth), 0.08e18, address(usdc), 150e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkBob);
        pool.openPosition(address(usdc), 350e6, address(eurc), 210e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkCharlie);
        pool.openPosition(address(eurc), 400e6, address(usdc), 260e6);
        vm.stopBroadcast();

        vm.startBroadcast(pkDeployer);
        pool.openPosition(address(weth), 0.06e18, address(usdc), 120e6);
        vm.stopBroadcast();

        console.log("Re-seeded. Final state:");
        _logReserve(address(usdc), "USDC");
        _logReserve(address(eurc), "EURC");
        _logReserve(address(weth), "WETH");
    }

    function _repayAndExitCollateral(uint256 pk, address account, address col, address debt, MockERC20 debtToken) internal {
        bytes32 key = pool.positionKey(account, col, debt);
        DataTypes.Position memory pos = pool.getPosition(key);
        if (pos.collateralAsset == address(0) || pos.scaledDebt == 0) return;

        vm.startBroadcast(pk);
        debtToken.approve(address(pool), type(uint256).max);
        pool.repay(account, col, debt, MAXU128);
        // collateral freed — withdraw it all
        uint256 colAmt = pool.getPosition(key).collateralAmount;
        if (colAmt > 0) pool.withdrawCollateral(col, debt, colAmt);
        vm.stopBroadcast();
        console.log("repaid+exited", account);
    }

    function _withdrawAll(uint256 pk, address account, address asset, MockERC20) internal {
        uint256 scaled = pool.getScaledDeposit(asset, account);
        if (scaled == 0) return;
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 value = (scaled * uint256(r.liquidityIndex)) / RAY;
        if (value == 0) return;
        vm.startBroadcast(pk);
        pool.withdraw(asset, value);
        vm.stopBroadcast();
        console.log("withdrawn", account, value);
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 sup = (uint256(r.totalScaledSupply) * uint256(r.liquidityIndex)) / RAY;
        uint256 bor = (uint256(r.totalScaledBorrow) * uint256(r.borrowIndex))    / RAY;
        console.log(name, sup, bor);
    }
}
