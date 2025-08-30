import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'My Next.js Project',
  description: 'Created with Coder workspace template',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}