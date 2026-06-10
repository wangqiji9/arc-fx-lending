// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {SimHandler} from "./SimHandler.sol";
import {DataTypes, RAY} from "../../src/libraries/DataTypes.sol";

/// @notice 50-actor large-scale invariant simulation test.
///
/// Handler = SimHandler, driving 13 operations:
///   Lending side (deposit/withdraw), Borrowing side (openPosition/borrow/addCollateral/withdrawCollateral/repay),
///   Liquidation (liquidate/repayBadDebt), guided crash (crashAndLiquidate), price/time walk (movePrice/warp).
///
/// Invariants (cf. state-transitions.md §Invariants + architecture.md §4):
///   1. supplyConsistency      — Σ scaledDeposits[a][actor] == totalScaledSupply (per asset)
///   2. borrowConsistency      — Σ position.scaledDebt for debt==a == totalScaledBorrow (per asset)
///   3. collateralConsistency  — Σ position.collateralAmount for col==a == totalCollateral[a] (per asset)
///   4. solvency_collateral    — balanceOf(pool,a) >= totalCollateral[a] (physical balance covers locked collateral)
///   5. supplierSolvency       — cash + borrowed >= supplied + collateral (lender solvency)
///   6. indexOrdering          — borrowIndex >= liquidityIndex >= RAY (index monotonically increasing)
///   7. fxEModeParamsCorrect   — FX category (USD↔EUR) params correct and enabled (T-19)
///   8. oraclePauseAlwaysBlocks— risk-increasing operations during oracle pause must revert, ghost count is 0 (T-18)
///   9. noZombiePositions      — no zombie position with collateralAsset≠0 but col=0 AND debt=0 (T-17)
///  10. userPositionKeysConsistency — key set and positions mapping are bidirectionally consistent (T-17)
///
/// Validity notes (avoiding ineffective revert tests):
///   - All operations use try/catch; an illegal revert does not violate the invariants.
///   - Ghost variables record success counts; after a run, inspect Handler state with --verbosity to quantitatively verify coverage.
///   - crashAndLiquidate deterministically triggers liquidation/bad debt, ensuring invariants 2/3 are stress-tested on the Layer 3 path.
///   - supplyConsistency enumerates all 50 actors, never missing any lender's scaledDeposit.
contract SimulationTest is BaseTest {
    SimHandler internal handler;

    address[] internal actorList;
    address[3] internal assetList;

    uint256 constant NUM_ACTORS = 50;

    function setUp() public override {
        super.setUp();

        // generate 50 deterministic actor addresses
        actorList = new address[](NUM_ACTORS);
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            actorList[i] = makeAddr(string.concat("sim_actor_", vm.toString(i)));
        }

        assetList = [address(usdc), address(eurc), address(weth)];

        handler = new SimHandler(
            pool,
            oracle,
            usdc,
            eurc,
            weth,
            actorList,
            makeAddr("sim_liquidator")
        );

        // handler acts as insuranceFund so it can call repayBadDebt
        pool.setInsuranceFund(address(handler));

        // handler acts as guardian so it can call oracle.setPaused (needed by T-18 pauseAndOperate)
        oracle.setGuardian(address(handler));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                     §Invariants 1/2/3: total consistency
    //////////////////////////////////////////////////////////////*/

    /// @notice sum(scaledDeposits[a][actor] for all 50 actors) == totalScaledSupply
    /// @dev Enumerate all actors, ensuring any deposit/withdraw call in SimHandler is covered.
    function invariant_supplyConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                sum += pool.getScaledDeposit(a, actorList[j]);
            }
            assertEq(sum, pool.getReserveData(a).totalScaledSupply, "supply sum mismatch");
        }
    }

    /// @notice sum(position.scaledDebt for debt==a, 50 actors × 5 pairs) == totalScaledBorrow
    function invariant_borrowConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                for (uint256 p = 0; p < 5; p++) {
                    (address col, address debt) = _pair(p);
                    if (debt != a) continue;
                    sum += pool.getPosition(actorList[j], col, debt).scaledDebt;
                }
            }
            assertEq(sum, pool.getReserveData(a).totalScaledBorrow, "borrow sum mismatch");
        }
    }

    /// @notice sum(position.collateralAmount for col==a, 50 actors × 5 pairs) == totalCollateral[a]
    function invariant_collateralConsistency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            uint256 sum;
            for (uint256 j = 0; j < actorList.length; j++) {
                for (uint256 p = 0; p < 5; p++) {
                    (address col, address debt) = _pair(p);
                    if (col != a) continue;
                    sum += pool.getPosition(actorList[j], col, debt).collateralAmount;
                }
            }
            assertEq(sum, pool.getTotalCollateral(a), "collateral sum mismatch");
        }
    }

    /*//////////////////////////////////////////////////////////////
               §Invariants 4/5/6: solvency / balance coverage / index
    //////////////////////////////////////////////////////////////*/

    /// @notice balanceOf(pool,a) >= totalCollateral[a] (locked collateral is never lent out / misappropriated)
    function invariant_solvency_collateralBacked() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            assertGe(
                IERC20Min(a).balanceOf(address(pool)),
                pool.getTotalCollateral(a),
                "balance < totalCollateral"
            );
        }
    }

    /// @notice Supplier solvency: cash + borrowed >= supplied + collateral
    /// @dev When reserveFactor > 0, borrowIndex > liquidityIndex, and the difference stays in the pool as cash (protocol reserve),
    ///      so borrowIndex grows faster than liquidityIndex, i.e. borrowed > supplied (normal behavior, not a bug).
    ///      The supplier's claim is jointly covered by cash + borrowed, and always holds.
    function invariant_supplierSolvency() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            address a = assetList[i];
            DataTypes.ReserveData memory r = pool.getReserveData(a);
            uint256 supplied = (uint256(r.totalScaledSupply) * r.liquidityIndex) / RAY;
            uint256 borrowed = (uint256(r.totalScaledBorrow) * r.borrowIndex) / RAY;
            uint256 cash = IERC20Min(a).balanceOf(address(pool));
            uint256 collateral = pool.getTotalCollateral(a);
            assertGe(cash + borrowed, supplied + collateral, "supplier claims not backed");
        }
    }

    /// @notice borrowIndex >= liquidityIndex >= RAY (index increases monotonically, never decreases)
    function invariant_indexOrdering() public view {
        for (uint256 i = 0; i < assetList.length; i++) {
            DataTypes.ReserveData memory r = pool.getReserveData(assetList[i]);
            assertGe(r.liquidityIndex, RAY, "liquidityIndex < RAY");
            assertGe(r.borrowIndex, r.liquidityIndex, "borrowIndex < liquidityIndex");
        }
    }

    /*//////////////////////////////////////////////////////////////
             §Invariant 7: FX E-Mode parameter correctness (T-19)
    //////////////////////////////////////////////////////////////*/

    /// @notice FX category (USD↔EUR) is configured correctly and enabled; resolveParams routing does not degrade to Standard params.
    /// @dev The verifyFxEMode handler only tracks behavioral coverage (ghost_fxVerified); parameter correctness is guaranteed here.
    ///      If configureFxCategory was never called or the params were tampered with, this invariant fails immediately.
    function invariant_fxEModeParamsCorrect() public view {
        DataTypes.FxCategory memory fx = pool.getFxCategory(USD, EUR);
        assertTrue(fx.enabled, "FX E-Mode: category not enabled");
        assertEq(fx.ltv, 9000, "FX E-Mode: LTV should be 9000 bps");
        assertEq(fx.liquidationThreshold, 9400, "FX E-Mode: LT should be 9400 bps");
        assertEq(fx.liquidationBonus, 250, "FX E-Mode: bonus should be 250 bps");
    }

    /*//////////////////////////////////////////////////////////////
             §Invariant 8: Oracle Pause gating (T-18)
    //////////////////////////////////////////////////////////////*/

    /// @notice Risk-increasing operations during an oracle pause must all revert.
    /// @dev The pauseAndOperate handler uses ghost_pauseGateMissed to count the "slipped-through" cases; this invariant requires that count to be 0.
    ///      Reason for not asserting inside the handler body: a failed assertTrue makes the handler revert,
    ///      and fail_on_revert=false silently swallows that revert, rendering the assertion useless.
    function invariant_oraclePauseAlwaysBlocks() public view {
        assertEq(
            handler.ghost_pauseGateMissed(),
            0,
            "oracle pause gate: operation succeeded while oracle was paused"
        );
    }

    /*//////////////////////////////////////////////////////////////
             §Invariants 9/10: behavioral correctness (_closeIfEmpty + key set)
    //////////////////////////////////////////////////////////////*/

    /// @notice No zombie position exists: collateralAsset≠0 but col=0 AND debt=0 (_closeIfEmpty missed the delete).
    /// @dev collateralAsset is the flag that a position exists; on close, delete positions[key] zeroes out every field.
    ///      If the delete is missed, collateralAsset stays a non-zero address while collateral/debt have been reduced to 0 normally.
    function invariant_noZombiePositions() public view {
        for (uint256 j = 0; j < actorList.length; j++) {
            for (uint256 p = 0; p < 5; p++) {
                (address col, address debt) = _pair(p);
                DataTypes.Position memory pos = pool.getPosition(actorList[j], col, debt);
                if (pos.collateralAsset != address(0)) {
                    assertTrue(
                        pos.collateralAmount > 0 || pos.scaledDebt > 0,
                        "zombie position: collateralAsset set but col=0 and debt=0"
                    );
                }
            }
        }
    }

    /// @notice userPositionKeys and the positions mapping are bidirectionally consistent:
    ///   ① every key in the key set → positions[key] genuinely exists (no ghost keys)
    ///   ② every genuinely existing position → its key is in the set (no missing registration)
    function invariant_userPositionKeysConsistency() public view {
        for (uint256 j = 0; j < actorList.length; j++) {
            address actor = actorList[j];
            bytes32[] memory keys = pool.getUserPositionKeys(actor);

            // ① every key in the set must point to a non-empty position
            for (uint256 k = 0; k < keys.length; k++) {
                DataTypes.Position memory pos = pool.getPosition(keys[k]);
                assertTrue(
                    pos.collateralAsset != address(0),
                    "ghost key: key in userPositionKeys but position deleted"
                );
            }

            // ② every non-empty position's key must be in the set
            for (uint256 p = 0; p < 5; p++) {
                (address col, address debt) = _pair(p);
                DataTypes.Position memory pos = pool.getPosition(actor, col, debt);
                if (pos.collateralAsset == address(0)) continue;

                bytes32 expected = pool.positionKey(actor, col, debt);
                bool found = false;
                for (uint256 k = 0; k < keys.length; k++) {
                    if (keys[k] == expected) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "missing key: open position not in userPositionKeys");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev 5 (collateral, debt) combinations, kept consistent with SimHandler._pair.
    function _pair(uint256 p) internal view returns (address col, address debt) {
        if (p == 0) return (address(weth), address(usdc));
        if (p == 1) return (address(weth), address(eurc));
        if (p == 2) return (address(usdc), address(eurc));
        if (p == 3) return (address(eurc), address(usdc));
        return (address(usdc), address(weth));
    }
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}
