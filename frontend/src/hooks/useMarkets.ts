import { useReadContract, useReadContracts } from 'wagmi'
import type { Abi } from 'viem'
import { LENDING_POOL_ADDRESS, LendingPoolABI, TOKENS, ORACLE_ADDRESS, ORACLE_ABI } from '@/lib/contracts'
import { formatApy, formatToken } from '@/lib/format'


const ABI = LendingPoolABI as Abi
const RAY = BigInt('1000000000000000000000000000')

export interface Market {
  collateralAsset: `0x${string}`
  debtAsset: `0x${string}`
  collateralSymbol: string
  debtSymbol: string
  ltv: number
  liquidationThreshold: number
  debtBorrowRate: bigint
  collateralSupplyRate: bigint
  availableLiquidity: bigint
  isFxMode: boolean
  borrowApyLabel: string
  supplyApyLabel: string
  liquidityLabel: string
}

export interface SupplyAsset {
  address: `0x${string}`
  symbol: string
  decimals: number
  supplyRate: bigint
  totalSupplied: bigint
  totalBorrowed: bigint
  available: bigint
  utilization: number
  supplyApyLabel: string
}

export function useMarkets() {
  const { data, isLoading, error } = useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: ABI,
    functionName: 'getAvailableMarkets',
  })

  const markets: Market[] = ((data as any[]) ?? []).map((m: any) => {
    const colToken = Object.values(TOKENS).find(t => t.address.toLowerCase() === m.collateralAsset.toLowerCase())
    const debtToken = Object.values(TOKENS).find(t => t.address.toLowerCase() === m.debtAsset.toLowerCase())
    return {
      collateralAsset: m.collateralAsset,
      debtAsset: m.debtAsset,
      collateralSymbol: colToken?.symbol ?? m.collateralAsset.slice(0, 6),
      debtSymbol: debtToken?.symbol ?? m.debtAsset.slice(0, 6),
      ltv: Number(m.ltv),
      liquidationThreshold: Number(m.liquidationThreshold),
      debtBorrowRate: BigInt(m.debtBorrowRate),
      collateralSupplyRate: BigInt(m.collateralSupplyRate),
      availableLiquidity: BigInt(m.availableLiquidity),
      isFxMode: m.isFxMode,
      borrowApyLabel: formatApy(BigInt(m.debtBorrowRate)),
      supplyApyLabel: formatApy(BigInt(m.collateralSupplyRate)),
      liquidityLabel: formatToken(BigInt(m.availableLiquidity), debtToken?.decimals ?? 6, 2),
    }
  })

  // For lend panel: one supply APY per asset (using collateralSupplyRate from any market featuring that asset as collateral)
  const lendAssets = Object.values(TOKENS).map(t => {
    const m = markets.find(x => x.collateralAsset.toLowerCase() === t.address.toLowerCase())
    return { token: t, supplyApyLabel: m?.supplyApyLabel ?? '—' }
  })

  return { markets, lendAssets, isLoading, error }
}

export function useSupplyAssets() {
  const tokenList = Object.values(TOKENS)

  const rateResults = useReadContracts({
    contracts: tokenList.map(t => ({
      address: LENDING_POOL_ADDRESS,
      abi: ABI,
      functionName: 'viewRates' as const,
      args: [t.address] as const,
    })),
  })

  const reserveResults = useReadContracts({
    contracts: tokenList.map(t => ({
      address: LENDING_POOL_ADDRESS,
      abi: ABI,
      functionName: 'getReserveData' as const,
      args: [t.address] as const,
    })),
  })

  const isLoading = rateResults.isLoading || reserveResults.isLoading

  const assets: SupplyAsset[] = tokenList.map((t, i) => {
    const rates = rateResults.data?.[i]?.result as readonly [bigint, bigint] | undefined
    const reserve = reserveResults.data?.[i]?.result as any

    const supplyRate = rates?.[1] ?? 0n

    let totalSupplied = 0n
    let totalBorrowed = 0n
    let available = 0n
    let utilization = 0

    if (reserve) {
      totalSupplied = (BigInt(reserve.totalScaledSupply) * BigInt(reserve.liquidityIndex)) / RAY
      totalBorrowed = (BigInt(reserve.totalScaledBorrow) * BigInt(reserve.borrowIndex)) / RAY
      available = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0n
      utilization = totalSupplied > 0n
        ? Math.min(100, Math.round(Number(totalBorrowed * 1000n / totalSupplied) / 10))
        : 0
    }

    return {
      address: t.address,
      symbol: t.symbol,
      decimals: t.decimals,
      supplyRate,
      totalSupplied,
      totalBorrowed,
      available,
      utilization,
      supplyApyLabel: formatApy(supplyRate),
    }
  })

  return { assets, isLoading }
}

// ── Oracle prices ──────────────────────────────────────────────────────────
// Returns USD price (1e8 base) per token address (lowercase key).

const ORACLE_ABI_TYPED = ORACLE_ABI as Abi

export function useOraclePrices() {
  const tokenList = Object.values(TOKENS)

  const { data, isLoading } = useReadContracts({
    contracts: tokenList.map(t => ({
      address: ORACLE_ADDRESS,
      abi: ORACLE_ABI_TYPED,
      functionName: 'getPrice' as const,
      args: [t.address] as const,
    })),
  })

  const prices: Record<string, bigint> = {}
  tokenList.forEach((t, i) => {
    prices[t.address.toLowerCase()] = (data?.[i]?.result as bigint | undefined) ?? 0n
  })

  return { prices, isLoading }
}
