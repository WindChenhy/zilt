import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Zilt 约定：固定端口（project.zig 的 dev_url 与此对应）
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    // 显式 HMR 目标：dev 反代模式下页面 origin 为应用自身（custom scheme），
    // @vite/client 需直连 vite ws 才能热更新（dev-url 直连模式下亦正确）
    hmr: { protocol: 'ws', host: 'localhost', port: 1420 },
  },
  build: { outDir: 'dist' },
});
