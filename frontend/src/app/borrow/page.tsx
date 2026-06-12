'use client'

import { BorrowPanel } from '@/components/borrow/BorrowPanel'
import { StatCard } from '@/components/ui/StatCard'
import { useMarkets } from '@/hooks/useMarkets'

export default function BorrowPage() {
  const { markets } = useMarkets()

  const bestBorrowApy = markets.reduce((best, m) => {
    const apy = Number(m.debtBorrowRate)
    return best === 0 || apy < best ? apy : best
  }, 0)

  const RAY = 1e27
  const bestApyLabel = bestBorrowApy > 0
    ? (bestBorrowApy / RAY * 100).toFixed(2) + '%'
    : '—'

  const fxCount      = markets.filter(m => m.isFxMode).length
  const standardCount = markets.filter(m => !m.isFxMode).length

  return (
    <div className="max-w-3xl mx-auto px-6 py-10">
      {/* Page header */}
      <div className="mb-8">
        <h1 className="text-[34px] font-bold text-apple-label tracking-tight">Borrow</h1>
        <p className="text-[17px] text-apple-secondary mt-2">
          Open isolated positions by depositing collateral and borrowing against it. Each (collateral, debt) pair is independent.
        </p>
      </div>

      {/* Quick stats */}
      <div className="grid grid-cols-3 gap-4 mb-8">
        <StatCard label="Lowest Borrow APY" value={bestApyLabel} accent />
        <StatCard label="FX E-Mode Pairs" value={String(fxCount)} sub="90% LTV · 2.5% bonus" />
        <StatCard label="Standard Pairs" value={String(standardCount)} sub="75% LTV · 7.5% bonus" />
      </div>

      {/* Mode explanation */}
      <div className="grid sm:grid-cols-2 gap-4 mb-8">
        <div className="bg-apple-card rounded-3xl p-5 shadow-apple border border-apple-separator">
          <div className="flex items-center gap-2 mb-2">
            <span className="px-2 py-0.5 bg-gray-100 text-apple-secondary text-[11px] font-semibold rounded-full">Standard</span>
          </div>
          <p className="text-[13px] text-apple-secondary leading-relaxed">
            For crypto pairs like WETH → USDC. LTV 75%, liquidation threshold 80%, 7.5% liquidation bonus. Liquidation price is reported as a scalar collateral price level.
          </p>
        </div>
        <div className="bg-apple-card rounded-3xl p-5 shadow-apple border border-apple-separator">
          <div className="flex items-center gap-2 mb-2">
            <span className="px-2 py-0.5 bg-indigo-50 text-indigo-600 text-[11px] font-semibold rounded-full">FX E-Mode</span>
          </div>
          <p className="text-[13px] text-apple-secondary leading-relaxed">
            For same-currency stablecoin pairs like USDC → EURC. LTV 90%, threshold 94%, only 2.5% liquidation bonus. Risk shown as safety buffer in bps — FX risk is a depeg jump, not a price approach.
          </p>
        </div>
      </div>

      {/* Main panel */}
      <BorrowPanel />
    </div>
  )
}
