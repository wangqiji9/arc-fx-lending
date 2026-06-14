'use client'
import { useMemo } from 'react'
import { useReadContract } from 'wagmi'
import { LENDING_POOL_ADDRESS, LendingPoolABI } from '@/lib/contracts'
import { loadPositionOpenData } from '@/lib/positionStorage'

export function useAccruedInterest({
  positionKey,
}: {
  positionKey: `0x${string}` | undefined
  // scaledDebt and currentBorrowIndex no longer needed — contract computes this
  scaledDebt?: bigint
  currentBorrowIndex?: bigint
}) {
  const openData = useMemo(() => {
    if (!positionKey) return null
    return loadPositionOpenData(positionKey)
  }, [positionKey])

  const { data } = useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getBorrowInterest',
    args: positionKey ? [positionKey] : undefined,
    query: { enabled: !!positionKey },
  })

  const result = data as readonly [bigint, bigint, bigint] | undefined
  // [liveDebt, principal, accruedInterest]
  const accrued = result ? result[2] : null

  return {
    accrued,
    openTimestamp: openData?.openTimestamp ?? null,
  }
}
