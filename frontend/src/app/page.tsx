'use client'

import { useMarkets, useSupplyAssets, useOraclePrices } from '@/hooks/useMarkets'
import { SupplyRow, SupplyRowSkeleton, BorrowRow, BorrowRowSkeleton } from '@/components/markets/MarketRow'
import { formatUsd } from '@/lib/format'

export default function MarketsPage() {
  const { markets, isLoading: marketsLoading } = useMarkets()
  const { assets, isLoading: assetsLoading } = useSupplyAssets()
  const { prices } = useOraclePrices()

  const fxMarkets      = markets.filter(m => m.isFxMode)
  const standardMarkets = markets.filter(m => !m.isFxMode)
  const isLoading = marketsLoading || assetsLoading

  // Protocol-wide totals in USD (1e8 base)
  const tvlUsd = assets.reduce((sum, a) => {
    const price = prices[a.address.toLowerCase()] ?? 0n
    return sum + (a.totalSupplied * price) / BigInt(10 ** a.decimals)
  }, 0n)
  const borrowedUsd = assets.reduce((sum, a) => {
    const price = prices[a.address.toLowerCase()] ?? 0n
    return sum + (a.totalBorrowed * price) / BigInt(10 ** a.decimals)
  }, 0n)
  const utilPct = tvlUsd > 0n ? Math.round(Number(borrowedUsd * 1000n / tvlUsd) / 10) : 0

  return (
    <div className="max-w-5xl mx-auto px-6 py-10">
      {/* Hero */}
      <div className="mb-10">
        <h1 className="text-[34px] font-bold text-apple-label tracking-tight leading-tight">
          Markets
        </h1>
        <p className="text-[17px] text-apple-secondary mt-2 max-w-xl">
          Supply assets to earn yield, or open isolated borrow positions with Standard and FX E-Mode parameters.
        </p>
      </div>

      {/* ── Protocol Stats ───────────────────────────────────────────────────── */}
      <div className="grid grid-cols-3 gap-4 mb-10">
        {[
          { label: 'Total Value Locked', value: isLoading ? '—' : formatUsd(tvlUsd) },
          { label: 'Total Borrowed',     value: isLoading ? '—' : formatUsd(borrowedUsd) },
          { label: 'Utilization',        value: isLoading ? '—' : `${utilPct}%` },
        ].map(({ label, value }) => (
          <div key={label} className="bg-apple-card rounded-2xl shadow-apple border border-apple-separator p-5">
            <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide mb-1.5">{label}</p>
            <p className="text-[22px] font-bold text-apple-label tabular-nums">{value}</p>
          </div>
        ))}
      </div>

      {/* ── Supply Markets ───────────────────────────────────────────────────── */}
      <section className="mb-10">
        <div className="flex items-center gap-2 mb-4">
          <h2 className="text-[19px] font-semibold text-apple-label">Supply Markets</h2>
          <span className="px-2 py-0.5 bg-apple-green/10 text-apple-green text-[11px] font-semibold rounded-full">
            Earn yield
          </span>
        </div>

        <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
          {/* Header */}
          <div className="grid grid-cols-[1fr_auto_auto_auto_auto] gap-6 px-5 py-3 border-b border-apple-separator">
            <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide">Asset</p>
            <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24">Supply APY</p>
            <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-36 hidden sm:block">Total Supplied</p>
            <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24 hidden sm:block">Utilization</p>
            <div className="w-16" />
          </div>

          <div className="divide-y divide-apple-separator">
            {isLoading
              ? [0, 1, 2].map(i => <SupplyRowSkeleton key={i} />)
              : assets.map(a => <SupplyRow key={a.address} asset={a} />)
            }
          </div>
        </div>
      </section>

      {/* ── Borrow Markets: FX E-Mode ────────────────────────────────────────── */}
      {(isLoading || fxMarkets.length > 0) && (
        <section className="mb-8">
          <div className="flex items-center gap-2 mb-4">
            <h2 className="text-[19px] font-semibold text-apple-label">Borrow Markets</h2>
            <span className="px-2 py-0.5 bg-indigo-50 text-indigo-600 text-[11px] font-semibold rounded-full">
              FX E-Mode · Higher LTV
            </span>
          </div>

          <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden mb-4">
            {/* Header */}
            <div className="grid grid-cols-[1fr_auto_auto_auto_auto] gap-6 px-5 py-3 border-b border-apple-separator">
              <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide">Market</p>
              <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24">Borrow APY</p>
              <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-36 hidden sm:block">Available</p>
              <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24 hidden sm:block">Liq. Threshold</p>
              <div className="w-16" />
            </div>

            <div className="divide-y divide-apple-separator">
              {isLoading
                ? [0, 1].map(i => <BorrowRowSkeleton key={i} />)
                : fxMarkets.map((m, i) => <BorrowRow key={i} market={m} />)
              }
            </div>
          </div>

          {/* Standard markets — same section heading already shown, just a sub-table */}
          {(isLoading || standardMarkets.length > 0) && (
            <>
              <div className="flex items-center gap-2 mb-4 mt-8">
                <h2 className="text-[19px] font-semibold text-apple-label">Standard Markets</h2>
              </div>
              <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
                <div className="grid grid-cols-[1fr_auto_auto_auto_auto] gap-6 px-5 py-3 border-b border-apple-separator">
                  <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide">Market</p>
                  <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24">Borrow APY</p>
                  <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-36 hidden sm:block">Available</p>
                  <p className="text-[11px] font-medium text-apple-secondary uppercase tracking-wide text-right w-24 hidden sm:block">Liq. Threshold</p>
                  <div className="w-16" />
                </div>
                <div className="divide-y divide-apple-separator">
                  {isLoading
                    ? [0, 1].map(i => <BorrowRowSkeleton key={i} />)
                    : standardMarkets.map((m, i) => <BorrowRow key={i} market={m} />)
                  }
                </div>
              </div>
            </>
          )}
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
