import { useReadContract } from 'wagmi'
import { LENDING_POOL_ADDRESS, LendingPoolABI } from '@/lib/contracts'

export function usePreviewPosition(
  collateralAsset: `0x${string}`,
  collateralAmount: bigint,
  debtAsset: `0x${string}`,
  borrowAmount: bigint,
) {
  const enabled =
    collateralAmount > 0n &&
    borrowAmount > 0n &&
    collateralAsset !== '0x0000000000000000000000000000000000000000' &&
    debtAsset !== '0x0000000000000000000000000000000000000000' &&
    collateralAsset.toLowerCase() !== debtAsset.toLowerCase()

  return useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'previewPosition',
    args: [collateralAsset, collateralAmount, debtAsset, borrowAmount],
    query: { enabled },
  })
}
