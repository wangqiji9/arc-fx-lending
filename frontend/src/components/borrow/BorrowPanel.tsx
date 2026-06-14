'use client'

import { useState, useRef, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract, usePublicClient } from 'wagmi'
import clsx from 'clsx'
import { decodeEventLog, parseAbiItem } from 'viem'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { HealthBadge } from '@/components/ui/HealthBadge'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, TOKENS, type TokenSymbol } from '@/lib/contracts'
import { formatToken, formatApy, parseTokenInput } from '@/lib/format'
import { usePreviewPosition } from '@/hooks/usePreview'
import { useMarkets, useOraclePrices } from '@/hooks/useMarkets'
import { computePositionKey, savePositionOpenData } from '@/lib/positionStorage'
import { useToast } from '@/lib/toast'

const RESERVE_UPDATED_ABI = parseAbiItem(
  'event ReserveDataUpdated(address indexed asset, uint256 liquidityIndex, uint256 borrowIndex, uint256 borrowRate)'
)

const STABLECOINS: TokenSymbol[] = ['USDC', 'EURC']
const ALL_TOKENS = Object.values(TOKENS)

function isFxAvailable(col: TokenSymbol, debt: TokenSymbol) {
  return STABLECOINS.includes(col) && STABLECOINS.includes(debt)
}

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
  const client = usePublicClient()
  const pendingAssetsRef = useRef<{ col: `0x${string}`; debt: `0x${string}` } | null>(null)
  const { showToast, updateToast } = useToast()
  const toastIdRef = useRef<string | null>(null)

  const [colSymbol, setColSymbol] = useState<TokenSymbol>('WETH')
  const [debtSymbol, setDebtSymbol] = useState<TokenSymbol>('USDC')
  const [colAmount, setColAmount] = useState('')
  const [borrowAmount, setBorrowAmount] = useState('')
  const [approveInput, setApproveInput] = useState('')
  const [useFxMode, setUseFxMode] = useState(true)

  const colToken  = TOKENS[colSymbol]
  const debtToken = TOKENS[debtSymbol]
  const fxAvailable = isFxAvailable(colSymbol, debtSymbol)
  const effectiveFx = fxAvailable && useFxMode

  function handleColChange(sym: TokenSymbol) {
    setColSymbol(sym)
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
  const { prices } = useOraclePrices()

  const market = markets.find(
    m =>
      m.collateralAsset.toLowerCase() === colToken.address.toLowerCase() &&
      m.debtAsset.toLowerCase() === debtToken.address.toLowerCase()
  )

  // Market matching the active mode — used for LTV-based max borrow calculation
  const effectiveMarket = markets.find(
    m =>
      m.collateralAsset.toLowerCase() === colToken.address.toLowerCase() &&
      m.debtAsset.toLowerCase() === debtToken.address.toLowerCase() &&
      m.isFxMode === effectiveFx
  ) ?? market

  const colPrice  = prices[colToken.address.toLowerCase()]  ?? 0n
  const debtPrice = prices[debtToken.address.toLowerCase()] ?? 0n
  const maxBorrow =
    effectiveMarket && parsedCol > 0n && colPrice > 0n && debtPrice > 0n
      ? (parsedCol * colPrice * BigInt(effectiveMarket.ltv) * BigInt(10 ** debtToken.decimals)) /
        (BigInt(10 ** colToken.decimals) * debtPrice * 10000n)
      : 0n

  const { data: walletBal } = useReadContract({
    address: colToken.address,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const { data: allowance } = useReadContract({
    address: colToken.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address },
  })

  const { writeContract, data: txHash, isPending, error: writeError } = useWriteContract()
  const { isLoading: isConfirming, isSuccess, isError: isReverted, data: receipt } = useWaitForTransactionReceipt({ hash: txHash })

  useEffect(() => {
    if (!txHash || !toastIdRef.current) return
    updateToast(toastIdRef.current, { txHash })
  }, [txHash])

  useEffect(() => {
    if (!writeError || !toastIdRef.current) return
    const msg = (writeError as any)?.shortMessage ?? writeError.message.split('\n')[0]
    updateToast(toastIdRef.current, { status: 'error', description: msg })
    toastIdRef.current = null
  }, [writeError])

  useEffect(() => {
    if (!isReverted || !toastIdRef.current) return
    updateToast(toastIdRef.current, { status: 'error', description: 'Transaction reverted on-chain' })
    toastIdRef.current = null
  }, [isReverted])

  // When openPosition confirms: save position open data + update toast
  useEffect(() => {
    if (!isSuccess || !receipt || !address || !client || !pendingAssetsRef.current) return
    const { col, debt } = pendingAssetsRef.current

    if (toastIdRef.current) {
      updateToast(toastIdRef.current, { status: 'success', description: 'Position opened successfully' })
      toastIdRef.current = null
    }

    ;(async () => {
      try {
        const block = await client.getBlock({ blockNumber: receipt.blockNumber })
        let borrowIndexAtOpen: bigint | undefined

        for (const log of receipt.logs) {
          if (log.address.toLowerCase() !== LENDING_POOL_ADDRESS.toLowerCase()) continue
          try {
            const decoded = decodeEventLog({ abi: [RESERVE_UPDATED_ABI], data: log.data, topics: log.topics as any })
            const args = decoded.args as any
            if (decoded.eventName === 'ReserveDataUpdated' && args.asset.toLowerCase() === debt.toLowerCase()) {
              borrowIndexAtOpen = args.borrowIndex as bigint
              break
            }
          } catch {}
        }

        if (!borrowIndexAtOpen) return

        const posKey = computePositionKey(address, col, debt)
        savePositionOpenData(posKey, {
          borrowIndexAtOpen: borrowIndexAtOpen.toString(),
          openTimestamp: Number(block.timestamp),
        })
      } catch (e) {
        console.error('Failed to save position open data:', e)
      }
    })()
  }, [isSuccess, receipt, address, client])

  const needsApprove = (allowance as bigint ?? 0n) < parsedCol && parsedCol > 0n
  const parsedApproveAmount = approveInput
    ? parseTokenInput(approveInput, colToken.decimals)
    : parsedCol
  const p = preview as any
  const openable  = p?.openable ?? false
  const hfValue   = p?.healthFactor ? BigInt(p.healthFactor) : 0n
  const busy      = isPending || isConfirming

  const [mounted, setMounted] = useState(false)
  useEffect(() => { setMounted(true) }, [])

  function handleApprove() {
    const id = `approve-${colToken.symbol}-${Date.now()}`
    toastIdRef.current = id
    showToast(id, {
      title: `Approve ${colToken.symbol}`,
      description: `Allow LendingPool to spend ${colToken.symbol}`,
      status: 'pending',
    })
    writeContract({ address: colToken.address, abi: ERC20_ABI, functionName: 'approve', args: [LENDING_POOL_ADDRESS, parsedApproveAmount] })
    setApproveInput('')
  }

  function handleOpen() {
    const id = `open-position-${Date.now()}`
    toastIdRef.current = id
    showToast(id, {
      title: `Open ${colSymbol} → ${debtSymbol} Position`,
      description: `${formatToken(parsedCol, colToken.decimals, 4)} ${colSymbol} collateral · borrow ${formatToken(parsedBorrow, debtToken.decimals, 4)} ${debtSymbol}`,
      status: 'pending',
    })
    pendingAssetsRef.current = { col: colToken.address, debt: debtToken.address }
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

        <div className="flex justify-center">
          <div className="w-8 h-8 bg-apple-fill rounded-full flex items-center justify-center text-apple-secondary text-sm select-none">↓</div>
        </div>

        {/* Borrow */}
        <div className="bg-apple-bg rounded-2xl p-4 space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-[12px] font-medium text-apple-secondary">Borrow</span>
            <div className="flex items-center gap-2">
              {maxBorrow > 0n && (
                <button
                  onClick={() => setBorrowAmount(formatToken(maxBorrow, debtToken.decimals, 4))}
                  className="text-[12px] text-apple-blue font-medium hover:underline"
                >
                  Max ({formatToken(maxBorrow, debtToken.decimals, 2)} {debtToken.symbol})
                </button>
              )}
              {market && (
                <span className="text-[12px] text-apple-tertiary">
                  Avail: {market.liquidityLabel} {market.debtSymbol}
                </span>
              )}
            </div>
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

        {!mounted || !isConnected ? (
          <p className="text-center text-[13px] text-apple-secondary py-1">Connect wallet to continue</p>
        ) : needsApprove ? (
          <div className="space-y-3">
            <div className="bg-apple-bg rounded-2xl p-4">
              <div className="flex items-center justify-between mb-2">
                <p className="text-[12px] text-apple-secondary">Approve amount ({colToken.symbol})</p>
                <button
                  onClick={() => setApproveInput(formatToken(parsedCol, colToken.decimals, colToken.decimals))}
                  className="text-[12px] text-apple-blue font-medium hover:underline"
                >
                  Exact
                </button>
              </div>
              <input
                type="number"
                min="0"
                placeholder={formatToken(parsedCol, colToken.decimals, 4) + ' (exact)'}
                value={approveInput}
                onChange={e => setApproveInput(e.target.value)}
                className="w-full bg-transparent text-[18px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
              />
            </div>
            <button
              onClick={handleApprove}
              disabled={busy || parsedCol === 0n}
              className="w-full py-3.5 bg-apple-orange text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all hover:brightness-105"
            >
              {busy ? 'Approving…' : `Approve ${colToken.symbol}`}
            </button>
          </div>
        ) : (
          <button
            onClick={handleOpen}
            disabled={busy || !openable || parsedCol === 0n || parsedBorrow === 0n}
            className="w-full py-3.5 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all"
          >
            {busy ? (isConfirming ? 'Confirming…' : 'Sending…') : 'Open Position'}
          </button>
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
