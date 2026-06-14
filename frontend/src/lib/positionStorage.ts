import { keccak256, encodeAbiParameters } from 'viem'

export interface PositionOpenData {
  borrowIndexAtOpen: string  // bigint serialized as string
  openTimestamp: number       // unix seconds
}

// Mirrors the contract's keccak256(abi.encode(owner, collateralAsset, debtAsset))
export function computePositionKey(
  owner: `0x${string}`,
  collateralAsset: `0x${string}`,
  debtAsset: `0x${string}`,
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'address' }, { type: 'address' }, { type: 'address' }],
      [owner, collateralAsset, debtAsset],
    ),
  )
}

const storageKey = (posKey: string) => `arc-pos-${posKey}`

export function savePositionOpenData(posKey: string, data: PositionOpenData): void {
  try {
    localStorage.setItem(storageKey(posKey), JSON.stringify(data))
  } catch {}
}

export function loadPositionOpenData(posKey: string): PositionOpenData | null {
  try {
    const raw = localStorage.getItem(storageKey(posKey))
    return raw ? (JSON.parse(raw) as PositionOpenData) : null
  } catch {
    return null
  }
}
