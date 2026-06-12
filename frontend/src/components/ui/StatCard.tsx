import clsx from 'clsx'

interface Props {
  label: string
  value: string
  sub?: string
  accent?: boolean
}

export function StatCard({ label, value, sub, accent }: Props) {
  return (
    <div className="bg-apple-card rounded-2xl p-5 shadow-apple border border-apple-separator">
      <p className="text-[12px] text-apple-secondary font-medium uppercase tracking-wider mb-1">{label}</p>
      <p className={clsx('text-[26px] font-semibold tracking-tight leading-none', accent ? 'text-apple-blue' : 'text-apple-label')}>
        {value}
      </p>
      {sub && <p className="text-[12px] text-apple-tertiary mt-1">{sub}</p>}
    </div>
  )
}
