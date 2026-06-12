import { useReadContract, useReadContracts } from 'wagmi'
import { LENDING_POOL_ADDRESS, LendingPoolABI, TOKENS, tokenByAddress } from '@/lib/contracts'
import { formatApy, formatToken } from '@/lib/format'

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

export function useMarkets() {
  const { data, isLoading, error } = useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getAvailableMarkets',
  })

  const markets: Market[] = ((data as any[]) ?? []).map((m: any) => {
    const colToken = tokenByAddress(m.collateralAsset)
    const debtToken = tokenByAddress(m.debtAsset)
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

  // Deduplicate by debt asset for the lend panel (one row per asset)
  const lendAssets = Object.values(
    Object.fromEntries(
      Object.values(TOKENS).map(t => {
        const m = markets.find(x => x.collateralAsset.toLowerCase() === t.address.toLowerCase())
        return [t.address, { token: t, supplyApyLabel: m?.supplyApyLabel ?? '—' }]
      })
    )
  )

  return { markets, lendAssets, isLoading, error }
}
