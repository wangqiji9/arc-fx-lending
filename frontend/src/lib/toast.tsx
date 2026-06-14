'use client'

import { createContext, useContext, useState, useCallback } from 'react'
import clsx from 'clsx'

const EXPLORER = 'https://testnet.arcscan.app'

export type ToastStatus = 'pending' | 'success' | 'error'

export interface ToastData {
  id: string
  title: string
  description?: string
  status: ToastStatus
  txHash?: string
}

interface ToastCtx {
  showToast: (id: string, data: Omit<ToastData, 'id'>) => void
  updateToast: (id: string, updates: Partial<Omit<ToastData, 'id'>>) => void
  dismissToast: (id: string) => void
}

const ToastContext = createContext<ToastCtx | null>(null)

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<ToastData[]>([])

  const showToast = useCallback((id: string, data: Omit<ToastData, 'id'>) => {
    setToasts(prev => {
      const idx = prev.findIndex(t => t.id === id)
      if (idx >= 0) {
        const next = [...prev]; next[idx] = { ...next[idx], ...data, id }; return next
      }
      return [...prev, { ...data, id }]
    })
  }, [])

  const updateToast = useCallback((id: string, updates: Partial<Omit<ToastData, 'id'>>) => {
    setToasts(prev => prev.map(t => t.id === id ? { ...t, ...updates } : t))
    if (updates.status === 'success' || updates.status === 'error') {
      const delay = updates.status === 'success' ? 5000 : 9000
      setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), delay)
    }
  }, [])

  const dismissToast = useCallback((id: string) => {
    setToasts(prev => prev.filter(t => t.id !== id))
  }, [])

  return (
    <ToastContext.Provider value={{ showToast, updateToast, dismissToast }}>
      {children}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </ToastContext.Provider>
  )
}

export function useToast(): ToastCtx {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToast must be used within ToastProvider')
  return ctx
}

// ── Internal UI ──────────────────────────────────────────────────────────────

function ToastContainer({ toasts, onDismiss }: { toasts: ToastData[]; onDismiss: (id: string) => void }) {
  if (toasts.length === 0) return null
  return (
    <div className="fixed bottom-6 right-6 z-50 flex flex-col gap-3 w-full max-w-[340px] pointer-events-none">
      {toasts.map(t => (
        <ToastItem key={t.id} toast={t} onDismiss={() => onDismiss(t.id)} />
      ))}
    </div>
  )
}

function ToastItem({ toast, onDismiss }: { toast: ToastData; onDismiss: () => void }) {
  const { title, description, status, txHash } = toast

  return (
    <div className="pointer-events-auto bg-white rounded-2xl shadow-[0_8px_32px_rgba(0,0,0,0.12)] border border-apple-separator p-4 flex items-start gap-3">
      <div className="flex-shrink-0 mt-0.5">
        {status === 'pending' && (
          <svg className="animate-spin text-apple-blue" width="16" height="16" viewBox="0 0 16 16" fill="none">
            <circle cx="8" cy="8" r="6" stroke="currentColor" strokeWidth="2" strokeOpacity="0.2" />
            <path d="M14 8a6 6 0 0 0-6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        )}
        {status === 'success' && (
          <svg className="text-apple-green" width="16" height="16" viewBox="0 0 16 16" fill="none">
            <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5" />
            <path d="M4.5 8.5l2.5 2.5 4.5-5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        )}
        {status === 'error' && (
          <svg className="text-apple-red" width="16" height="16" viewBox="0 0 16 16" fill="none">
            <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5" />
            <path d="M8 5v3.5M8 11.5v.01" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          </svg>
        )}
      </div>

      <div className="flex-1 min-w-0">
        <p className="text-[13px] font-semibold text-apple-label leading-snug">{title}</p>
        {description && (
          <p className="text-[12px] text-apple-secondary mt-0.5 leading-snug">{description}</p>
        )}
        {txHash && (
          <a
            href={`${EXPLORER}/tx/${txHash}`}
            target="_blank"
            rel="noreferrer"
            className="text-[11px] text-apple-blue hover:underline mt-1 inline-block font-mono"
          >
            {txHash.slice(0, 8)}…{txHash.slice(-6)} ↗
          </a>
        )}
      </div>

      <button
        onClick={onDismiss}
        className="flex-shrink-0 text-apple-tertiary hover:text-apple-secondary transition-colors"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M2 2l10 10M12 2L2 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  )
}