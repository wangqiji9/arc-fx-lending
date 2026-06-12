import clsx from 'clsx'
import { formatHf, hfBgColor, wadToHf } from '@/lib/format'

export function HealthBadge({ wad }: { wad: bigint }) {
  const hf = wadToHf(wad)
  return (
    <span className={clsx('inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold tabular-nums', hfBgColor(wad))}>
      <span className="text-[8px]">●</span>
      {isFinite(hf) ? formatHf(wad) : '∞'}
    </span>
  )
}
