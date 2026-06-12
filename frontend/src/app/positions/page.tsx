'use client'

import { useAccount } from 'wagmi'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useUserPositionKeys, useBatchPositionRisk } from '@/hooks/useUserPositions'
import { PositionCard } from '@/components/positions/PositionCard'
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
      <h3 className="text-[17px] font-semibold text-apple-label mb-1">No open positions</h3>
      <p className="text-[13px] text-apple-secondary mb-6 max-w-xs mx-auto">
        Open your first position by depositing collateral and borrowing against it.
      </p>
      <Link
        href="/borrow"
        className="inline-flex items-center px-5 py-2.5 bg-apple-blue hover:bg-apple-blue-hover text-white text-[14px] font-semibold rounded-full transition-colors"
      >
        Open a Position
      </Link>
    </div>
  )
}

function LoadingSkeleton() {
  return (
    <div className="space-y-4">
      {[0, 1].map(i => (
        <div key={i} className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator p-5 animate-pulse">
          <div className="flex items-center gap-4">
            <div className="flex -space-x-2">
              <div className="w-8 h-8 rounded-full bg-apple-fill" />
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
  const { isConnected } = useAccount()
  const { data: keys, isLoading: keysLoading } = useUserPositionKeys()
  const positionKeys = (keys as `0x${string}`[]) ?? []
  const { data: risks, isLoading: risksLoading } = useBatchPositionRisk(positionKeys)
  const positionRisks = (risks as any[]) ?? []

  const isLoading = keysLoading || risksLoading
  const hasPositions = positionKeys.length > 0

  return (
    <div className="max-w-3xl mx-auto px-6 py-10">
      {/* Header */}
      <div className="flex items-start justify-between mb-8">
        <div>
          <h1 className="text-[34px] font-bold text-apple-label tracking-tight">Positions</h1>
          <p className="text-[17px] text-apple-secondary mt-2">
            Manage your open borrowing positions.
          </p>
        </div>
        {isConnected && hasPositions && (
          <Link
            href="/borrow"
            className="mt-2 px-4 py-2 bg-apple-blue hover:bg-apple-blue-hover text-white text-[13px] font-semibold rounded-full transition-colors"
          >
            + New
          </Link>
        )}
      </div>

      {!isConnected ? (
        <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator p-12 text-center">
          <p className="text-[17px] font-semibold text-apple-label mb-2">Connect your wallet</p>
          <p className="text-[13px] text-apple-secondary mb-6">Connect to view your open positions.</p>
          <div className="flex justify-center">
            <ConnectButton />
          </div>
        </div>
      ) : isLoading ? (
        <LoadingSkeleton />
      ) : !hasPositions ? (
        <EmptyState />
      ) : (
        <div className="space-y-4">
          {positionRisks.map((risk, i) => (
            <PositionCard key={positionKeys[i]} risk={{
              ...risk,
              key: positionKeys[i],
              healthFactor:   BigInt(risk.healthFactor),
              liquidationPrice: BigInt(risk.liquidationPrice),
              bufferBps:      BigInt(risk.bufferBps),
              currentDebt:    BigInt(risk.currentDebt),
              collateralValue: BigInt(risk.collateralValue),
              debtValue:       BigInt(risk.debtValue),
              debtBorrowRate:  BigInt(risk.debtBorrowRate),
              collateralSupplyRate: BigInt(risk.collateralSupplyRate),
            }} />
          ))}
        </div>
      )}
    </div>
  )
}
