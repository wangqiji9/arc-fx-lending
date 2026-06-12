'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import clsx from 'clsx'

const NAV = [
  { href: '/',          label: 'Markets'   },
  { href: '/lend',      label: 'Supply'    },
  { href: '/borrow',    label: 'Borrow'    },
  { href: '/positions', label: 'Positions' },
]

export function Header() {
  const pathname = usePathname()

  return (
    <header className="sticky top-0 z-50 bg-white/80 backdrop-blur-apple border-b border-apple-separator">
      <div className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
        {/* Logo */}
        <Link href="/" className="flex items-center gap-2.5">
          <div className="w-7 h-7 rounded-lg bg-apple-blue flex items-center justify-center">
            <span className="text-white text-xs font-semibold">FX</span>
          </div>
          <span className="text-apple-label font-semibold text-[15px] tracking-tight">Arc Lending</span>
        </Link>

        {/* Nav */}
        <nav className="hidden md:flex items-center gap-1">
          {NAV.map(({ href, label }) => {
            const active = pathname === href
            return (
              <Link
                key={href}
                href={href}
                className={clsx(
                  'px-3.5 py-1.5 rounded-full text-[13px] font-medium transition-colors',
                  active
                    ? 'bg-apple-fill text-apple-label'
                    : 'text-apple-secondary hover:text-apple-label hover:bg-apple-fill/50'
                )}
              >
                {label}
              </Link>
            )
          })}
        </nav>

        {/* Wallet */}
        <ConnectButton
          showBalance={false}
          chainStatus="icon"
          accountStatus="avatar"
        />
      </div>
    </header>
  )
}
