// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Multi-actor interaction test against the deployed system on Anvil.
/// @dev forge script script/Interact.s.sol --rpc-url http://localhost:8545 --broadcast -vv
contract Interact is Script {
    // Deployed addresses from broadcast/Deploy.s.sol/31337/run-latest.json
    LendingPool    constant pool     = LendingPool    (0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e);
    MockPriceOracle constant oracle  = MockPriceOracle(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    MockERC20      constant usdc     = MockERC20      (0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0);
    MockERC20      constant eurc     = MockERC20      (0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9);
    MockERC20      constant weth     = MockERC20      (0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9);

    uint256 constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PK_ALICE    = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK_BOB      = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK_CHARLIE  = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant PK_DAVE     = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    address alice;
    address bob;
    address charlie;
    address dave;
    address deployer;

    function run() external {
        deployer = vm.addr(PK_DEPLOYER);
        alice    = vm.addr(PK_ALICE);
        bob      = vm.addr(PK_BOB);
        charlie  = vm.addr(PK_CHARLIE);
        dave     = vm.addr(PK_DAVE);

        console.log("=== arc-fx-lending interaction test ===");
        console.log("alice   :", alice);
        console.log("bob     :", bob);
        console.log("charlie :", charlie);
        console.log("dave    :", dave);

        _scenarioA_normalOps();
        _scenarioB_liquidation();
        _scenarioC_badDebt();
        _scenarioD_fxLiquidation();

        console.log("[ALL DONE] no unexpected reverts");
    }

    // ─────────────────────────────────────────────────────────────
    // A. Normal operations
    // ─────────────────────────────────────────────────────────────

    function _scenarioA_normalOps() internal {
        console.log("--- Scenario A: normal ops ---");

        vm.startBroadcast(PK_ALICE);
        usdc.mint(alice, 50_000e6);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 50_000e6);
        vm.stopBroadcast();
        console.log("[A1] alice deposited 50,000 USDC");

        vm.startBroadcast(PK_BOB);
        eurc.mint(bob, 30_000e6);
        usdc.mint(bob, 20_000e6);
        eurc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(eurc), 30_000e6);
        vm.stopBroadcast();
        console.log("[A2] bob deposited 30,000 EURC");

        vm.startBroadcast(PK_CHARLIE);
        weth.mint(charlie, 23e18);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 20e18);
        vm.stopBroadcast();
        console.log("[A3] charlie deposited 20 WETH");

        // alice: 5 WETH col, borrow 10,000 USDC (LTV=75%, $15k col -> $11.25k max)
        vm.startBroadcast(PK_ALICE);
        weth.mint(alice, 5e18);
        pool.openPosition(address(weth), 5e18, address(usdc), 10_000e6);
        vm.stopBroadcast();
        _logHF(alice, address(weth), address(usdc), "A4-alice-WETH/USDC");

        // bob: FX E-Mode, 20,000 USDC col, borrow 16,500 EURC (LTV=90%)
        // maxBorrow = 20000 * 0.90 / 1.08 = 16,666 EURC -> 16,500 OK
        vm.startBroadcast(PK_BOB);
        pool.openPosition(address(usdc), 20_000e6, address(eurc), 16_500e6);
        vm.stopBroadcast();
        _logHF(bob, address(usdc), address(eurc), "A5-bob-USDC/EURC-FX");

        // charlie: 2 WETH col, borrow 2,000 USDC; then addCollateral 1 WETH
        vm.startBroadcast(PK_CHARLIE);
        pool.openPosition(address(weth), 2e18, address(usdc), 2_000e6);
        pool.addCollateral(address(weth), address(usdc), 1e18);
        vm.stopBroadcast();
        _logHF(charlie, address(weth), address(usdc), "A6-charlie-addCollateral");

        // charlie repays 1,000 USDC partial
        vm.startBroadcast(PK_CHARLIE);
        pool.repay(charlie, address(weth), address(usdc), 1_000e6);
        vm.stopBroadcast();
        _logHF(charlie, address(weth), address(usdc), "A7-charlie-repay1000");

        // alice withdraws 10,000 USDC from deposit
        vm.startBroadcast(PK_ALICE);
        pool.withdraw(address(usdc), 10_000e6);
        vm.stopBroadcast();
        console.log("[A8] alice withdrew 10,000 USDC");

        _logReserve(address(usdc), "USDC");
        _logReserve(address(weth), "WETH");
    }

    // ─────────────────────────────────────────────────────────────
    // B. ETH crash -> liquidate alice (HF < 1.0, > 0.98 -> 50% CF)
    // ─────────────────────────────────────────────────────────────

    function _scenarioB_liquidation() internal {
        console.log("--- Scenario B: ETH crash -> liquidate alice ---");

        // ETH $3000 -> $1800: alice HF = 5*1800*0.8/10000 = 0.72 -> liquidatable
        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(weth), 1800e8);
        vm.stopBroadcast();
        console.log("[B1] ETH -> $1800");
        _logHF(alice, address(weth), address(usdc), "B1-alice");

        vm.startBroadcast(PK_DAVE);
        usdc.mint(dave, 10_000e6);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        pool.liquidate(alice, address(weth), address(usdc), 10_000e6, 0);
        vm.stopBroadcast();
        console.log("[B2] dave liquidated alice (partial/full per closeFactor)");
        _logHF(alice, address(weth), address(usdc), "B2-alice-post-liq");

        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(weth), 3000e8);
        vm.stopBroadcast();
        console.log("[B3] ETH restored $3000");
    }

    // ─────────────────────────────────────────────────────────────
    // C. Extreme crash -> bad debt -> repayBadDebt
    // ─────────────────────────────────────────────────────────────

    function _scenarioC_badDebt() internal {
        console.log("--- Scenario C: extreme crash -> bad debt ---");

        // dave opens WETH/USDC: 1 WETH col, 2000 USDC debt
        vm.startBroadcast(PK_DAVE);
        weth.mint(dave, 1e18);
        weth.approve(address(pool), type(uint256).max);
        pool.openPosition(address(weth), 1e18, address(usdc), 2_000e6);
        vm.stopBroadcast();
        _logHF(dave, address(weth), address(usdc), "C1-dave-open");

        // ETH $50: col=$50, debt=$2000 -> severe bad debt
        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(weth), 50e8);
        vm.stopBroadcast();
        console.log("[C2] ETH -> $50");
        _logHF(dave, address(weth), address(usdc), "C2-dave");

        // Liquidate: seizes all collateral ($50), back-calcs repay (~46.5 USDC)
        // Remaining debt ~1953 USDC = bad debt
        vm.startBroadcast(PK_DEPLOYER);
        usdc.mint(deployer, 2_100e6); // cover liquidation repay + bad debt (~2000 USDC)
        pool.liquidate(dave, address(weth), address(usdc), type(uint256).max, 0);
        vm.stopBroadcast();
        console.log("[C3] liquidated dave (expects bad debt residual)");

        DataTypes.Position memory pos = pool.getPosition(dave, address(weth), address(usdc));
        if (pos.scaledDebt > 0) {
            console.log("[C4] bad debt confirmed: scaledDebt remaining");
            vm.startBroadcast(PK_DEPLOYER);
            pool.repayBadDebt(dave, address(weth), address(usdc));
            vm.stopBroadcast();
            console.log("[C5] repayBadDebt OK");
        } else {
            console.log("[C4] no bad debt residual");
        }

        pos = pool.getPosition(dave, address(weth), address(usdc));
        require(pos.collateralAsset == address(0), "C_FAIL: position not closed");
        console.log("[C6] position closed OK");

        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(weth), 3000e8);
        vm.stopBroadcast();
    }

    // ─────────────────────────────────────────────────────────────
    // D. EURC appreciates -> bob FX position liquidated
    // ─────────────────────────────────────────────────────────────

    function _scenarioD_fxLiquidation() internal {
        console.log("--- Scenario D: EURC appreciate -> liquidate bob FX ---");

        // bob: 20,000 USDC col, 16,500 EURC debt
        // FX LT = 94%; HF = 20000*0.94 / (16500*1.35) = 18800/22275 = 0.844 -> liquidatable
        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(eurc), 135000000); // $1.35
        vm.stopBroadcast();
        console.log("[D1] EURC -> $1.35");
        _logHF(bob, address(usdc), address(eurc), "D1-bob");

        vm.startBroadcast(PK_DAVE);
        eurc.mint(dave, 20_000e6);
        pool.liquidate(bob, address(usdc), address(eurc), type(uint256).max, 0);
        vm.stopBroadcast();
        console.log("[D2] dave liquidated bob FX position");
        _logHF(bob, address(usdc), address(eurc), "D2-bob-post-liq");

        vm.startBroadcast(PK_DEPLOYER);
        oracle.setPrice(address(eurc), 108000000); // restore $1.08
        vm.stopBroadcast();

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
            console.log("[HF] %s = %d (WAD, 1e18=1.0)", tag, hf);
        } catch {
            console.log("[HF] %s -> no position / no debt", tag);
        }
    }

    function _logReserve(address asset, string memory name) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex)   / RAY;
        uint256 cash     = asset == address(usdc) ? usdc.balanceOf(address(pool))
                         : asset == address(eurc) ? eurc.balanceOf(address(pool))
                         : weth.balanceOf(address(pool));
        console.log("[RES] %s supplied=%d borrowed=%d", name, supplied, borrowed);
        console.log("      cash=%d", cash);
    }
}
