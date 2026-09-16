import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      // Same-origin in dev, so the session cookie just works.
      '/api': { target: process.env.VITE_API_TARGET ?? 'http://localhost:3001', changeOrigin: true,
                rewrite: (p) => p.replace(/^\/api/, '') },
    },
  },
})
