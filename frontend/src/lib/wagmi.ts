import { connectorsForWallets } from '@rainbow-me/rainbowkit'
import {
  metaMaskWallet,
  rainbowWallet,
  coinbaseWallet,
  okxWallet,
  injectedWallet,
} from '@rainbow-me/rainbowkit/wallets'
import { createConfig, http } from 'wagmi'
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

// Get a free Project ID at https://cloud.walletconnect.com
// Placeholder keeps the app running; WalletConnect QR won't work until replaced.
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || '00000000000000000000000000000001'

const connectors = connectorsForWallets(
  [
    {
      groupName: 'Recommended',
      wallets: [okxWallet, metaMaskWallet, coinbaseWallet],
    },
    {
      groupName: 'Other',
      wallets: [rainbowWallet, injectedWallet],
    },
  ],
  {
    appName: 'Arc FX Lending',
    projectId,
  }
)

export const wagmiConfig = createConfig({
  connectors,
  chains: [arcTestnet],
  transports: { [arcTestnet.id]: http() },
  ssr: true,
})
