'use client'

import { useState, useRef, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from 'wagmi'
import clsx from 'clsx'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { HealthBadge } from '@/components/ui/HealthBadge'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, TOKENS, type TokenSymbol } from '@/lib/contracts'
import { formatToken, formatApy, parseTokenInput } from '@/lib/format'
import { usePreviewPosition } from '@/hooks/usePreview'
import { useMarkets } from '@/hooks/useMarkets'

const STABLECOINS: TokenSymbol[] = ['USDC', 'EURC']
const ALL_TOKENS = Object.values(TOKENS)

function isFxAvailable(col: TokenSymbol, debt: TokenSymbol) {
  return STABLECOINS.includes(col) && STABLECOINS.includes(debt)
}

// Dropdown token selector
function TokenDropdown({
  value,
  exclude,
  label,
  onChange,
}: {
  value: TokenSymbol
  exclude: TokenSymbol
  label: string
  onChange: (v: TokenSymbol) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const token = TOKENS[value]
  const options = ALL_TOKENS.filter(t => t.symbol !== exclude)

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [])

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(o => !o)}
        className="flex items-center gap-2 bg-white rounded-full px-3 py-1.5 shadow-apple-sm border border-apple-separator hover:border-apple-blue/30 transition-colors"
      >
        <TokenIcon symbol={token.symbol} size="sm" />
        <span className="text-[13px] font-semibold text-apple-label">{token.symbol}</span>
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={clsx('text-apple-secondary transition-transform', open && 'rotate-180')}>
          <path d="M2.5 4.5l3.5 3 3.5-3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-1.5 bg-white rounded-2xl shadow-apple-lg border border-apple-separator overflow-hidden z-20 min-w-[140px]">
          <p className="px-3 pt-2.5 pb-1 text-[11px] font-semibold text-apple-secondary uppercase tracking-wider">{label}</p>
          {options.map(t => (
            <button
              key={t.symbol}
              onClick={() => { onChange(t.symbol as TokenSymbol); setOpen(false) }}
              className={clsx(
                'w-full flex items-center gap-2.5 px-3 py-2.5 hover:bg-apple-fill transition-colors',
                value === t.symbol && 'bg-apple-fill'
              )}
            >
              <TokenIcon symbol={t.symbol} size="sm" />
              <div className="text-left">
                <p className="text-[13px] font-semibold text-apple-label">{t.symbol}</p>
              </div>
              {value === t.symbol && (
                <svg className="ml-auto text-apple-blue" width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <path d="M2.5 7l3 3 6-6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// Mode badge
function ModeBadge({ fx }: { fx: boolean }) {
  return (
    <span className={clsx(
      'inline-flex items-center px-2.5 py-0.5 rounded-full text-[11px] font-semibold',
      fx ? 'bg-indigo-50 text-indigo-600' : 'bg-gray-100 text-apple-secondary'
    )}>
      {fx ? 'FX E-Mode' : 'Standard'}
    </span>
  )
}

export function BorrowPanel() {
  const { address, isConnected } = useAccount()
  const [colSymbol, setColSymbol] = useState<TokenSymbol>('WETH')
  const [debtSymbol, setDebtSymbol] = useState<TokenSymbol>('USDC')
  const [colAmount, setColAmount] = useState('')
  const [borrowAmount, setBorrowAmount] = useState('')
  // FX E-Mode toggle — only relevant when both assets are stablecoins
  const [useFxMode, setUseFxMode] = useState(true)

  const colToken  = TOKENS[colSymbol]
  const debtToken = TOKENS[debtSymbol]
  const fxAvailable = isFxAvailable(colSymbol, debtSymbol)
  // Effective mode: FX only when both are stablecoins AND user chose it
  const effectiveFx = fxAvailable && useFxMode

  // When asset changes, reset FX mode default
  function handleColChange(sym: TokenSymbol) {
    setColSymbol(sym)
    // If new pair can't be FX, reset toggle
    if (!isFxAvailable(sym, debtSymbol)) setUseFxMode(false)
    else setUseFxMode(true)
    setColAmount('')
  }
  function handleDebtChange(sym: TokenSymbol) {
    setDebtSymbol(sym)
    if (!isFxAvailable(colSymbol, sym)) setUseFxMode(false)
    else setUseFxMode(true)
    setBorrowAmount('')
  }

  const parsedCol    = parseTokenInput(colAmount, colToken.decimals)
  const parsedBorrow = parseTokenInput(borrowAmount, debtToken.decimals)

  const { data: preview } = usePreviewPosition(colToken.address, parsedCol, debtToken.address, parsedBorrow)
  const { markets } = useMarkets()

  const market = markets.find(
    m =>
      m.collateralAsset.toLowerCase() === colToken.address.toLowerCase() &&
      m.debtAsset.toLowerCase() === debtToken.address.toLowerCase()
  )

  const { data: walletBal } = useReadContract({
    address: colToken.address,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: colToken.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address },
  })

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  const needsApprove = (allowance as bigint ?? 0n) < parsedCol && parsedCol > 0n
  const p = preview as any
  const openable  = p?.openable ?? false
  const hfValue   = p?.healthFactor ? BigInt(p.healthFactor) : 0n
  const busy      = isPending || isConfirming

  function handleApprove() {
    writeContract({ address: colToken.address, abi: ERC20_ABI, functionName: 'approve', args: [LENDING_POOL_ADDRESS, parsedCol] })
  }
  function handleOpen() {
    writeContract({
      address: LENDING_POOL_ADDRESS,
      abi: LendingPoolABI,
      functionName: 'openPosition',
      args: [colToken.address, parsedCol, debtToken.address, parsedBorrow],
    })
    setColAmount(''); setBorrowAmount('')
  }

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
      <div className="p-6 space-y-4">
        <div className="flex items-start justify-between">
          <div>
            <h2 className="text-[17px] font-semibold text-apple-label">Open Position</h2>
            <p className="text-[13px] text-apple-secondary mt-0.5">Deposit collateral and borrow in one step</p>
          </div>
          {/* Active mode indicator */}
          <ModeBadge fx={effectiveFx} />
        </div>

        {/* Collateral */}
        <div className="bg-apple-bg rounded-2xl p-4 space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-[12px] font-medium text-apple-secondary">Collateral</span>
            <span className="text-[12px] text-apple-tertiary">
              Bal: {formatToken((walletBal as bigint) ?? 0n, colToken.decimals, 4)} {colToken.symbol}
            </span>
          </div>
          <div className="flex items-center gap-3">
            <input
              type="number"
              min="0"
              placeholder="0.00"
              value={colAmount}
              onChange={e => setColAmount(e.target.value)}
              className="flex-1 bg-transparent text-[22px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
            />
            <TokenDropdown value={colSymbol} exclude={debtSymbol} label="Select collateral" onChange={handleColChange} />
          </div>
        </div>

        {/* Arrow */}
        <div className="flex justify-center">
          <div className="w-8 h-8 bg-apple-fill rounded-full flex items-center justify-center text-apple-secondary text-sm select-none">↓</div>
        </div>

        {/* Borrow */}
        <div className="bg-apple-bg rounded-2xl p-4 space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-[12px] font-medium text-apple-secondary">Borrow</span>
            {market && (
              <span className="text-[12px] text-apple-tertiary">
                Avail: {market.liquidityLabel} {market.debtSymbol}
              </span>
            )}
          </div>
          <div className="flex items-center gap-3">
            <input
              type="number"
              min="0"
              placeholder="0.00"
              value={borrowAmount}
              onChange={e => setBorrowAmount(e.target.value)}
              className="flex-1 bg-transparent text-[22px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
            />
            <TokenDropdown value={debtSymbol} exclude={colSymbol} label="Select borrow asset" onChange={handleDebtChange} />
          </div>
        </div>

        {/* Mode selector — only when both stablecoins */}
        {fxAvailable && (
          <div className="bg-apple-bg rounded-2xl p-4">
            <p className="text-[12px] font-medium text-apple-secondary mb-2.5">Risk Mode</p>
            <div className="flex bg-white rounded-full p-1 shadow-apple-sm border border-apple-separator gap-1">
              <button
                onClick={() => setUseFxMode(true)}
                className={clsx(
                  'flex-1 py-2 rounded-full text-[13px] font-semibold transition-all',
                  useFxMode ? 'bg-indigo-600 text-white shadow-apple-sm' : 'text-apple-secondary hover:text-apple-label'
                )}
              >
                FX E-Mode
              </button>
              <button
                onClick={() => setUseFxMode(false)}
                className={clsx(
                  'flex-1 py-2 rounded-full text-[13px] font-semibold transition-all',
                  !useFxMode ? 'bg-apple-label text-white shadow-apple-sm' : 'text-apple-secondary hover:text-apple-label'
                )}
              >
                Standard
              </button>
            </div>
            <p className="text-[11px] text-apple-secondary mt-2 leading-relaxed">
              {useFxMode
                ? 'FX E-Mode: LTV 90%, threshold 94%, 2.5% liquidation bonus. Risk shown as safety buffer.'
                : 'Standard: LTV 75%, threshold 80%, 7.5% liquidation bonus. Liquidation price reported.'}
            </p>
          </div>
        )}

        {/* Preview */}
        {p && parsedCol > 0n && parsedBorrow > 0n && (
          <div className="bg-apple-bg rounded-2xl p-4 space-y-2.5">
            <p className="text-[12px] font-semibold text-apple-secondary uppercase tracking-wider">Preview</p>
            <div className="space-y-2">
              <PreviewRow label="Health Factor"><HealthBadge wad={hfValue} /></PreviewRow>
              <PreviewRow label="Borrow APY">
                <span className="text-[13px] font-semibold text-apple-label tabular-nums">{formatApy(BigInt(p.borrowRate))}</span>
              </PreviewRow>
              {p.liquidationPriceApplicable && (
                <PreviewRow label="Liquidation Price">
                  <span className="text-[13px] font-semibold text-apple-red tabular-nums">
                    ${(Number(BigInt(p.liquidationPrice)) / 1e8).toFixed(2)}
                  </span>
                </PreviewRow>
              )}
              {!p.liquidationPriceApplicable && BigInt(p.bufferBps) > 0n && (
                <PreviewRow label="Safety Buffer">
                  <span className="text-[13px] font-semibold text-apple-label tabular-nums">
                    {(Number(BigInt(p.bufferBps)) / 100).toFixed(1)} bps
                  </span>
                </PreviewRow>
              )}
              <PreviewRow label="Can Open">
                <span className={clsx('text-[13px] font-semibold', openable ? 'text-apple-green' : 'text-apple-red')}>
                  {openable ? 'Yes ✓' : 'No ✗'}
                </span>
              </PreviewRow>
            </div>
          </div>
        )}

        {/* CTA */}
        {!isConnected ? (
          <p className="text-center text-[13px] text-apple-secondary py-1">Connect wallet to continue</p>
        ) : needsApprove ? (
          <button
            onClick={handleApprove}
            disabled={busy || parsedCol === 0n}
            className="w-full py-3.5 bg-apple-orange text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all hover:brightness-105"
          >
            {busy ? 'Approving…' : `Approve ${colToken.symbol}`}
          </button>
        ) : (
          <button
            onClick={handleOpen}
            disabled={busy || !openable || parsedCol === 0n || parsedBorrow === 0n}
            className="w-full py-3.5 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all"
          >
            {busy ? (isConfirming ? 'Confirming…' : 'Sending…') : 'Open Position'}
          </button>
        )}

        {isSuccess && (
          <p className="text-center text-[13px] text-apple-green font-medium">Position opened ✓</p>
        )}
      </div>
    </div>
  )
}

function PreviewRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-[12px] text-apple-secondary">{label}</span>
      {children}
    </div>
  )
}
