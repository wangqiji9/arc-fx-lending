import LendingPoolABI from '@/abis/LendingPool.json'

export { LendingPoolABI }

export const LENDING_POOL_ADDRESS = (
  process.env.NEXT_PUBLIC_LENDING_POOL_ADDRESS ?? '0x0000000000000000000000000000000000000000'
) as `0x${string}`

export const TOKENS = {
  USDC: {
    address: (process.env.NEXT_PUBLIC_USDC_ADDRESS ?? '0x3600000000000000000000000000000000000000') as `0x${string}`,
    symbol: 'USDC',
    decimals: 6,
  },
  EURC: {
    address: (process.env.NEXT_PUBLIC_EURC_ADDRESS ?? '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a') as `0x${string}`,
    symbol: 'EURC',
    decimals: 6,
  },
  WETH: {
    address: (process.env.NEXT_PUBLIC_WETH_ADDRESS ?? '0x0000000000000000000000000000000000000000') as `0x${string}`,
    symbol: 'WETH',
    decimals: 18,
  },
} as const

export type TokenSymbol = keyof typeof TOKENS

export function tokenByAddress(address: string): typeof TOKENS[TokenSymbol] | undefined {
  return Object.values(TOKENS).find(t => t.address.toLowerCase() === address.toLowerCase())
}

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
