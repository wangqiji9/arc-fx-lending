# Arc FX-Lending

A lending protocol with dual-mode risk: **Standard mode** (crypto collateral) and **FX E-Mode** (same-currency stablecoin pairs with tighter parameters and lower liquidation bonus).

Built in Solidity 0.8.24 with Foundry. Targets the Arc testnet.

---

## Overview

### Roles

| Role | Actions |
|------|---------|
| **Lender** | `deposit` / `withdraw` — supplies liquidity, earns scaled interest |
| **Borrower** | `openPosition` / `borrow` / `addCollateral` / `withdrawCollateral` / `repay` — isolated positions per (collateral, debt) pair |

### Standard vs FX E-Mode

Each (collateral, debt) position uses either Standard or FX risk parameters, determined automatically by the currency codes of the two assets:

- **Standard** — e.g. WETH → USDC. LTV/LT/bonus from `AssetConfig` (e.g. 75%/80%/7.5%).
- **FX E-Mode** — e.g. USDC → EURC (both USD↔EUR). Tighter parameters from `FxCategory` (e.g. 90%/94%/2.5%).

### Liquidation

Close factor is dynamic: 50% partial liquidation above an HF threshold, 100% full liquidation below it. The threshold differs by mode — `0.98` in Standard mode, `0.983` in FX E-Mode (the tighter LT 94% + 2.5% bonus needs a higher threshold so a single 50% liquidation still restores HF > 1). If collateral is fully exhausted before debt is cleared, the residual (bad debt) is marked for Layer 3 recapitalization via `repayBadDebt`.

### Interest

Utilization-based rate model (RateEngine). Interest accrues via ray-math indices (`borrowIndex`, `liquidityIndex`). A `reserveFactor` splits borrow interest between lenders and protocol.

---

## Architecture

```
LendingPool (entry point)
├── PoolStorage          — all state (reserves, positions, scaledDeposits, totalCollateral)
├── RateEngine           — index accrual, utilization rate
├── RiskEngine           — health factor, LTV check
├── Liquidation          — close factor, seize amount, back-calculation
├── Keys                 — position key (keccak256 of owner/collateral/debt)
└── PriceOracle          — Chainlink wrapper: staleness check, decimal normalization to 1e8, guardian pause
```

All token transfers are in `LendingPool`. CEI order is strictly observed; risk-increasing operations (`openPosition`, `borrow`, `withdrawCollateral`) use effect-then-verify.

### Oracle pause gate

Risk-increasing operations and liquidation are blocked when the oracle is paused for either asset. Untrustworthy prices must not be used to seize collateral. Lender `withdraw` is not affected — liquidity exit remains available during emergencies.

| Operation | Blocked when paused? |
|-----------|----------------------|
| `openPosition`, `borrow`, `withdrawCollateral` | Yes |
| `liquidate` | Yes |
| `deposit`, `repay`, `addCollateral` | No |
| `withdraw` (lender) | No |

---

## Setup

**Requirements:** [Foundry](https://book.getfoundry.sh/getting-started/installation)

```shell
git clone <repo>
cd arc-fx-lending
forge install
forge build
```

---

## Testing

```shell
# Unit + integration tests
forge test --no-match-test "invariant"

# Invariant suite (slower)
forge test --match-test "invariant"

# All tests
forge test
```

Test coverage includes:

- Standard and FX E-Mode liquidation paths (partial, full, collateral-constrained)
- Interest-driven liquidation (high utilization, time warp)
- Close factor boundary (Standard 0.98, FX 0.983)
- Fee-on-transfer rejection
- PriceOracle: staleness, invalid price, decimal normalization, guardian authorization
- Multi-position isolation
- Oracle pause gate (`withdrawCollateral` blocked, `liquidate` blocked, lender `withdraw` allowed)
- WETH borrowing (Standard mode debt asset)
- LTV vs LT gating (`openPosition`/`borrow` use LTV; `withdrawCollateral` uses LT)
- Fuzz: LTV enforcement, deposit-withdraw roundtrip, price-driven liquidation, addCollateral monotonicity
- Invariants: solvency (`balanceOf(pool) ≥ totalCollateral`), delta consistency per operation

---

## License

MIT
