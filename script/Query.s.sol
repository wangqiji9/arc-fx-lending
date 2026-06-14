// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DataTypes, RAY} from "../src/libraries/DataTypes.sol";

contract Query is Script {
    LendingPool constant pool = LendingPool(0xB574Eb2FD1101A75070Cda9673a6dB207581C467);
    address constant USDC     = 0xe5F8C0bD7Eda98F24f0B5002Fa485D473FE7E7Eb;
    address constant EURC     = 0x254a2627EB0e2e3ded4CB2225AFb8815f05e04e9;
    address constant WETH     = 0xCDeA155469985F1E6910bbC53278Cb2008bff207;
    address constant DEPLOYER = 0xCa14e37C862465677caA064c20BDBB6673F6FE48;
    address constant ALICE    = 0xCBb3b40109E849a2cD1531258CE1797Fa9ECA7e7;
    address constant BOB      = 0xE52C9AA4d90C9C1050228DC08E6c336da64251AF;
    address constant CHARLIE  = 0x2968871b9780B38FFcf2221653ABB09aD1038552;

    function run() external view {
        console.log("===== Pool Reserve State =====");
        _logReserve(USDC, "USDC", 6);
        _logReserve(EURC, "EURC", 6);
        _logReserve(WETH, "WETH", 18);

        console.log("===== User Deposits =====");
        _logDeposit(DEPLOYER, USDC, "USDC", 6,  "Deployer");
        _logDeposit(DEPLOYER, EURC, "EURC", 6,  "Deployer");
        _logDeposit(DEPLOYER, WETH, "WETH", 18, "Deployer");
        _logDeposit(ALICE,    WETH, "WETH", 18, "Alice");
        _logDeposit(BOB,      EURC, "EURC", 6,  "Bob");
        _logDeposit(CHARLIE,  WETH, "WETH", 18, "Charlie");

        console.log("===== Borrow Positions =====");
        _logPos(ALICE,   EURC, USDC, "Alice  EURC->USDC");
        _logPos(BOB,     WETH, USDC, "Bob    WETH->USDC");
        _logPos(CHARLIE, USDC, EURC, "Charlie USDC->EURC");
    }

    function _logReserve(address asset, string memory name, uint8) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
        uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
        console.log("  %s  supplied=%d  borrowed=%d  (raw)", name, supplied, borrowed);
    }

    function _logDeposit(address user, address asset, string memory aname, uint8, string memory uname) internal view {
        DataTypes.ReserveData memory r = pool.getReserveData(asset);
        uint256 scaled = pool.getScaledDeposit(asset, user);
        if (scaled == 0) return;
        uint256 actual = (scaled * r.liquidityIndex) / RAY;
        console.log("  %s  %s  deposit=%d (raw)", uname, aname, actual);
    }

    function _logPos(address user, address col, address debt, string memory tag) internal view {
        try pool.getPosition(user, col, debt) returns (DataTypes.Position memory p) {
            if (p.collateralAsset == address(0)) { console.log("  %s: closed", tag); return; }
            DataTypes.ReserveData memory dr = pool.getReserveData(debt);
            uint256 debtAmt = (uint256(p.scaledDebt) * dr.borrowIndex) / RAY;
            console.log("  %s: col=%d  debt=%d (raw)", tag, p.collateralAmount, debtAmt);
            uint256 hf = pool.getHealthFactor(user, col, debt);
            console.log("    HF=%d (1e18=1.0)", hf);
        } catch {
            console.log("  %s: no position", tag);
        }
    }
}
