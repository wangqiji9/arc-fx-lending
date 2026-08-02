import { createConfig, injected } from 'wagmi'
import { custom, defineChain } from 'viem'
import { queuedRpc } from './rpcQueue'

export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  // Listed for wallet "add network" prompts and as a fallback. Actual reads do
  // not go through this URL — they are dispatched by rpcQueue.ts across all
  // three published Arc endpoints (see arcTransport below).
  rpcUrls: {
    default: { http: ['https://rpc.drpc.testnet.arc.network'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://testnet.arcscan.app' },
  },
  // Multicall3 is deployed at the canonical address on Arc Testnet. Declaring it
  // lets viem/wagmi batch `useReadContracts` calls; without it those calls throw
  // "does not support contract multicall3" and dependent UI values (TVL, total
  // supplied/borrowed, oracle prices) silently fall back to 0.
  contracts: {
    multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
  },
  testnet: true,
})

// Custom transport: route every JSON-RPC call through the single-flight,
// rate-limited queue (see rpcQueue.ts) instead of firing them concurrently.
// This is what keeps reads from being rejected by the Arc public RPC limiter.
const arcTransport = custom({
  async request({ method, params }) {
    const out = (await queuedRpc({ jsonrpc: '2.0', id: 1, method, params })) as {
      result?: unknown
      error?: { message?: string }
    }
    if (out.error) throw new Error(out.error.message ?? 'RPC error')
    return out.result
  },
})

// Local testnet: injected wallet only (MetaMask / OKX / browser extension).
// WalletConnect requires a valid project ID from cloud.walletconnect.com — add it
// to .env.local (NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID) when needed for mobile/QR flow.
export const wagmiConfig = createConfig({
  connectors: [injected()],
  chains: [arcTestnet],
  // Merge same-tick contract reads into a single Multicall3 call to minimize
  // request volume against the rate limiter. `wait` batches calls fired within
  // the window into one HTTP request.
  batch: { multicall: { wait: 80 } },
  transports: { [arcTestnet.id]: arcTransport },
  ssr: false,
})
