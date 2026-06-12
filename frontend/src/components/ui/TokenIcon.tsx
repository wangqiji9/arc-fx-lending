import clsx from 'clsx'

const COLORS: Record<string, string> = {
  USDC: 'bg-blue-500',
  EURC: 'bg-indigo-500',
  WETH: 'bg-gray-600',
}

export function TokenIcon({ symbol, size = 'md' }: { symbol: string; size?: 'sm' | 'md' | 'lg' }) {
  const sz = size === 'sm' ? 'w-6 h-6 text-[9px]' : size === 'lg' ? 'w-10 h-10 text-[13px]' : 'w-8 h-8 text-[11px]'
  return (
    <div className={clsx('rounded-full flex items-center justify-center text-white font-bold', sz, COLORS[symbol] ?? 'bg-apple-tertiary')}>
      {symbol.slice(0, 2)}
    </div>
  )
}

export function TokenPair({ col, debt }: { col: string; debt: string }) {
  return (
    <div className="flex items-center">
      <TokenIcon symbol={col} />
      <div className="-ml-2">
        <TokenIcon symbol={debt} size="sm" />
      </div>
    </div>
  )
}
