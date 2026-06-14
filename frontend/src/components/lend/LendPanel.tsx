'use client'

import { useState, useEffect, useRef } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from 'wagmi'
import clsx from 'clsx'
import { TokenIcon } from '@/components/ui/TokenIcon'
import { LENDING_POOL_ADDRESS, LendingPoolABI, ERC20_ABI, TOKENS, type TokenSymbol } from '@/lib/contracts'
import { formatToken, formatApy, parseTokenInput } from '@/lib/format'
import { projectSupplyRate } from '@/lib/rateModel'
import { useUserDeposit, useReserveData } from '@/hooks/useUserPositions'
import { useMarkets } from '@/hooks/useMarkets'
import { useToast } from '@/lib/toast'

const TOKEN_LIST = Object.values(TOKENS)

export function LendPanel() {
  const { address, isConnected } = useAccount()
  const [selected, setSelected] = useState<TokenSymbol>('USDC')
  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit')
  const [amount, setAmount] = useState('')
  const [approveInput, setApproveInput] = useState('')
  const { showToast, updateToast } = useToast()
  const toastIdRef = useRef<string | null>(null)

  const token = TOKENS[selected]
  const { data: scaledDeposit } = useUserDeposit(token.address)
  const { data: reserveData } = useReserveData(token.address)
  const { markets } = useMarkets()

  const supplyRate = markets.find(
    m => m.collateralAsset.toLowerCase() === token.address.toLowerCase()
  )?.supplyApyLabel ?? '—'

  const RAY = BigInt('1000000000000000000000000000')
  const userBalance = scaledDeposit && reserveData
    ? (BigInt(scaledDeposit as bigint) * BigInt((reserveData as any).liquidityIndex)) / RAY
    : 0n

  const totalSupplied = reserveData
    ? (BigInt((reserveData as any).totalScaledSupply) * BigInt((reserveData as any).liquidityIndex)) / RAY
    : 0n
  const totalBorrowed = reserveData
    ? (BigInt((reserveData as any).totalScaledBorrow) * BigInt((reserveData as any).borrowIndex)) / RAY
    : 0n

  const { data: walletBalance } = useReadContract({
    address: token.address,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const { data: allowance } = useReadContract({
    address: token.address,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, LENDING_POOL_ADDRESS] : undefined,
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

  const parsedAmount = parseTokenInput(amount, token.decimals)
  const needsApprove = tab === 'deposit' && (allowance as bigint ?? 0n) < parsedAmount
  const parsedApproveAmount = approveInput
    ? parseTokenInput(approveInput, token.decimals)
    : parsedAmount

  const projectedRate =
    tab === 'deposit' && parsedAmount > 0n && reserveData
      ? projectSupplyRate(totalSupplied, totalBorrowed, parsedAmount)
      : null

  function handleMax() {
    const bal = tab === 'deposit' ? (walletBalance as bigint ?? 0n) : userBalance
    setAmount(formatToken(bal, token.decimals, 6))
  }

  function handleApprove() {
    const id = `approve-${token.symbol}-${Date.now()}`
    toastIdRef.current = id
    showToast(id, {
      title: `Approve ${token.symbol}`,
      description: `Allow LendingPool to spend ${token.symbol}`,
      status: 'pending',
    })
    writeContract({
      address: token.address,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [LENDING_POOL_ADDRESS, parsedApproveAmount],
    })
    setApproveInput('')
  }

  function handleSubmit() {
    const id = `${tab}-${token.symbol}-${Date.now()}`
    toastIdRef.current = id
    if (tab === 'deposit') {
      showToast(id, {
        title: `Deposit ${token.symbol}`,
        description: `${formatToken(parsedAmount, token.decimals, 4)} ${token.symbol} into pool`,
        status: 'pending',
      })
      writeContract({
        address: LENDING_POOL_ADDRESS,
        abi: LendingPoolABI,
        functionName: 'deposit',
        args: [token.address, parsedAmount],
      })
    } else {
      showToast(id, {
        title: `Withdraw ${token.symbol}`,
        description: `${formatToken(parsedAmount, token.decimals, 4)} ${token.symbol} from pool`,
        status: 'pending',
      })
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

  const [mounted, setMounted] = useState(false)
  useEffect(() => { setMounted(true) }, [])

  return (
    <div className="bg-apple-card rounded-3xl shadow-apple border border-apple-separator overflow-hidden">
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
        <div className="grid grid-cols-3 gap-3">
          {/* Supply APY — shows projected rate when deposit amount is entered */}
          <div className="bg-apple-bg rounded-2xl p-3.5">
            <p className="text-[11px] text-apple-secondary mb-1">
              {projectedRate !== null ? 'APY after deposit' : 'Supply APY'}
            </p>
            {projectedRate !== null ? (
              <div className="flex items-center gap-1">
                <p className="text-[12px] font-medium tabular-nums text-apple-tertiary line-through">{supplyRate}</p>
                <span className="text-apple-tertiary text-[10px]">→</span>
                <p className="text-[14px] font-semibold tabular-nums text-apple-green">{formatApy(projectedRate)}</p>
              </div>
            ) : (
              <p className="text-[14px] font-semibold tabular-nums text-apple-green">{supplyRate}</p>
            )}
          </div>
          {[
            { label: 'Your Deposit', value: formatToken(userBalance, token.decimals, 4) + ' ' + token.symbol },
            { label: 'Wallet Balance', value: formatToken((walletBalance as bigint) ?? 0n, token.decimals, 4) + ' ' + token.symbol },
          ].map(({ label, value }) => (
            <div key={label} className="bg-apple-bg rounded-2xl p-3.5">
              <p className="text-[11px] text-apple-secondary mb-1">{label}</p>
              <p className="text-[14px] font-semibold tabular-nums text-apple-label">{value}</p>
            </div>
          ))}
        </div>

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

        {!mounted || !isConnected ? (
          <p className="text-center text-[13px] text-apple-secondary py-1">Connect wallet to continue</p>
        ) : needsApprove ? (
          <div className="space-y-3">
            <div className="bg-apple-bg rounded-2xl p-4">
              <div className="flex items-center justify-between mb-2">
                <p className="text-[12px] text-apple-secondary">Approve amount ({token.symbol})</p>
                <button
                  onClick={() => setApproveInput(formatToken(parsedAmount, token.decimals, token.decimals))}
                  className="text-[12px] text-apple-blue font-medium hover:underline"
                >
                  Exact
                </button>
              </div>
              <input
                type="number"
                min="0"
                placeholder={formatToken(parsedAmount, token.decimals, 4) + ' (exact)'}
                value={approveInput}
                onChange={e => setApproveInput(e.target.value)}
                className="w-full bg-transparent text-[18px] font-semibold text-apple-label outline-none placeholder:text-apple-tertiary tabular-nums"
              />
            </div>
            <button
              onClick={handleApprove}
              disabled={busy || parsedAmount === 0n}
              className="w-full py-3.5 bg-apple-orange text-white rounded-full text-[15px] font-semibold disabled:opacity-40 transition-all hover:brightness-105"
            >
              {busy ? 'Approving…' : `Approve ${token.symbol}`}
            </button>
          </div>
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
      </div>
    </div>
  )
}
