import { useReadContract, useReadContracts } from 'wagmi'
import { useAccount } from 'wagmi'
import type { Abi } from 'viem'
import { LENDING_POOL_ADDRESS, LendingPoolABI, TOKENS } from '@/lib/contracts'

const ABI = LendingPoolABI as Abi

export function useUserPositionKeys() {
  const { address } = useAccount()
  return useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getUserPositionKeys',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })
}

export function useBatchPositionRisk(keys: `0x${string}`[]) {
  return useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'batchGetPositionRisk',
    args: [keys],
    query: { enabled: keys.length > 0 },
  })
}

export function useUserDeposit(asset: `0x${string}`) {
  const { address } = useAccount()
  return useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getScaledDeposit',
    args: address ? [asset, address] : undefined,
    query: { enabled: !!address },
  })
}

export function useReserveData(asset: `0x${string}`) {
  return useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getReserveData',
    args: [asset],
    ,
  })
}

export interface LenderDeposit {
  asset: `0x${string}`
  symbol: string
  decimals: number
  currentValue: bigint
  principal: bigint
  earned: bigint
  supplyRate: bigint
}

export function useLenderDeposits() {
  const { address } = useAccount()
  const tokenList = Object.values(TOKENS)

  // getLenderPosition returns (value, principal, earned) — live index, one call per token
  const positionResults = useReadContracts({
    contracts: tokenList.map(t => ({
      address: LENDING_POOL_ADDRESS,
      abi: ABI,
      functionName: 'getLenderPosition',
      args: [t.address, address!],
    })),
    query: { enabled: !!address, refetchInterval: REFETCH_INTERVAL },
  })

  const supplyRateResults = useReadContracts({
    contracts: tokenList.map(t => ({
      address: LENDING_POOL_ADDRESS,
      abi: ABI,
      functionName: 'viewRates',
      args: [t.address],
    })),
    query: { refetchInterval: REFETCH_INTERVAL },
  })

  const deposits: LenderDeposit[] = tokenList.flatMap((t, i) => {
    const pos = positionResults.data?.[i]?.result as readonly [bigint, bigint, bigint] | undefined
    const rates = supplyRateResults.data?.[i]?.result as readonly [bigint, bigint] | undefined

    // pos = [value, principal, earned]
    if (!pos || pos[0] === 0n) return []

    return [{
      asset: t.address,
      symbol: t.symbol,
      decimals: t.decimals,
      currentValue: pos[0],
      principal: pos[1],
      earned: pos[2],
      supplyRate: rates ? rates[1] : 0n,
    }]
  })

  return {
    deposits,
    isLoading: positionResults.isLoading || supplyRateResults.isLoading,
  }
}
