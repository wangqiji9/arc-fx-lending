// Precision constants matching the protocol
const RAY = BigInt('1000000000000000000000000000') // 1e27
const WAD = BigInt('1000000000000000000')          // 1e18
const BPS = BigInt('10000')                         // 1e4

// RAY → annual percentage (e.g. 0.05 = 5%)
export function rayToApy(ray: bigint): number {
  return Number(ray) / Number(RAY)
}

// RAY → formatted APY string (e.g. "5.23%")
export function formatApy(ray: bigint): string {
  const pct = rayToApy(ray) * 100
  if (pct < 0.01) return '< 0.01%'
  return pct.toFixed(2) + '%'
}

// WAD health factor → display number (e.g. 1.25)
export function wadToHf(wad: bigint): number {
  if (wad === BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff') ||
      wad > BigInt('1000') * WAD) return Infinity
  return Number(wad) / Number(WAD)
}

export function formatHf(wad: bigint): string {
  const hf = wadToHf(wad)
  if (!isFinite(hf)) return '∞'
  return hf.toFixed(2)
}

// BPS → percentage number (7500 → 75)
export function bpsToPercent(bps: number | bigint): number {
  return Number(bps) / 100
}

// Token amount with decimals → display string
export function formatToken(amount: bigint, decimals: number, maxFrac = 4): string {
  const divisor = BigInt(10 ** decimals)
  const whole = amount / divisor
  const frac = amount % divisor
  if (frac === 0n) return whole.toString()
  const fracStr = frac.toString().padStart(decimals, '0').slice(0, maxFrac).replace(/0+$/, '')
  return fracStr ? `${whole}.${fracStr}` : whole.toString()
}

// USD value (1e8 precision) → display string
export function formatUsd(value: bigint): string {
  const dollars = Number(value) / 1e8
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 2 }).format(dollars)
}

// Utilization (RAY) → percentage
export function formatUtilization(totalBorrow: bigint, totalSupply: bigint): string {
  if (totalSupply === 0n) return '0%'
  const util = (Number(totalBorrow) / Number(totalSupply)) * 100
  return util.toFixed(1) + '%'
}

// Parse human string → bigint with decimals
export function parseTokenInput(value: string, decimals: number): bigint {
  if (!value || value === '.') return 0n
  const [whole, frac = ''] = value.split('.')
  const fracPadded = frac.slice(0, decimals).padEnd(decimals, '0')
  return BigInt(whole || '0') * BigInt(10 ** decimals) + BigInt(fracPadded)
}

// Health factor color
export function hfColor(wad: bigint): string {
  const hf = wadToHf(wad)
  if (!isFinite(hf)) return 'text-apple-green'
  if (hf >= 1.5)  return 'text-apple-green'
  if (hf >= 1.1)  return 'text-apple-orange'
  return 'text-apple-red'
}

export function hfBgColor(wad: bigint): string {
  const hf = wadToHf(wad)
  if (!isFinite(hf)) return 'bg-apple-green/10 text-apple-green'
  if (hf >= 1.5)  return 'bg-apple-green/10 text-apple-green'
  if (hf >= 1.1)  return 'bg-apple-orange/10 text-apple-orange'
  return 'bg-apple-red/10 text-apple-red'
}
