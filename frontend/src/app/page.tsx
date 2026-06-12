'use client'

import { useMarkets } from '@/hooks/useMarkets'
import { MarketRow, MarketRowSkeleton } from '@/components/markets/MarketRow'
import { StatCard } from '@/components/ui/StatCard'
import { formatToken, formatApy } from '@/lib/format'
import { TOKENS } from '@/lib/contracts'
import { useReserveData } from '@/hooks/useUserPositions'

function ProtocolStats() {
  const { data: usdcReserve } = useReserveData(TOKENS.USDC.address)
  const { data: eurcReserve } = useReserveData(TOKENS.EURC.address)
  const { data: wethReserve } = useReserveData(TOKENS.WETH.address)

  const RAY = BigInt('1000000000000000000000000000')

  function totalSupply(reserve: any, decimals: number) {
    if (!reserve) return '—'
    const actual = (BigInt(reserve.totalScaledSupply) * BigInt(reserve.liquidityIndex)) / RAY
    return formatToken(actual, decimals, 2)
  }

  function totalBorrow(reserve: any, decimals: number) {
    if (!reserve) return '—'
    const actual = (BigInt(reserve.totalScaledBorrow) * BigInt(reserve.borrowIndex)) / RAY
    return formatToken(actual, decimals, 2)
  }

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 gap-4 mb-8">
      <StatCard label="USDC Supplied"  value={totalSupply(usdcReserve, 6) + ' USDC'} />
      <StatCard label="EURC Supplied"  value={totalSupply(eurcReserve, 6) + ' EURC'} />
      <StatCard label="WETH Supplied"  value={totalSupply(wethReserve, 18) + ' WETH'} />
      <StatCard label="USDC Borrowed"  value={totalBorrow(usdcReserve, 6) + ' USDC'} />
      <StatCard label="EURC Borrowed"  value={totalBorrow(eurcReserve, 6) + ' EURC'} />
      <StatCard label="WETH Borrowed"  value={totalBorrow(wethReserve, 18) + ' WETH'} />
    </div>
  )
}

export default function MarketsPage() {
  const { markets, isLoading } = useMarkets()

  const fxMarkets      = markets.filter(m => m.isFxMode)
  const standardMarkets = markets.filter(m => !m.isFxMode)

  return (
    <div className="max-w-6xl mx-auto px-6 py-10">
      {/* Hero */}
      <div className="mb-10">
        <h1 className="text-[34px] font-bold text-apple-label tracking-tight leading-tight">
          Multi-currency Lending &amp; Borrowing
        </h1>
        <p className="text-[17px] text-apple-secondary mt-2 max-w-xl">
          Supply assets to earn yield or open isolated positions with Standard and FX E-Mode risk parameters on Arc Testnet.
        </p>
      </div>

      {/* Protocol stats */}
      <ProtocolStats />

      {/* FX E-Mode markets */}
      {(isLoading || fxMarkets.length > 0) && (
        <section className="mb-8">
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-[19px] font-semibold text-apple-label">FX E-Mode</h2>
            <span className="px-2.5 py-0.5 bg-indigo-50 text-indigo-600 text-[11px] font-semibold rounded-full">
              Higher LTV · Lower Bonus
            </span>
          </div>
          <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator divide-y divide-apple-separator">
            {isLoading
              ? <MarketRowSkeleton />
              : fxMarkets.map((m, i) => <MarketRow key={i} market={m} />)}
          </div>
        </section>
      )}

      {/* Standard markets */}
      {(isLoading || standardMarkets.length > 0) && (
        <section>
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-[19px] font-semibold text-apple-label">Standard Markets</h2>
          </div>
          <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator divide-y divide-apple-separator">
            {isLoading
              ? [0,1,2].map(i => <MarketRowSkeleton key={i} />)
              : standardMarkets.map((m, i) => <MarketRow key={i} market={m} />)}
          </div>
        </section>
      )}

      {!isLoading && markets.length === 0 && (
        <div className="text-center py-20 text-apple-secondary">
          <p className="text-[17px]">No markets found.</p>
          <p className="text-[13px] mt-1">Make sure the contract is deployed and configured.</p>
        </div>
      )}
    </div>
  )
}
