import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Zilt 约定：固定端口（project.zig 的 dev_url 与此对应）
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { outDir: 'dist' },
});
