import LendingPoolABI from '@/abis/LendingPool.json'

export { LendingPoolABI }

export const LENDING_POOL_ADDRESS = '0x6fc50Bbd108F39Fc6B0069c29f42e4A120C9df97' as `0x${string}`

export const TOKENS = {
  USDC: {
    address: '0xe94C3c122204a1011EED9Ba9C11Aa8DEA861e91f' as `0x${string}`,
    symbol: 'USDC',
    decimals: 6,
  },
  EURC: {
    address: '0x657ff6937aC8913AD3DbEC44430BcdeD3af1367C' as `0x${string}`,
    symbol: 'EURC',
    decimals: 6,
  },
  WETH: {
    address: '0x78F1D761BC1E5D01b136e78A63AE444189ee02FB' as `0x${string}`,
    symbol: 'WETH',
    decimals: 18,
  },
} as const

export type TokenSymbol = keyof typeof TOKENS

export function tokenByAddress(address: string): typeof TOKENS[TokenSymbol] | undefined {
  return Object.values(TOKENS).find(t => t.address.toLowerCase() === address.toLowerCase())
}

// Price oracle (IPriceOracle — USD prices with 1e8 base)
export const ORACLE_ADDRESS = '0x39375eD41C100De00c759067774D73d62Ab7380B' as `0x${string}`
export const ORACLE_ABI = [
  { name: 'getPrice', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] },
] as const

// Minimal ERC-20 ABI (approve + balanceOf + allowance)
export const ERC20_ABI = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] },
  { name: 'allowance', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }] },
  { name: 'decimals', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint8' }] },
] as const
