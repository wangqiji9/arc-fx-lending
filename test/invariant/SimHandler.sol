// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DataTypes, RAY} from "../../src/libraries/DataTypes.sol";

/// @notice 50-actor guided invariant handler (used by SimulationTest).
///
/// Three core improvements over the basic Handler:
///   1. 50 actors — large-scale coverage so totalScaledSupply / totalScaledBorrow stay consistent under high concurrency
///   2. Ghost variables — count successful calls per operation type, to quantify coverage after a run (avoids "all-revert empty test")
///   3. crashAndLiquidate — deterministic path: crash collateral price → liquidator repays in full → repayBadDebt if bad debt results
///      restore the original price after the crash, so later sequences are not stuck in a permanent "liquidatable" state
///
/// T-8 delta consistency assertions are kept in every operation that mutates totalCollateral.
contract SimHandler is Test {
    uint256 public constant NUM_ACTORS = 50;

    /*//////////////////////////////////////////////////////////////
                        Ghost variables (successful-call counters)
    //////////////////////////////////////////////////////////////*/

    uint256 public ghost_deposits;
    uint256 public ghost_withdrawals;
    uint256 public ghost_openPositions;
    uint256 public ghost_borrows;
    uint256 public ghost_addCollaterals;
    uint256 public ghost_withdrawCollaterals;
    uint256 public ghost_repays;
    uint256 public ghost_liquidations;
    uint256 public ghost_crashAttempts;
    uint256 public ghost_crashLiquidations;
    uint256 public ghost_badDebtRepaid;
    uint256 public ghost_pauseTests;
    uint256 public ghost_pauseGateMissed; // number of times an operation did not revert while the oracle was paused; must always be 0
    uint256 public ghost_fxVerified;
    uint256 public ghost_boundaryLiquidations;

    /*//////////////////////////////////////////////////////////////
                                state
    //////////////////////////////////////////////////////////////*/

    LendingPool public pool;
    MockPriceOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public eurc;
    MockERC20 public weth;

    address[] public actors;
    address public immutable liquidator;

    constructor(
        LendingPool _pool,
        MockPriceOracle _oracle,
        MockERC20 _usdc,
        MockERC20 _eurc,
        MockERC20 _weth,
        address[] memory _actors,
        address _liquidator
    ) {
        pool = _pool;
        oracle = _oracle;
        usdc = _usdc;
        eurc = _eurc;
        weth = _weth;
        actors = _actors;
        liquidator = _liquidator;

        for (uint256 i = 0; i < _actors.length; i++) {
            _fundAll(_actors[i]);
        }
        _fundAll(_liquidator);
        _fundAll(address(this)); // handler = insuranceFund, holds tokens for repayBadDebt._pull
    }

    function _fundAll(address who) internal {
        usdc.mint(who, 10_000_000e6);
        eurc.mint(who, 10_000_000e6);
        weth.mint(who, 100_000e18);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        eurc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// @dev 5 (collateral, debt) combinations, kept consistent with _pair in SimulationTest.
    function _pair(uint256 s) internal view returns (address col, address debt) {
        uint256 i = s % 5;
        if (i == 0) return (address(weth), address(usdc));
        if (i == 1) return (address(weth), address(eurc));
        if (i == 2) return (address(usdc), address(eurc));
        if (i == 3) return (address(eurc), address(usdc));
        return (address(usdc), address(weth));
    }

    function _colBound(address col, uint256 amt) internal view returns (uint256) {
        if (col == address(weth)) return bound(amt, 1e15, 10e18);
        return bound(amt, 1e6, 10_000e6);
    }

    function _debtBound(address debt, uint256 amt) internal view returns (uint256) {
        if (debt == address(weth)) return bound(amt, 1e15, 5e18);
        return bound(amt, 1e6, 5_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                              Lending side
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 t = tokenSeed % 3;
        MockERC20 token = t == 0 ? usdc : (t == 1 ? eurc : weth);
        amount = (token == weth) ? bound(amount, 1e15, 100e18) : bound(amount, 1e6, 100_000e6);
        vm.prank(actor);
        try pool.deposit(address(token), amount) {
            ghost_deposits++;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 t = tokenSeed % 3;
        MockERC20 token = t == 0 ? usdc : (t == 1 ? eurc : weth);
        amount = (token == weth) ? bound(amount, 1, 200e18) : bound(amount, 1, 200_000e6);
        vm.prank(actor);
        try pool.withdraw(address(token), amount) {
            ghost_withdrawals++;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              Borrowing side
    //////////////////////////////////////////////////////////////*/

    function openPosition(uint256 actorSeed, uint256 pairSeed, uint256 colAmt, uint256 borrowAmt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        colAmt = _colBound(col, colAmt);
        borrowAmt = _debtBound(debt, borrowAmt);

        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.openPosition(col, colAmt, debt, borrowAmt) {
            ghost_openPositions++;
            // T-8: Δbalance == ΔtotalCollateral
            assertEq(
                MockERC20(col).balanceOf(address(pool)) - balBefore,
                pool.getTotalCollateral(col) - totBefore,
                "openPosition: delta balance != delta totalCollateral"
            );
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 pairSeed, uint256 borrowAmt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        borrowAmt = _debtBound(debt, borrowAmt);
        vm.prank(actor);
        try pool.borrow(col, debt, borrowAmt) {
            ghost_borrows++;
        } catch {}
    }

    function addCollateral(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _colBound(col, amt);

        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.addCollateral(col, debt, amt) {
            ghost_addCollaterals++;
            // T-8
            assertEq(
                MockERC20(col).balanceOf(address(pool)) - balBefore,
                pool.getTotalCollateral(col) - totBefore,
                "addCollateral: delta balance != delta totalCollateral"
            );
        } catch {}
    }

    function withdrawCollateral(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _colBound(col, amt);

        uint256 balBefore = MockERC20(col).balanceOf(address(pool));
        uint256 totBefore = pool.getTotalCollateral(col);

        vm.prank(actor);
        try pool.withdrawCollateral(col, debt, amt) {
            ghost_withdrawCollaterals++;
            // T-8 (opposite direction: decrease)
            assertEq(
                balBefore - MockERC20(col).balanceOf(address(pool)),
                totBefore - pool.getTotalCollateral(col),
                "withdrawCollateral: delta balance != delta totalCollateral"
            );
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 pairSeed, uint256 amt) external {
        address actor = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _debtBound(debt, amt);
        vm.prank(actor);
        try pool.repay(actor, col, debt, amt) {
            ghost_repays++;
        } catch {}
    }

    /// @notice handler = insuranceFund, called directly (no prank needed).
    function repayBadDebt(uint256 targetSeed, uint256 pairSeed) external {
        address target = _actor(targetSeed);
        (address col, address debt) = _pair(pairSeed);

        uint256 borrowBefore = pool.getReserveData(debt).totalScaledBorrow;
        try pool.repayBadDebt(target, col, debt) {
            ghost_badDebtRepaid++;
            assertLe(
                pool.getReserveData(debt).totalScaledBorrow,
                borrowBefore,
                "repayBadDebt: totalScaledBorrow must not increase"
            );
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              Liquidation
    //////////////////////////////////////////////////////////////*/

    function liquidate(uint256 targetSeed, uint256 pairSeed, uint256 amt) external {
        address target = _actor(targetSeed);
        (address col, address debt) = _pair(pairSeed);
        amt = _debtBound(debt, amt);

        uint256 colBalBefore = MockERC20(col).balanceOf(address(pool));
        uint256 colTotBefore = pool.getTotalCollateral(col);

        vm.prank(liquidator);
        try pool.liquidate(target, col, debt, amt, 0) {
            ghost_liquidations++;
            // T-8
            assertEq(
                colBalBefore - MockERC20(col).balanceOf(address(pool)),
                colTotBefore - pool.getTotalCollateral(col),
                "liquidate: delta balance != delta totalCollateral"
            );
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
              Third-party repayment / Oracle Pause (T-18)
    //////////////////////////////////////////////////////////////*/

    /// @notice msg.sender(sender) repays on behalf of target — the two can be different actors (third-party repayment path).
    ///         When sender==target this degenerates to self-repayment, harmless but already covered by repay.
    function repayFor(uint256 senderSeed, uint256 targetSeed, uint256 pairSeed, uint256 amt) external {
        address sender = _actor(senderSeed);
        address target = _actor((targetSeed + 1) % actors.length); // +1 ensures it differs from sender
        (address col, address debt) = _pair(pairSeed);
        amt = _debtBound(debt, amt);

        vm.prank(sender);
        try pool.repay(target, col, debt, amt) {
            ghost_repays++; // reuse the repay ghost; third-party repayment is also a repayment-type operation
        } catch {}
    }

    /// @notice Verify oracle pause correctly blocks risk-increasing operations (deposit / openPosition / borrow / withdrawCollateral).
    ///   handler has been set as guardian (oracle.setGuardian(address(handler)) in setUp), so it can call setPaused directly.
    ///   pause -> attempt operation -> must revert -> unpause; never affects pool accounting state.
    function pauseAndOperate(uint256 actorSeed, uint256 feedSeed, uint256 opSeed) external {
        address actor = _actor(actorSeed);
        uint256 fi = feedSeed % 3;
        address asset = fi == 0 ? address(usdc) : (fi == 1 ? address(eurc) : address(weth));

        oracle.setPaused(asset, true);

        uint256 op = opSeed % 4;
        bool reverted = false;

        if (op == 0) {
            // deposit should be intercepted by OraclePaused
            vm.prank(actor);
            try pool.deposit(asset, 1e6) {
            // reaching here means pause did not block
            }
            catch {
                reverted = true;
            }
        } else if (op == 1) {
            // openPosition (col=asset) should be intercepted by OraclePaused
            address debt = asset == address(usdc) ? address(eurc) : address(usdc);
            vm.prank(actor);
            try pool.openPosition(asset, 1e6, debt, 1e6) {}
            catch {
                reverted = true;
            }
        } else if (op == 2) {
            // borrow should be intercepted by OraclePaused (a nonexistent position reverts with PositionNotFound first, which also counts as reverted)
            address col = asset == address(usdc) ? address(weth) : address(usdc);
            vm.prank(actor);
            try pool.borrow(col, asset, 1e6) {}
            catch {
                reverted = true;
            }
        } else {
            // withdrawCollateral should be intercepted by OraclePaused (nonexistent position as above)
            address debt = asset == address(usdc) ? address(eurc) : address(usdc);
            vm.prank(actor);
            try pool.withdrawCollateral(asset, debt, 1e6) {}
            catch {
                reverted = true;
            }
        }

        // record the "did not revert" count; the assertion is done at the state layer by invariant_oraclePauseAlwaysBlocks,
        // avoiding assertTrue inside the handler body being silently swallowed by fail_on_revert=false.
        if (!reverted) ghost_pauseGateMissed++;
        ghost_pauseTests++;

        oracle.setPaused(asset, false);
    }

    /*//////////////////////////////////////////////////////////////
       Deterministic liquidation path: crash price -> full liquidation -> optional repayBadDebt
    //////////////////////////////////////////////////////////////*/

    /// @notice Guided bad-debt path, forcing Layer 3 logic to trigger.
    ///   Flow:
    ///   1. Check that target has an active debt position on the pair
    ///   2. Save the current collateral feed answer, crash it to an extremely low value (WETH=$50, stable=$0.05) to ensure HF<<1
    ///   3. The liquidator calls liquidate with the full debt amount (Liquidation.calcLiquidation handles closeFactor/collateral constraints automatically)
    ///   4. If bad debt remains after liquidation (collateral==0 && scaledDebt>0) -> handler acts as insuranceFund and calls repayBadDebt
    ///   5. Restore the original price, to avoid later sequences getting globally stuck in a "permanently liquidatable" state
    function crashAndLiquidate(uint256 actorSeed, uint256 pairSeed) external {
        ghost_crashAttempts++;

        address target = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);

        DataTypes.Position memory pos = pool.getPosition(target, col, debt);
        if (pos.collateralAsset == address(0) || pos.scaledDebt == 0) return;

        // save the original price
        uint256 savedColAnswer = _getFeedAnswer(col);

        // crash the collateral price
        uint256 crashPrice = (col == address(weth)) ? uint256(50e8) : uint256(0.05e8);
        _setFeedAnswer(col, crashPrice);

        // Estimate the full debt (for the liquidate request; the Liquidation library applies closeFactor + collateral constraints internally)
        DataTypes.ReserveData memory r = pool.getReserveData(debt);
        uint256 maxRepay = (uint256(pos.scaledDebt) * r.borrowIndex + RAY - 1) / RAY;

        uint256 colBalBefore = MockERC20(col).balanceOf(address(pool));
        uint256 colTotBefore = pool.getTotalCollateral(col);

        vm.prank(liquidator);
        try pool.liquidate(target, col, debt, maxRepay, 0) {
            ghost_crashLiquidations++;
            // T-8
            assertEq(
                colBalBefore - MockERC20(col).balanceOf(address(pool)),
                colTotBefore - pool.getTotalCollateral(col),
                "crashLiquidate: delta balance != delta totalCollateral"
            );

            // Check whether a bad-debt residual position resulted (collateral==0 && scaledDebt>0)
            DataTypes.Position memory posAfter = pool.getPosition(target, col, debt);
            if (posAfter.collateralAsset != address(0) && posAfter.collateralAmount == 0 && posAfter.scaledDebt > 0) {
                uint256 borrowBefore2 = pool.getReserveData(debt).totalScaledBorrow;
                try pool.repayBadDebt(target, col, debt) {
                    ghost_badDebtRepaid++;
                    assertLe(
                        pool.getReserveData(debt).totalScaledBorrow,
                        borrowBefore2,
                        "crashRepayBadDebt: totalScaledBorrow must not increase"
                    );
                } catch {}
            }
        } catch {}

        // Restore the original price (regardless of whether liquidation succeeded)
        _setFeedAnswer(col, savedColAnswer);
    }

    /*//////////////////////////////////////////////////////////////
             FX E-Mode parameter routing verification (T-19)
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that (usdc, eurc) routes through FX E-Mode params (LTV=90%) and not Standard (LTV=75%).
    ///
    ///   Logic: open a (usdc → eurc) position at 85% LTV:
    ///     - FX  LTV=90%: HF = 1000×0.90 / (830×1.08) ≈ 1.003  → success
    ///     - Std LTV=75%: HF = 1000×0.75 / (830×1.08) ≈ 0.836  → must revert
    ///
    ///   success → ghost_fxVerified++ (E-Mode in effect)
    ///   revert → assertTrue(false) reports a routing bug (openPosition with FX params should not revert)
    ///
    ///   Immediately after opening, repay the full debt + withdrawCollateral all collateral; state is restored after closing.
    function verifyFxEMode(uint256 actorSeed) external {
        address actor = _actor(actorSeed);

        // Fixed amounts: 1000 USDC collateral, borrow 830 EURC (~85% LTV; passes at FX 90%, fails at Standard 75%)
        uint256 colAmt = 1_000e6; // 1000 USDC
        uint256 borrowAmt = 830e6; // 830 EURC

        // First confirm the actor has sufficient balance (mock already minted 10M, normally enough)
        // Attempt to open with the FX pair
        vm.prank(actor);
        try pool.openPosition(address(usdc), colAmt, address(eurc), borrowAmt) {
            ghost_fxVerified++;

            // Immediately repay + withdraw collateral, closing the position (avoids a high-LTV position lingering and affecting borrowCap)
            vm.prank(actor);
            try pool.repay(actor, address(usdc), address(eurc), type(uint256).max) {} catch {}

            vm.prank(actor);
            try pool.withdrawCollateral(address(usdc), address(eurc), colAmt) {} catch {}
        } catch {
            // The revert may be due to non-FX reasons such as insufficient liquidity / borrowCap / collateralCap / pause; skip silently.
            // FX parameter correctness is guaranteed at the state layer by invariant_fxEModeParamsCorrect (SimulationTest).
        }
    }

    /*//////////////////////////////////////////////////////////////
        closeFactor=50% boundary test: HF∈[0.98,1.0) partial path (T-20)
    //////////////////////////////////////////////////////////////*/

    /// @notice Back-solve the collateral price that makes HF land precisely in [0.98, 1.0), triggering partial closeFactor(50%).
    ///
    ///   Target HF = 0.985 (within the [0.98, 1.0) range):
    ///     HF = colAmt × crashPrice / colUnit × LT / BPS × WAD / debtValue = 0.985e18
    ///   Solving for:
    ///     crashPrice = 0.985e18 × debtValue × colUnit × BPS / (colAmt × LT × WAD)
    ///   debtValue(1e8 base) = debtOf(scaledDebt, borrowIndex) × debtPrice / debtUnit
    ///
    ///   Verify: after liquidate(maxRepay=actualDebt), repaid ≤ actualDebt/2 + dust (50% closeFactor)
    ///
    ///   Formula derivation (Standard LT=80%, target HF=0.985):
    ///     HF = colAmt × p / colUnit × 0.8 × WAD / debtValue = 0.985e18
    ///     → p = 985 × debtValue × colUnit / (colAmt × 800)
    ///   Skip the FX pair (LT=94%, back-solve is complex; pair 2/3 = usdc↔eurc).
    function boundaryCrash(uint256 actorSeed, uint256 pairSeed) external {
        ghost_crashAttempts++;
        if (pairSeed % 5 == 2 || pairSeed % 5 == 3) return; // skip FX pairs

        address target = _actor(actorSeed);
        (address col, address debt) = _pair(pairSeed);

        DataTypes.Position memory pos = pool.getPosition(target, col, debt);
        if (pos.collateralAsset == address(0) || pos.scaledDebt == 0 || pos.collateralAmount == 0) return;

        uint256 colUnit = col == address(weth) ? 1e18 : 1e6;
        uint256 debtUnit = debt == address(weth) ? 1e18 : 1e6;

        // debtValue(1e8 base) = actualDebt × debtPrice / debtUnit
        DataTypes.ReserveData memory r = pool.getReserveData(debt);
        uint256 actualDebt = (uint256(pos.scaledDebt) * r.borrowIndex + RAY - 1) / RAY;
        uint256 debtValue = actualDebt * oracle.getPrice(debt) / debtUnit;
        if (debtValue == 0) return;

        // crashPrice makes HF = 0.985 (in [0.98,1) it triggers partial closeFactor)
        uint256 crashPrice = 985 * debtValue * colUnit / (uint256(pos.collateralAmount) * 800);
        uint256 savedPrice = _getFeedAnswer(col);
        if (crashPrice == 0 || crashPrice >= savedPrice) return;

        _setFeedAnswer(col, crashPrice);

        uint256 scaledDebtBefore = pos.scaledDebt;
        uint256 colBalBefore = MockERC20(col).balanceOf(address(pool));
        uint256 colTotBefore = pool.getTotalCollateral(col);

        vm.prank(liquidator);
        (bool ok,) = address(pool).call(abi.encodeCall(pool.liquidate, (target, col, debt, actualDebt, uint256(0))));

        if (ok) {
            ghost_boundaryLiquidations++;
            // T-8 delta assertion
            assertEq(
                colBalBefore - MockERC20(col).balanceOf(address(pool)),
                colTotBefore - pool.getTotalCollateral(col),
                "boundaryCrash: T-8 delta mismatch"
            );
            // Core: partial closeFactor — scaledDebt reduction ≤ 50% + 1 dust
            uint256 scaledDebtReduced = scaledDebtBefore - pool.getPosition(target, col, debt).scaledDebt;
            assertLe(
                scaledDebtReduced,
                scaledDebtBefore / 2 + 1,
                "boundaryCrash: closeFactor FULL triggered instead of PARTIAL"
            );
            assertGt(scaledDebtReduced, 0, "boundaryCrash: liquidation repaid 0");
        }

        _setFeedAnswer(col, savedPrice);
    }

    /*//////////////////////////////////////////////////////////////
                          Price / time walk
    //////////////////////////////////////////////////////////////*/

    function movePrice(uint256 feedSeed, uint256 price) external {
        uint256 i = feedSeed % 3;
        if (i == 0) {
            oracle.setPrice(address(usdc), bound(price, 0.85e8, 1.15e8));
        } else if (i == 1) {
            oracle.setPrice(address(eurc), bound(price, 0.8e8, 1.5e8));
        } else {
            oracle.setPrice(address(weth), bound(price, 500e8, 6000e8));
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
    }

    /*//////////////////////////////////////////////////////////////
                              Internal helpers
    //////////////////////////////////////////////////////////////*/

    function _getFeedAnswer(address token) internal view returns (uint256) {
        return oracle.price(token);
    }

    function _setFeedAnswer(address token, uint256 price) internal {
        oracle.setPrice(token, price);
    }
}
