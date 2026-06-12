import type { Config } from 'tailwindcss'

const config: Config = {
  content: ['./src/**/*.{js,ts,jsx,tsx,mdx}'],
  theme: {
    extend: {
      colors: {
        apple: {
          bg:        '#F5F5F7',
          card:      '#FFFFFF',
          label:     '#1D1D1F',
          secondary: '#6E6E73',
          tertiary:  '#86868B',
          separator: 'rgba(0,0,0,0.08)',
          blue:      '#0071E3',
          'blue-hover': '#0077ED',
          green:     '#30D158',
          orange:    '#FF9F0A',
          red:       '#FF3B30',
          fill:      'rgba(0,0,0,0.05)',
        },
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', '"SF Pro Display"', '"SF Pro Text"', 'system-ui', 'sans-serif'],
      },
      borderRadius: {
        '2xl': '18px',
        '3xl': '24px',
      },
      boxShadow: {
        apple:    '0 2px 20px rgba(0,0,0,0.06)',
        'apple-lg': '0 8px 40px rgba(0,0,0,0.10)',
        'apple-sm': '0 1px 4px rgba(0,0,0,0.06)',
      },
      backdropBlur: {
        apple: '20px',
      },
    },
  },
  plugins: [],
}

export default config
