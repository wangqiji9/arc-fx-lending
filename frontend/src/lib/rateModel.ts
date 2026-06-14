// ── Interest rate model ────────────────────────────────────────────────────
// SYNC WITH CONTRACT: These constants mirror the deployed LendingPool's
// InterestRateModel. If contract parameters change, update all ← SYNC lines.

const RAY = BigInt('1000000000000000000000000000') // 1e27

const SLOPE1          = BigInt('40000000000000000000000000')  // 4%  in RAY  ← SYNC
const SLOPE2          = BigInt('750000000000000000000000000') // 75% in RAY  ← SYNC
const KINK            = BigInt('800000000000000000000000000') // 80% in RAY  ← SYNC
const RESERVE_FACTOR  = 1000n                                 // bps = 10%   ← SYNC
const BPS             = 10000n

function computeBorrowRate(utilRay: bigint): bigint {
  if (utilRay <= KINK) {
    return (SLOPE1 * utilRay) / RAY
  }
  return SLOPE1 + (SLOPE2 * (utilRay - KINK)) / (RAY - KINK)
}

/**
 * Project supply rate after a hypothetical deposit/withdraw.
 * @param totalSupplied  current total lendable supply (in token units, scaled by decimals)
 * @param totalBorrowed  current total borrows (same units)
 * @param delta          positive = deposit, negative = withdraw
 * @returns projected supply rate in RAY, or 0n if pool would be empty
 */
export function projectSupplyRate(
  totalSupplied: bigint,
  totalBorrowed: bigint,
  delta: bigint,
): bigint {
  const newSupply = totalSupplied + delta
  if (newSupply <= 0n) return 0n

  const util = totalBorrowed * RAY / newSupply
  const u = util > RAY ? RAY : util

  const borrowRate = computeBorrowRate(u)
  return (borrowRate * u / RAY) * (BPS - RESERVE_FACTOR) / BPS
}
