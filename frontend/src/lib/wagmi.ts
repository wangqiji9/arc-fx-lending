import { createConfig, http, injected } from 'wagmi'
import { defineChain } from 'viem'

export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://rpc.testnet.arc.network'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://testnet.arcscan.app' },
  },
  testnet: true,
})

// Local testnet: injected wallet only (MetaMask / OKX / browser extension).
// WalletConnect requires a valid project ID from cloud.walletconnect.com — add it
// to .env.local (NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID) when needed for mobile/QR flow.
export const wagmiConfig = createConfig({
  connectors: [injected()],
  chains: [arcTestnet],
  transports: { [arcTestnet.id]: http() },
  ssr: false,
})
