'use client'

import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useUserPositionKeys, useBatchPositionRisk, useLenderDeposits } from '@/hooks/useUserPositions'
import { PositionCard } from '@/components/positions/PositionCard'
import { LenderDepositCard } from '@/components/positions/LenderDepositCard'
import Link from 'next/link'

function EmptyState() {
  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator p-12 text-center">
      <div className="w-16 h-16 bg-apple-fill rounded-full flex items-center justify-center mx-auto mb-4">
        <svg width="32" height="32" viewBox="0 0 32 32" fill="none">
          <rect x="6" y="10" width="20" height="14" rx="3" stroke="#86868B" strokeWidth="1.5"/>
          <path d="M11 10V8a5 5 0 0110 0v2" stroke="#86868B" strokeWidth="1.5" strokeLinecap="round"/>
          <circle cx="16" cy="17" r="2" fill="#86868B"/>
        </svg>
      </div>
      <h3 className="text-[17px] font-semibold text-apple-label mb-1">No positions yet</h3>
      <p className="text-[13px] text-apple-secondary mb-6 max-w-xs mx-auto">
        Supply assets to earn interest, or open a borrowing position.
      </p>
      <div className="flex gap-3 justify-center">
        <Link
          href="/lend"
          className="inline-flex items-center px-5 py-2.5 bg-apple-green hover:opacity-90 text-white text-[14px] font-semibold rounded-full transition-colors"
        >
          Supply
        </Link>
        <Link
          href="/borrow"
          className="inline-flex items-center px-5 py-2.5 bg-apple-blue hover:bg-apple-blue-hover text-white text-[14px] font-semibold rounded-full transition-colors"
        >
          Borrow
        </Link>
      </div>
    </div>
  )
}

function LoadingSkeleton() {
  return (
    <div className="space-y-4">
      {[0, 1].map(i => (
        <div key={i} className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator p-5 animate-pulse">
          <div className="flex items-center gap-4">
            <div className="flex gap-2">
              <div className="w-6 h-6 rounded-full bg-apple-fill" />
              <div className="w-6 h-6 rounded-full bg-apple-fill" />
            </div>
            <div className="space-y-1.5 flex-1">
              <div className="h-4 w-32 bg-apple-fill rounded-full" />
              <div className="h-3 w-24 bg-apple-fill rounded-full" />
            </div>
            <div className="h-6 w-14 bg-apple-fill rounded-full" />
          </div>
        </div>
      ))}
    </div>
  )
}

export default function PositionsPage() {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  const { isConnected } = useAccount()
  const { data: keys, isLoading: keysLoading } = useUserPositionKeys()
  const positionKeys = (keys as `0x${string}`[]) ?? []
  const { data: risks, isLoading: risksLoading } = useBatchPositionRisk(positionKeys)
  const positionRisks = (risks as any[]) ?? []
  const { deposits, isLoading: depositsLoading } = useLenderDeposits()

  const isLoading = keysLoading || risksLoading || depositsLoading
  const hasBorrowPositions = positionKeys.length > 0
  const hasLendPositions = deposits.length > 0
  const hasAny = hasBorrowPositions || hasLendPositions

  return (
    <div className="max-w-3xl mx-auto px-6 py-10">
      {/* Header */}
      <div className="flex items-start justify-between mb-8">
        <div>
          <h1 className="text-[34px] font-bold text-apple-label tracking-tight">Positions</h1>
          <p className="text-[17px] text-apple-secondary mt-2">
            Your lending deposits and borrowing positions.
          </p>
        </div>
        {isConnected && hasAny && (
          <div className="flex gap-2 mt-2">
            <Link href="/lend" className="px-4 py-2 bg-apple-green hover:opacity-90 text-white text-[13px] font-semibold rounded-full transition-colors">
              + Supply
            </Link>
            <Link href="/borrow" className="px-4 py-2 bg-apple-blue hover:bg-apple-blue-hover text-white text-[13px] font-semibold rounded-full transition-colors">
              + Borrow
            </Link>
          </div>
        )}
      </div>

      {!mounted ? (
        <LoadingSkeleton />
      ) : !isConnected ? (
        <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator p-12 text-center">
          <p className="text-[17px] font-semibold text-apple-label mb-2">Connect your wallet</p>
          <p className="text-[13px] text-apple-secondary mb-6">Connect to view your positions.</p>
          <div className="flex justify-center">
            <ConnectButton />
          </div>
        </div>
      ) : isLoading ? (
        <LoadingSkeleton />
      ) : !hasAny ? (
        <EmptyState />
      ) : (
        <div className="space-y-8">
          {/* Lending section */}
          {hasLendPositions && (
            <section>
              <div className="flex items-center gap-2 mb-3">
                <h2 className="text-[17px] font-semibold text-apple-label">Lending</h2>
                <span className="px-2 py-0.5 bg-apple-green/10 text-apple-green text-[12px] font-medium rounded-full">
                  {deposits.length} asset{deposits.length !== 1 ? 's' : ''}
                </span>
              </div>
              <div className="space-y-3">
                {deposits.map(d => (
                  <LenderDepositCard key={d.asset} {...d} />
                ))}
              </div>
            </section>
          )}

          {/* Borrowing section */}
          {hasBorrowPositions && (
            <section>
              <div className="flex items-center gap-2 mb-3">
                <h2 className="text-[17px] font-semibold text-apple-label">Borrowing</h2>
                <span className="px-2 py-0.5 bg-apple-orange/10 text-apple-orange text-[12px] font-medium rounded-full">
                  {positionKeys.length} position{positionKeys.length !== 1 ? 's' : ''}
                </span>
              </div>
              <div className="space-y-3">
                {positionRisks.map((risk, i) => (
                  <PositionCard key={positionKeys[i]} risk={{
                    ...risk,
                    key: positionKeys[i],
                    healthFactor:         BigInt(risk.healthFactor),
                    liquidationPrice:     BigInt(risk.liquidationPrice),
                    bufferBps:            BigInt(risk.bufferBps),
                    currentDebt:          BigInt(risk.currentDebt),
                    collateralValue:      BigInt(risk.collateralValue),
                    debtValue:            BigInt(risk.debtValue),
                    debtBorrowRate:       BigInt(risk.debtBorrowRate),
                    collateralSupplyRate: BigInt(risk.collateralSupplyRate),
                  }} />
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  )
}
