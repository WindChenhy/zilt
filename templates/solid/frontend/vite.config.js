import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';

export default defineConfig({
  plugins: [solid()],
  // 相对 base：应用以自定义 scheme 加载资产（/index.html），绝对路径会解析失败
  base: './',
  server: { port: 1420, strictPort: true },
  build: { outDir: 'dist', emptyOutDir: true },
});
