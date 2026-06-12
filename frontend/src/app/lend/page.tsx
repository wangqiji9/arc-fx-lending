'use client'

import { LendPanel } from '@/components/lend/LendPanel'
import { StatCard } from '@/components/ui/StatCard'
import { useMarkets } from '@/hooks/useMarkets'
import { TOKENS } from '@/lib/contracts'

export default function LendPage() {
  const { markets } = useMarkets()

  const bestSupplyApy = markets.reduce((best, m) => {
    const apy = Number(m.collateralSupplyRate)
    return apy > best ? apy : best
  }, 0)

  const RAY = 1e27
  const bestApyLabel = bestSupplyApy > 0
    ? (bestSupplyApy / RAY * 100).toFixed(2) + '%'
    : '—'

  return (
    <div className="max-w-3xl mx-auto px-6 py-10">
      {/* Page header */}
      <div className="mb-8">
        <h1 className="text-[34px] font-bold text-apple-label tracking-tight">Supply</h1>
        <p className="text-[17px] text-apple-secondary mt-2">
          Supply USDC, EURC, or WETH to earn interest. Withdraw any time when liquidity is available.
        </p>
      </div>

      {/* Quick stats */}
      <div className="grid grid-cols-3 gap-4 mb-8">
        <StatCard label="Best Supply APY" value={bestApyLabel} accent />
        <StatCard label="Assets" value="3" sub="USDC · EURC · WETH" />
        <StatCard label="Network" value="Arc Testnet" sub="Chain ID 5042002" />
      </div>

      {/* How it works */}
      <div className="bg-apple-card rounded-3xl p-6 shadow-apple border border-apple-separator mb-8">
        <h2 className="text-[15px] font-semibold text-apple-label mb-3">How it works</h2>
        <ol className="space-y-2 text-[13px] text-apple-secondary">
          <li className="flex gap-2.5">
            <span className="w-5 h-5 rounded-full bg-apple-blue/10 text-apple-blue text-[11px] font-bold flex items-center justify-center flex-shrink-0 mt-0.5">1</span>
            Approve the LendingPool to transfer your tokens.
          </li>
          <li className="flex gap-2.5">
            <span className="w-5 h-5 rounded-full bg-apple-blue/10 text-apple-blue text-[11px] font-bold flex items-center justify-center flex-shrink-0 mt-0.5">2</span>
            Deposit any amount — you receive scaled shares that automatically accrue interest via the liquidity index.
          </li>
          <li className="flex gap-2.5">
            <span className="w-5 h-5 rounded-full bg-apple-blue/10 text-apple-blue text-[11px] font-bold flex items-center justify-center flex-shrink-0 mt-0.5">3</span>
            Withdraw your principal + interest at any time (subject to available pool liquidity).
          </li>
        </ol>
      </div>

      {/* Main panel */}
      <LendPanel />
    </div>
  )
}
