'use client'

import clsx from 'clsx'
import Link from 'next/link'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { bpsToPercent } from '@/lib/format'
import type { Market } from '@/hooks/useMarkets'

export function MarketRow({ market }: { market: Market }) {
  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto_auto] items-center gap-4 px-5 py-4 hover:bg-apple-fill/50 transition-colors rounded-2xl">
      {/* Pair */}
      <div className="flex items-center gap-3 min-w-0">
        <div className="flex -space-x-2">
          <TokenIcon symbol={market.collateralSymbol} />
          <TokenIcon symbol={market.debtSymbol} size="sm" />
        </div>
        <div className="min-w-0">
          <p className="text-[14px] font-semibold text-apple-label truncate">
            {market.collateralSymbol} → {market.debtSymbol}
          </p>
          <p className="text-[11px] text-apple-secondary">
            {market.isFxMode ? 'FX E-Mode' : 'Standard'}
          </p>
        </div>
      </div>

      {/* Borrow APY */}
      <div className="text-right">
        <p className="text-[12px] text-apple-secondary mb-0.5">Borrow APY</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">{market.borrowApyLabel}</p>
      </div>

      {/* Supply APY */}
      <div className="text-right">
        <p className="text-[12px] text-apple-secondary mb-0.5">Supply APY</p>
        <p className="text-[14px] font-semibold text-apple-green tabular-nums">{market.supplyApyLabel}</p>
      </div>

      {/* LTV */}
      <div className="text-right">
        <p className="text-[12px] text-apple-secondary mb-0.5">LTV</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">{bpsToPercent(market.ltv)}%</p>
      </div>

      {/* Liquidity */}
      <div className="text-right">
        <p className="text-[12px] text-apple-secondary mb-0.5">Liquidity</p>
        <p className="text-[14px] font-semibold text-apple-label tabular-nums">
          {market.liquidityLabel} <span className="text-apple-secondary font-normal">{market.debtSymbol}</span>
        </p>
      </div>

      {/* CTA */}
      <Link
        href="/borrow"
        className="px-4 py-1.5 bg-apple-blue hover:bg-apple-blue-hover text-white text-[13px] font-medium rounded-full transition-colors whitespace-nowrap"
      >
        Borrow
      </Link>
    </div>
  )
}

export function MarketRowSkeleton() {
  return (
    <div className="grid grid-cols-[1fr_auto_auto_auto_auto_auto] items-center gap-4 px-5 py-4 animate-pulse">
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-full bg-apple-fill" />
        <div className="space-y-1.5">
          <div className="h-3.5 w-28 bg-apple-fill rounded-full" />
          <div className="h-3 w-16 bg-apple-fill rounded-full" />
        </div>
      </div>
      {[...Array(4)].map((_, i) => (
        <div key={i} className="space-y-1.5 text-right">
          <div className="h-3 w-16 bg-apple-fill rounded-full ml-auto" />
          <div className="h-3.5 w-12 bg-apple-fill rounded-full ml-auto" />
        </div>
      ))}
      <div className="h-7 w-16 bg-apple-fill rounded-full" />
    </div>
  )
}
