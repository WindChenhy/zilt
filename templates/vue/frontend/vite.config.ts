import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// Zilt 约定：固定端口（project.zig 的 dev_url 与此对应）
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { outDir: 'dist' },
});
