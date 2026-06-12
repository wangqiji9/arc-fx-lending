'use client'

import { useState } from 'react'
import { useWriteContract, useWaitForTransactionReceipt, useReadContract, useAccount } from 'wagmi'
import clsx from 'clsx'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { HealthBadge } from '@/components/ui/HealthBadge'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, tokenByAddress } from '@/lib/contracts'
import { formatToken, formatUsd, formatApy, parseTokenInput } from '@/lib/format'

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

export function PositionCard({ risk }: { risk: PositionRisk }) {
  const { address } = useAccount()
  const [open, setOpen] = useState(false)
  const [action, setAction] = useState<'repay' | 'addCollateral' | 'withdraw'>('repay')
  const [amount, setAmount] = useState('')

  const { data: posData } = useReadContract({
    address: LENDING_POOL_ADDRESS,
    abi: LendingPoolABI,
    functionName: 'getPosition',
    args: [risk.key],
  })
  const pos = posData as Position | undefined

  const colToken  = pos ? tokenByAddress(pos.collateralAsset) : undefined
  const debtToken = pos ? tokenByAddress(pos.debtAsset) : undefined

  // Allowance for repay (debtAsset)
  const { data: repayAllowance } = useReadContract({
    address: debtToken?.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address && debtToken ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address && !!debtToken },
  })

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  const busy = isPending || isConfirming
  const parsedAmount = parseTokenInput(amount, action === 'repay' ? (debtToken?.decimals ?? 6) : (colToken?.decimals ?? 18))

  const needsApprove = action === 'repay' && (repayAllowance as bigint ?? 0n) < parsedAmount

  if (!risk.exists || !pos) return null

  function handleApprove() {
    writeContract({ address: debtToken!.address, abi: ERC20_ABI, functionName: 'approve', args: [LENDING_POOL_ADDRESS, parsedAmount] })
  }

  function handleAction() {
    if (!address || !pos) return
    if (action === 'repay') {
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'repay',
        args: [address, pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    } else if (action === 'addCollateral') {
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'addCollateral',
        args: [pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    } else {
      writeContract({
        address: LENDING_POOL_ADDRESS, abi: LendingPoolABI, functionName: 'withdrawCollateral',
        args: [pos.collateralAsset, pos.debtAsset, parsedAmount],
      })
    }
    setAmount('')
  }

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
      {/* Header */}
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between p-5 hover:bg-apple-fill/30 transition-colors"
      >
        <div className="flex items-center gap-4">
          {/* Token pair icons */}
          <div className="flex -space-x-2">
            {colToken && <TokenIcon symbol={colToken.symbol} />}
            {debtToken && <TokenIcon symbol={debtToken.symbol} size="sm" />}
          </div>
          <div className="text-left">
            <p className="text-[15px] font-semibold text-apple-label">
              {colToken?.symbol ?? '?'} → {debtToken?.symbol ?? '?'}
            </p>
            <p className="text-[12px] text-apple-secondary mt-0.5">
              {colToken && formatToken(BigInt(pos.collateralAmount), colToken.decimals, 4)} {colToken?.symbol} collateral
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
          {/* Stats grid */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {[
              { label: 'Collateral Value', value: formatUsd(BigInt(risk.collateralValue)) },
              { label: 'Debt Value',       value: formatUsd(BigInt(risk.debtValue)) },
              { label: 'Borrow APY',       value: formatApy(BigInt(risk.debtBorrowRate)) },
              risk.liquidationPriceApplicable
                ? { label: 'Liq. Price', value: `$${(Number(BigInt(risk.liquidationPrice)) / 1e8).toFixed(2)}` }
                : { label: 'Safety Buffer', value: `${(Number(BigInt(risk.bufferBps)) / 100).toFixed(1)} bps` },
            ].map(({ label, value }) => (
              <div key={label} className="bg-apple-bg rounded-xl p-3">
                <p className="text-[11px] text-apple-secondary mb-1">{label}</p>
                <p className="text-[13px] font-semibold text-apple-label tabular-nums">{value}</p>
              </div>
            ))}
          </div>

          {/* Action tabs */}
          <div className="flex bg-apple-fill rounded-full p-1 gap-1">
            {(['repay', 'addCollateral', 'withdraw'] as const).map(a => (
              <button
                key={a}
                onClick={() => { setAction(a); setAmount('') }}
                className={clsx(
                  'flex-1 py-1.5 rounded-full text-[12px] font-medium transition-all',
                  action === a ? 'bg-white text-apple-label shadow-apple-sm' : 'text-apple-secondary'
                )}
              >
                {a === 'addCollateral' ? 'Add Collateral' : a === 'withdraw' ? 'Withdraw Col.' : 'Repay'}
              </button>
            ))}
          </div>

          {/* Amount input */}
          <div className="bg-apple-bg rounded-2xl p-4">
            <p className="text-[12px] text-apple-secondary mb-2">
              {action === 'repay'
                ? `Repay ${debtToken?.symbol ?? ''}`
                : action === 'addCollateral'
                ? `Add ${colToken?.symbol ?? ''} collateral`
                : `Withdraw ${colToken?.symbol ?? ''} collateral`}
            </p>
            <input
              type="number"
              min="0"
              placeholder="0.00"
              value={amount}
              onChange={e => setAmount(e.target.value)}
              className="w-full bg-transparent text-[22px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
            />
          </div>

          {needsApprove ? (
            <button
              onClick={handleApprove}
              disabled={busy || parsedAmount === 0n}
              className="w-full py-3 bg-apple-orange text-white rounded-full text-[14px] font-semibold disabled:opacity-40 transition-all"
            >
              {busy ? 'Approving…' : `Approve ${debtToken?.symbol}`}
            </button>
          ) : (
            <button
              onClick={handleAction}
              disabled={busy || parsedAmount === 0n}
              className="w-full py-3 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[14px] font-semibold disabled:opacity-40 transition-all"
            >
              {busy
                ? (isConfirming ? 'Confirming…' : 'Sending…')
                : action === 'repay' ? 'Repay Debt'
                : action === 'addCollateral' ? 'Add Collateral'
                : 'Withdraw Collateral'}
            </button>
          )}

          {isSuccess && (
            <p className="text-center text-[13px] text-apple-green font-medium">Transaction confirmed ✓</p>
          )}
        </div>
      )}
    </div>
  )
}
