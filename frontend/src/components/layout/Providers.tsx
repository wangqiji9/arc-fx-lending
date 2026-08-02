'use client'

import { RainbowKitProvider, darkTheme, lightTheme } from '@rainbow-me/rainbowkit'
import { WagmiProvider } from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { wagmiConfig } from '@/lib/wagmi'
import { ToastProvider } from '@/lib/toast'
import '@rainbow-me/rainbowkit/styles.css'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      // rpcQueue.ts owns rate-limit handling: it retries across three endpoints
      // with its own backoff. Retrying aggressively here as well multiplied the
      // request count for the same read (measured: 13 HTTP requests for 2
      // distinct payloads), so keep this to a single safety-net attempt.
      retry: 1,
      retryDelay: 500,
      // Keep the last good data on screen while refetching so a transient
      // limiter rejection never blanks the UI back to 0 / "—".
      placeholderData: (prev: unknown) => prev,
      staleTime: 30_000,
      gcTime: 5 * 60_000,
    },
  },
})

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={lightTheme({
            accentColor: '#0071E3',
            accentColorForeground: 'white',
            borderRadius: 'large',
            fontStack: 'system',
          })}
        >
          <ToastProvider>
            {children}
          </ToastProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
