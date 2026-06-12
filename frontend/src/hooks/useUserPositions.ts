import { useReadContract } from 'wagmi'
import { useAccount } from 'wagmi'
import { LENDING_POOL_ADDRESS, LendingPoolABI } from '@/lib/contracts'

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
  })
}
