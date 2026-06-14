'use client'

import { useState, useEffect, useRef } from 'react'
import { useWriteContract, useWaitForTransactionReceipt, useReadContract, useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { TokenPair } from '@/components/ui/TokenIcon'
import { HealthBadge } from '@/components/ui/HealthBadge'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, tokenByAddress } from '@/lib/contracts'
import { formatToken, formatUsd, formatApy, parseTokenInput } from '@/lib/format'
import { useAccruedInterest } from '@/hooks/useAccruedInterest'
import { usePreviewPosition } from '@/hooks/usePreview'
import { useToast } from '@/lib/toast'

interface PositionRisk {
  key: `0x${string}`
  exists: boolean
  healthFactor: bigint
  liquidationPrice: bigint
  liquidationPriceApplicable: boolean
  bufferBps: bigint
  currentDebt: bigint
  collateralValue: bigint
  debtValue: bigint
  debtBorrowRate: bigint
  collateralSupplyRate: bigint
}

interface Position {
  collateralAsset: `0x${string}`
  debtAsset: `0x${string}`
  collateralAmount: bigint
  scaledDebt: bigint
}

type Action = 'repay' | 'addCollateral' | 'withdraw' | 'borrow'

const ACTION_LABELS: Record<Action, string> = {
  repay: 'Repay',
  addCollateral: 'Add Col.',
  withdraw: 'Withdraw Col.',
  borrow: 'Borrow More',
}

