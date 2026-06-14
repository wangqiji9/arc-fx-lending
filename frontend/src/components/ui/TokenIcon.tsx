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
    <div className="flex items-center gap-1.5">
      <div className="flex flex-col items-center gap-0.5">
        <TokenIcon symbol={col} size="sm" />
        <span className="text-[9px] text-apple-tertiary leading-none">Col</span>
      </div>
      <svg width="14" height="10" viewBox="0 0 14 10" fill="none" className="text-apple-tertiary flex-shrink-0">
        <path d="M1 5h12M8 1l4 4-4 4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
      <div className="flex flex-col items-center gap-0.5">
        <TokenIcon symbol={debt} size="sm" />
        <span className="text-[9px] text-apple-tertiary leading-none">Debt</span>
      </div>
    </div>
  )
}
