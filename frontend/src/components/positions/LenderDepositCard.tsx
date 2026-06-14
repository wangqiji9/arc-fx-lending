'use client'

import { useState, useEffect, useRef } from 'react'
import { useWriteContract, useWaitForTransactionReceipt, useReadContract, useAccount } from 'wagmi'
import clsx from 'clsx'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI } from '@/lib/contracts'
import { formatToken, formatApy, parseTokenInput } from '@/lib/format'
import { useToast } from '@/lib/toast'

interface Props {
  asset: `0x${string}`
  symbol: string
  decimals: number
  currentValue: bigint
  principal: bigint
  earned: bigint
  supplyRate: bigint
}

export function LenderDepositCard({ asset, symbol, decimals, currentValue, principal: _principal, earned, supplyRate }: Props) {
  const { address } = useAccount()
  const [open, setOpen] = useState(false)
  const [amount, setAmount] = useState('')
  const { showToast, updateToast } = useToast()
  const toastIdRef = useRef<string | null>(null)

  const { data: walletBalance } = useReadContract({
    address: asset,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

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
  }, [isSuccess])

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
  const parsedAmount = parseTokenInput(amount, decimals)

  function handleMax() {
    setAmount(formatToken(currentValue, decimals, 6))
  }

  function handleWithdraw() {
    const id = `withdraw-${symbol}-${Date.now()}`
    toastIdRef.current = id
    showToast(id, {
      title: `Withdraw ${symbol}`,
      description: `${formatToken(parsedAmount, decimals, 4)} ${symbol} from pool`,
      status: 'pending',
    })
    writeContract({
      address: LENDING_POOL_ADDRESS,
      abi: LendingPoolABI,
      functionName: 'withdraw',
      args: [asset, parsedAmount],
    })
    setAmount('')
  }

  const earnedLabel = earned > 0n
    ? `+${formatToken(earned, decimals, 4)} ${symbol}`
    : `+0 ${symbol}`

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between p-5 hover:bg-apple-fill/30 transition-colors"
      >
        <div className="flex items-center gap-3">
          <TokenIcon symbol={symbol} />
          <div className="text-left">
            <p className="text-[15px] font-semibold text-apple-label">{symbol} Deposit</p>
            <p className="text-[12px] text-apple-secondary mt-0.5">
              Supply APY: <span className="text-apple-green font-medium">{formatApy(supplyRate)}</span>
            </p>
          </div>
        </div>

        <div className="flex items-center gap-4">
          <div className="text-right">
            <p className="text-[12px] text-apple-secondary mb-0.5">Balance</p>
            <p className="text-[14px] font-semibold text-apple-label tabular-nums">
              {formatToken(currentValue, decimals, 4)} {symbol}
            </p>
            <p className="text-[11px] text-apple-green font-medium tabular-nums mt-0.5">{earnedLabel}</p>
          </div>
          <span className={clsx('text-apple-secondary transition-transform', open && 'rotate-180')}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <path d="M4 6l4 4 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
        </div>
      </button>

      {open && (
        <div className="px-5 pb-5 space-y-4 border-t border-apple-separator pt-4">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {[
              { label: 'Deposit Value', value: `${formatToken(currentValue, decimals, 4)} ${symbol}` },
              { label: 'Earned', value: earnedLabel, green: true },
              { label: 'Supply APY', value: formatApy(supplyRate), green: true },
              { label: 'Wallet Balance', value: `${formatToken((walletBalance as bigint) ?? 0n, decimals, 4)} ${symbol}` },
            ].map(({ label, value, green }) => (
              <div key={label} className="bg-apple-bg rounded-xl p-3">
                <p className="text-[11px] text-apple-secondary mb-1">{label}</p>
                <p className={clsx('text-[13px] font-semibold tabular-nums', green ? 'text-apple-green' : 'text-apple-label')}>{value}</p>
              </div>
            ))}
          </div>

          <div className="bg-apple-bg rounded-2xl p-4">
            <div className="flex items-center justify-between mb-2">
              <p className="text-[12px] text-apple-secondary">Withdraw {symbol}</p>
              <button onClick={handleMax} className="text-[12px] text-apple-blue font-medium hover:underline">Max</button>
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

          <button
            onClick={handleWithdraw}
            disabled={busy || parsedAmount === 0n}
            className="w-full py-3 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[14px] font-semibold disabled:opacity-40 transition-all"
          >
            {busy ? (isConfirming ? 'Confirming…' : 'Sending…') : `Withdraw ${symbol}`}
          </button>
        </div>
      )}
    </div>
  )
}