export function PositionCard({ risk }: { risk: PositionRisk }) {
  const { address } = useAccount()
  const [open, setOpen] = useState(false)
  const debtIsZero = risk.currentDebt === 0n
  const [action, setAction] = useState<Action>(debtIsZero ? 'withdraw' : 'repay')
  const [amount, setAmount] = useState('')
  const [approveInput, setApproveInput] = useState('')
  const { showToast, updateToast } = useToast()
  const toastIdRef = useRef<string | null>(null)

  const { data: posData } = useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getPosition',
    args: [risk.key],
  })
  const pos = posData as Position | undefined

  const colToken  = pos ? tokenByAddress(pos.collateralAsset) : undefined
  const debtToken = pos ? tokenByAddress(pos.debtAsset) : undefined

  const { accrued, openTimestamp } = useAccruedInterest({ positionKey: risk.key })

  // Allowances for repay (debt token) and addCollateral (collateral token)
  const { data: repayAllowance } = useReadContract({
    address: debtToken?.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address && debtToken ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address && !!debtToken },
  })
  const { data: colAllowance } = useReadContract({
    address: colToken?.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address && colToken ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address && !!colToken },
  })

  const queryClient = useQueryClient()
  const { writeContract, data: txHash, isPending, error: writeError } = useWriteContract()
  const { isLoading: isConfirming, isSuccess, isError: isReverted } = useWaitForTransactionReceipt({ hash: txHash })

  useEffect(() => {
    if (!txHash || !toastIdRef.current) return
    updateToast(toastIdRef.current, { txHash })
  }, [txHash])

  useEffect(() => {
    if (!isSuccess || !toastIdRef.current) return
    updateToast(toastIdRef.current, { status: 'success', description: 'Transaction confirmed' })
    toastIdRef.current = null
    queryClient.invalidateQueries({ queryKey: ['readContract'] })
  }, [isSuccess, queryClient])

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

  const busy = isPending || isConfirming

  // Decimals depend on action type
  const actionDecimals =
    action === 'repay' || action === 'borrow'
      ? (debtToken?.decimals ?? 6)
      : (colToken?.decimals ?? 18)

  const parsedAmount = parseTokenInput(amount, actionDecimals)

  // Approve: which token and how much
  const needsApprove =
    (action === 'repay'          && (repayAllowance as bigint ?? 0n) < parsedAmount) ||
    (action === 'addCollateral'  && (colAllowance   as bigint ?? 0n) < parsedAmount)

  const approveDecimals = action === 'repay' ? (debtToken?.decimals ?? 6) : (colToken?.decimals ?? 18)
  const parsedApproveAmount = approveInput
    ? parseTokenInput(approveInput, approveDecimals)
    : parsedAmount
  const approveToken = action === 'repay' ? debtToken : colToken

  // Borrow-more preview: pass existing collateral + (current debt + additional borrow)
  const borrowMoreEnabled = action === 'borrow' && parsedAmount > 0n && !!pos
  const { data: borrowMorePreview } = usePreviewPosition(
    pos?.collateralAsset ?? '0x0000000000000000000000000000000000000000',
    pos ? BigInt(pos.collateralAmount) : 0n,
    pos?.debtAsset      ?? '0x0000000000000000000000000000000000000000',
    borrowMoreEnabled ? BigInt(risk.currentDebt) + parsedAmount : 0n,
  )

  if (!risk.exists || !pos) return null

  function handleApprove() {
    if (!approveToken) return
    const id = `approve-${approveToken.symbol}-${Date.now()}`
    toastIdRef.current = id
    showToast(id, {
      title: `Approve ${approveToken.symbol}`,
      description: `Allow LendingPool to spend ${approveToken.symbol}`,
      status: 'pending',
    })
    writeContract({
      address: approveToken.address,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [LENDING_POOL_ADDRESS, parsedApproveAmount],
    })
    setApproveInput('')
  }

  function handleAction() {
    if (!address || !pos) return
    const id = `${action}-${Date.now()}`
    toastIdRef.current = id

    if (action === 'repay') {
      showToast(id, {
        title: `Repay ${debtToken?.symbol ?? ''}`,
        description: `${formatToken(parsedAmount, debtToken?.decimals ?? 6, 4)} ${debtToken?.symbol ?? ''} debt`,
        status: 'pending',
      })
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'repay',
        args: [address, pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    } else if (action === 'addCollateral') {
      showToast(id, {
        title: `Add ${colToken?.symbol ?? ''} Collateral`,
        description: `${formatToken(parsedAmount, colToken?.decimals ?? 18, 4)} ${colToken?.symbol ?? ''}`,
        status: 'pending',
      })
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'addCollateral',
        args: [pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    } else if (action === 'withdraw') {
      showToast(id, {
        title: `Withdraw ${colToken?.symbol ?? ''} Collateral`,
        description: `${formatToken(parsedAmount, colToken?.decimals ?? 18, 4)} ${colToken?.symbol ?? ''}`,
        status: 'pending',
      })
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'withdrawCollateral',
        args: [pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    } else {
      // borrow more
      showToast(id, {
        title: `Borrow More ${debtToken?.symbol ?? ''}`,
        description: `${formatToken(parsedAmount, debtToken?.decimals ?? 6, 4)} ${debtToken?.symbol ?? ''}`,
        status: 'pending',
      })
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'borrow',
        args: [pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    }
    setAmount('')
    setApproveInput('')
  }

  const accruedLabel = accrued != null
    ? `${formatToken(accrued, debtToken?.decimals ?? 6, 6)} ${debtToken?.symbol ?? ''}`
    : '—'

  const openedLabel = openTimestamp
    ? new Date(openTimestamp * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
    : null

  const bp = borrowMorePreview as any
  const bmHf = bp?.healthFactor ? BigInt(bp.healthFactor) : null

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
      {/* Header */}
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between p-5 hover:bg-apple-fill/30 transition-colors"
      >
        <div className="flex items-center gap-4">
          {colToken && debtToken && (
            <TokenPair col={colToken.symbol} debt={debtToken.symbol} />
          )}
          <div className="text-left">
            <p className="text-[15px] font-semibold text-apple-label">
              {colToken?.symbol ?? '?'} → {debtToken?.symbol ?? '?'}
            </p>
            <p className="text-[12px] text-apple-secondary mt-0.5">
              {colToken && formatToken(BigInt(pos.collateralAmount), colToken.decimals, 4)} {colToken?.symbol} collateral
              {openedLabel && <span className="ml-2 text-apple-tertiary">· opened {openedLabel}</span>}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-4">
          <div className="text-right hidden sm:block">
            <p className="text-[12px] text-apple-secondary mb-0.5">Debt</p>
            <p className="text-[14px] font-semibold text-apple-label tabular-nums">
              {debtToken && formatToken(BigInt(risk.currentDebt), debtToken.decimals, 4)} {debtToken?.symbol}
            </p>
          </div>
          <HealthBadge wad={BigInt(risk.healthFactor)} />
          <span className={clsx('text-apple-secondary transition-transform', open && 'rotate-180')}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <path d="M4 6l4 4 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
        </div>
      </button>

      {/* Expanded details */}
      {open && (
        <div className="px-5 pb-5 space-y-4 border-t border-apple-separator pt-4">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            {[
              { label: 'Collateral Value', value: formatUsd(BigInt(risk.collateralValue)) },
              { label: 'Debt Value',       value: formatUsd(BigInt(risk.debtValue)) },
              { label: 'Borrow APY',       value: formatApy(BigInt(risk.debtBorrowRate)) },
              risk.liquidationPriceApplicable
                ? { label: 'Liq. Price',    value: `$${(Number(BigInt(risk.liquidationPrice)) / 1e8).toFixed(2)}` }
                : { label: 'Safety Buffer', value: `${(Number(BigInt(risk.bufferBps)) / 100).toFixed(1)} bps` },
              { label: 'Accrued Interest', value: accruedLabel, accent: true },
            ].map(({ label, value, accent }) => (
              <div key={label} className="bg-apple-bg rounded-xl p-3">
                <p className="text-[11px] text-apple-secondary mb-1">{label}</p>
                <p className={clsx('text-[13px] font-semibold tabular-nums', accent ? 'text-apple-red' : 'text-apple-label')}>{value}</p>
              </div>
            ))}
          </div>

          {/* Action tabs */}
          <div className="flex bg-apple-fill rounded-full p-1 gap-1">
            {(['repay', 'addCollateral', 'withdraw', 'borrow'] as const).map(a => (
              <button
                key={a}
                onClick={() => { setAction(a); setAmount(''); setApproveInput('') }}
                className={clsx(
                  'flex-1 py-1.5 rounded-full text-[11px] font-medium transition-all',
                  action === a ? 'bg-white text-apple-label shadow-apple-sm' : 'text-apple-secondary'
                )}
              >
                {ACTION_LABELS[a]}
              </button>
            ))}
          </div>

          {/* Amount input */}
          <div className="bg-apple-bg rounded-2xl p-4">
            <div className="flex items-center justify-between mb-2">
              <p className="text-[12px] text-apple-secondary">
                {action === 'repay'         ? `Repay ${debtToken?.symbol ?? ''}`
                 : action === 'addCollateral' ? `Add ${colToken?.symbol ?? ''} collateral`
                 : action === 'withdraw'      ? `Withdraw ${colToken?.symbol ?? ''} collateral`
                 : `Borrow more ${debtToken?.symbol ?? ''}`}
              </p>
              {action === 'repay' && debtToken && (
                <button
                  onClick={() => setAmount(formatToken(BigInt(risk.currentDebt), debtToken.decimals, debtToken.decimals))}
                  className="text-[12px] text-apple-blue font-medium hover:underline"
                >
                  Max
                </button>
              )}
            </div>
            <input
              type="number"
              min="0"
              placeholder="0.00"
              value={amount}
              onChange={e => setAmount(e.target.value)}
              className="w-full bg-transparent text-[22px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
            />
          </div>

          {/* Borrow-more HF preview */}
          {action === 'borrow' && parsedAmount > 0n && bmHf !== null && (
            <div className="bg-apple-bg rounded-2xl p-4 flex items-center justify-between">
              <span className="text-[12px] text-apple-secondary">Health Factor after borrow</span>
              <HealthBadge wad={bmHf} />
            </div>
          )}

          {/* Approve amount input — shown when approve step is needed */}
          {needsApprove && (
            <div className="bg-apple-bg rounded-2xl p-4 space-y-2">
              <div className="flex items-center justify-between">
                <p className="text-[12px] text-apple-secondary">
                  Approve amount ({approveToken?.symbol})
                </p>
                <button
                  onClick={() => setApproveInput(formatToken(parsedAmount, approveDecimals, approveDecimals))}
                  className="text-[12px] text-apple-blue font-medium hover:underline"
                >
                  Exact
                </button>
              </div>
              <input
                type="number"
                min="0"
                placeholder={formatToken(parsedAmount, approveDecimals, 4) + ' (exact)'}
                value={approveInput}
                onChange={e => setApproveInput(e.target.value)}
                className="w-full bg-transparent text-[18px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
              />
            </div>
          )}

          {needsApprove ? (
            <button
              onClick={handleApprove}
              disabled={busy || parsedAmount === 0n}
              className="w-full py-3 bg-apple-orange text-white rounded-full text-[14px] font-semibold disabled:opacity-40 transition-all"
            >
              {busy ? 'Approving…' : `Approve ${approveToken?.symbol}`}
            </button>
          ) : (
            <button
              onClick={handleAction}
              disabled={busy || parsedAmount === 0n}
              className="w-full py-3 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[14px] font-semibold disabled:opacity-40 transition-all"
            >
              {busy
                ? (isConfirming ? 'Confirming…' : 'Sending…')
                : action === 'repay'         ? 'Repay Debt'
                : action === 'addCollateral' ? 'Add Collateral'
                : action === 'withdraw'      ? 'Withdraw Collateral'
                : 'Borrow More'}
            </button>
          )}
        </div>
      )}
    </div>
  )
}
