'use client'

import { useState, useEffect } from 'react'
import { useChainId, useSwitchChain } from 'wagmi'
import { useAccount } from 'wagmi'
import { arcTestnet } from '@/lib/wagmi'

export function NetworkBanner() {
  const [mounted, setMounted] = useState(false)
  useEffect(() => { setMounted(true) }, [])

  const { isConnected } = useAccount()
  const chainId = useChainId()
  const { switchChain, isPending } = useSwitchChain()

  if (!mounted || !isConnected || chainId === arcTestnet.id) return null

  return (
    <div className="bg-apple-orange/10 border-b border-apple-orange/20 py-2.5 px-6 flex items-center justify-center gap-3">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" className="text-apple-orange shrink-0">
        <path d="M7 1L13 12H1L7 1Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round"/>
        <path d="M7 5.5V8" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
        <circle cx="7" cy="10" r="0.75" fill="currentColor"/>
      </svg>
      <span className="text-[13px] text-apple-orange font-medium">
        Wrong network — please switch to Arc Testnet
      </span>
      <button
        onClick={() => switchChain({ chainId: arcTestnet.id })}
        disabled={isPending}
        className="px-3 py-1 bg-apple-orange text-white text-[12px] font-semibold rounded-full hover:brightness-105 disabled:opacity-50 transition-all"
      >
        {isPending ? 'Switching…' : 'Switch Network'}
      </button>
    </div>
  )
}
