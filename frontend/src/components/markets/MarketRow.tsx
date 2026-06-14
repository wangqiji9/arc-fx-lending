'use client'

import Link from 'next/link'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { formatToken, bpsToPercent } from '@/lib/format'
import type { Market, SupplyAsset } from '@/hooks/useMarkets'

// ── Supply row ────────────────────────────────────────────────────────────────

export function SupplyRow({ asset }: { asset: SupplyAsset }) {
  const utilColor =
    asset.utilization >= 90 ? 'text-apple-red' :
    asset.utilization >= 70 ? 'text-apple-orange' :
    'text-apple-label'

  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto] items-center gap-6 px-5 py-4 hover:bg-apple-fill/40 transition-colors">
      {/* Asset */}
      <div className="flex items-center gap-3">
        <TokenIcon symbol={asset.symbol} />
        <span className="text-[15px] font-semibold text-apple-label">{asset.symbol}</span>
      </div>

      {/* Supply APY */}
      <div className="text-right w-24">
        <p className="text-[11px] text-apple-secondary mb-0.5">Supply APY</p>
        <p className="text-[15px] font-semibold text-apple-green tabular-nums">{asset.supplyApyLabel}</p>
      </div>

      {/* Total Supplied */}
      <div className="text-right w-36 hidden sm:block">
        <p className="text-[11px] text-apple-secondary mb-0.5">Total Supplied</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">
          {formatToken(asset.totalSupplied, asset.decimals, 2)}{' '}
          <span className="text-apple-secondary font-normal text-[12px]">{asset.symbol}</span>
        </p>
      </div>

      {/* Utilization */}
      <div className="text-right w-24 hidden sm:block">
        <p className="text-[11px] text-apple-secondary mb-0.5">Utilization</p>
        <div className="flex flex-col items-end gap-1">
          <p className={`text-[14px] font-semibold tabular-nums ${utilColor}`}>{asset.utilization}%</p>
          <div className="w-16 h-1 rounded-full bg-apple-fill overflow-hidden">
            <div
              className={`h-full rounded-full transition-all ${asset.utilization >= 90 ? 'bg-apple-red' : asset.utilization >= 70 ? 'bg-apple-orange' : 'bg-apple-green'}`}
              style={{ width: `${asset.utilization}%` }}
            />
          </div>
        </div>
      </div>

      {/* CTA */}
      <Link
        href="/lend"
        className="px-4 py-1.5 bg-apple-green hover:opacity-90 text-white text-[13px] font-semibold rounded-full transition-all whitespace-nowrap"
      >
        Supply
      </Link>
    </div>
  )
}

export function SupplyRowSkeleton() {
  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto] items-center gap-6 px-5 py-4 animate-pulse">
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-full bg-apple-fill" />
        <div className="h-4 w-12 bg-apple-fill rounded-full" />
      </div>
      {[...Array(3)].map((_, i) => (
        <div key={i} className="space-y-1.5 text-right hidden sm:block">
          <div className="h-3 w-16 bg-apple-fill rounded-full ml-auto" />
          <div className="h-4 w-12 bg-apple-fill rounded-full ml-auto" />
        </div>
      ))}
      <div className="h-7 w-16 bg-apple-fill rounded-full" />
    </div>
  )
}

// ── Borrow row ────────────────────────────────────────────────────────────────

export function BorrowRow({ market }: { market: Market }) {
  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto] items-center gap-6 px-5 py-4 hover:bg-apple-fill/40 transition-colors">
      {/* Pair + mode badge */}
      <div className="flex items-center gap-3 min-w-0">
        <div className="flex -space-x-2 shrink-0">
          <TokenIcon symbol={market.collateralSymbol} />
          <TokenIcon symbol={market.debtSymbol} size="sm" />
        </div>
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <p className="text-[14px] font-semibold text-apple-label truncate">
              {market.collateralSymbol} → {market.debtSymbol}
            </p>
            {market.isFxMode && (
              <span className="shrink-0 px-1.5 py-0.5 bg-indigo-50 text-indigo-600 text-[10px] font-bold rounded-md leading-none">
                E-Mode
              </span>
            )}
          </div>
          <p className="text-[11px] text-apple-secondary mt-0.5">
            {market.isFxMode ? 'FX E-Mode' : 'Standard'} · LTV {bpsToPercent(market.ltv)}%
          </p>
        </div>
      </div>

      {/* Borrow APY */}
      <div className="text-right w-24">
        <p className="text-[11px] text-apple-secondary mb-0.5">Borrow APY</p>
        <p className="text-[15px] font-semibold text-apple-label tabular-nums">{market.borrowApyLabel}</p>
      </div>

      {/* Available liquidity */}
      <div className="text-right w-36 hidden sm:block">
        <p className="text-[11px] text-apple-secondary mb-0.5">Available</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">
          {market.liquidityLabel}{' '}
          <span className="text-apple-secondary font-normal text-[12px]">{market.debtSymbol}</span>
        </p>
      </div>

      {/* LT */}
      <div className="text-right w-24 hidden sm:block">
        <p className="text-[11px] text-apple-secondary mb-0.5">Liq. Threshold</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">
          {bpsToPercent(market.liquidationThreshold)}%
        </p>
      </div>

      {/* CTA */}
      <Link
        href="/borrow"
        className="px-4 py-1.5 bg-apple-blue hover:bg-apple-blue-hover text-white text-[13px] font-semibold rounded-full transition-colors whitespace-nowrap"
      >
        Borrow
      </Link>
    </div>
  )
}

export function BorrowRowSkeleton() {
  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto] items-center gap-6 px-5 py-4 animate-pulse">
      <div className="flex items-center gap-3">
        <div className="flex -space-x-2">
          <div className="w-8 h-8 rounded-full bg-apple-fill" />
          <div className="w-6 h-6 rounded-full bg-apple-fill" />
        </div>
        <div className="space-y-1.5">
          <div className="h-3.5 w-28 bg-apple-fill rounded-full" />
          <div className="h-3 w-20 bg-apple-fill rounded-full" />
        </div>
      </div>
      {[...Array(3)].map((_, i) => (
        <div key={i} className="space-y-1.5 text-right hidden sm:block">
          <div className="h-3 w-16 bg-apple-fill rounded-full ml-auto" />
          <div className="h-4 w-12 bg-apple-fill rounded-full ml-auto" />
        </div>
      ))}
      <div className="h-7 w-16 bg-apple-fill rounded-full" />
    </div>
  )
}

// Keep old exports for compatibility with any other importer
/** @deprecated use BorrowRow */
export const MarketRow = BorrowRow
/** @deprecated use BorrowRowSkeleton */
export const MarketRowSkeleton = BorrowRowSkeleton
