'use client'

import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from 'wagmi'
import clsx from 'clsx'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, TOKENS, type TokenSymbol } from '@/lib/contracts'
import { formatToken, formatApy, parseTokenInput } from '@/lib/format'
import { useUserDeposit, useReserveData } from '@/hooks/useUserPositions'
import { useMarkets } from '@/hooks/useMarkets'

const TOKEN_LIST = Object.values(TOKENS)

export function LendPanel() {
  const { address, isConnected } = useAccount()
  const [selected, setSelected] = useState<TokenSymbol>('USDC')
  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit')
  const [amount, setAmount] = useState('')
  const [approving, setApproving] = useState(false)

  const token = TOKENS[selected]
  const { data: scaledDeposit } = useUserDeposit(token.address)
  const { data: reserveData } = useReserveData(token.address)
  const { markets } = useMarkets()

  const supplyRate = markets.find(
    m => m.collateralAsset.toLowerCase() === token.address.toLowerCase()
  )?.supplyApyLabel ?? '—'

  // Compute actual balance from scaled deposit × liquidityIndex
  const userBalance = scaledDeposit && reserveData
    ? (BigInt(scaledDeposit as bigint) * BigInt((reserveData as any).liquidityIndex)) / BigInt('1000000000000000000000000000')
    : 0n

  // Token wallet balance
  const { data: walletBalance } = useReadContract({
    address: token.address,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  // Allowance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: token.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, LENDING_POOL_ADDRESS] : undefined,
    query: { enabled: !!address },
  })

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  const parsedAmount = parseTokenInput(amount, token.decimals)
  const needsApprove = tab === 'deposit' && (allowance as bigint ?? 0n) < parsedAmount

  function handleMax() {
    const bal = tab === 'deposit' ? (walletBalance as bigint ?? 0n) : userBalance
    setAmount(formatToken(bal, token.decimals, 6))
  }

  function handleApprove() {
    writeContract({
      address: token.address,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [LENDING_POOL_ADDRESS, parsedAmount],
    })
  }

  function handleSubmit() {
    if (tab === 'deposit') {
      writeContract({
        address: LENDING_POOL_ADDRESS,
        abi: LendingPoolABI,
        functionName: 'deposit',
        args: [token.address, parsedAmount],
      })
    } else {
      writeContract({
        address: LENDING_POOL_ADDRESS,
        abi: LendingPoolABI,
        functionName: 'withdraw',
        args: [token.address, parsedAmount],
      })
    }
    setAmount('')
  }

  const busy = isPending || isConfirming

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
      {/* Token selector */}
      <div className="flex gap-2 p-4 border-b border-apple-separator overflow-x-auto">
        {TOKEN_LIST.map(t => (
          <button
            key={t.symbol}
            onClick={() => { setSelected(t.symbol as TokenSymbol); setAmount('') }}
            className={clsx(
              'flex items-center gap-2 px-4 py-2 rounded-full text-[13px] font-medium whitespace-nowrap transition-all',
              selected === t.symbol
                ? 'bg-apple-label text-white shadow-apple-sm'
                : 'bg-apple-fill text-apple-secondary hover:text-apple-label'
            )}
          >
            <TokenIcon symbol={t.symbol} size="sm" />
            {t.symbol}
          </button>
        ))}
      </div>

      <div className="p-6 space-y-5">
        {/* Stats row */}
        <div className="grid grid-cols-3 gap-3">
          {[
            { label: 'Supply APY', value: supplyRate, green: true },
            { label: 'Your Deposit', value: formatToken(userBalance, token.decimals, 4) + ' ' + token.symbol },
            { label: 'Wallet Balance', value: formatToken((walletBalance as bigint) ?? 0n, token.decimals, 4) + ' ' + token.symbol },
          ].map(({ label, value, green }) => (
            <div key={label} className="bg-apple-bg rounded-2xl p-3.5">
              <p className="text-[11px] text-apple-secondary mb-1">{label}</p>
              <p className={clsx('text-[14px] font-semibold tabular-nums', green ? 'text-apple-green' : 'text-apple-label')}>{value}</p>
            </div>
          ))}
        </div>

        {/* Deposit / Withdraw tab */}
        <div className="flex bg-apple-fill rounded-full p-1">
          {(['deposit', 'withdraw'] as const).map(t => (
            <button
              key={t}
              onClick={() => { setTab(t); setAmount('') }}
              className={clsx(
                'flex-1 py-1.5 rounded-full text-[13px] font-medium capitalize transition-all',
                tab === t ? 'bg-white text-apple-label shadow-apple-sm' : 'text-apple-secondary'
              )}
            >
              {t}
            </button>
          ))}
        </div>

        {/* Amount input */}
        <div className="bg-apple-bg rounded-2xl p-4">
          <div className="flex items-center justify-between mb-2">
            <span className="text-[12px] text-apple-secondary font-medium">Amount</span>
            <button onClick={handleMax} className="text-[12px] text-apple-blue font-medium hover:underline">Max</button>
          </div>
          <div className="flex items-center gap-3">
            <input
              type="number"
              min="0"
              placeholder="0.00"
              value={amount}
              onChange={e => setAmount(e.target.value)}
              className="flex-1 bg-transparent text-[22px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
            />
            <div className="flex items-center gap-1.5 bg-white rounded-full px-3 py-1.5 shadow-apple-sm">
              <TokenIcon symbol={token.symbol} size="sm" />
              <span className="text-[13px] font-semibold text-apple-label">{token.symbol}</span>
            </div>
          </div>
        </div>

        {/* Action button */}
        {!isConnected ? (
          <p className="text-center text-[13px] text-apple-secondary py-1">Connect wallet to continue</p>
        ) : needsApprove ? (
          <button
            onClick={handleApprove}
            disabled={busy || parsedAmount === 0n}
            className="w-full py-3.5 bg-apple-orange text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all hover:brightness-105"
          >
            {busy ? 'Approving…' : `Approve ${token.symbol}`}
          </button>
        ) : (
          <button
            onClick={handleSubmit}
            disabled={busy || parsedAmount === 0n}
            className="w-full py-3.5 bg-apple-blue hover:bg-apple-blue-hover text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all"
          >
            {busy
              ? (isConfirming ? 'Confirming…' : 'Sending…')
              : tab === 'deposit' ? `Deposit ${token.symbol}` : `Withdraw ${token.symbol}`}
          </button>
        )}

        {isSuccess && (
          <p className="text-center text-[13px] text-apple-green font-medium">Transaction confirmed ✓</p>
        )}
      </div>
    </div>
  )
}
