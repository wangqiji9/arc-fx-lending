import type { Metadata } from 'next'
import { Providers } from '@/components/layout/Providers'
import { Header } from '@/components/layout/Header'
import { NetworkBanner } from '@/components/layout/NetworkBanner'
import './globals.css'

export const metadata: Metadata = {
  title: 'Arc FX Lending',
  description: 'Multi-currency lending protocol on Arc — Standard and FX E-Mode markets',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <Providers>
          <Header />
          <NetworkBanner />
          <main className="min-h-screen bg-apple-bg">
            {children}
          </main>
        </Providers>
      </body>
    </html>
  )
}
