# create-zilt-app

Zilt 桌面应用脚手架（Zig + 系统 WebView）。

```bash
npm create zilt-app my-app
npm create zilt-app my-app -- --template solid
```

可用模板：`vanilla` / `vue` / `react` / `svelte` / `solid` / `preact` / `htmx` / `angular`。

## 工作方式

1. 优先调用 `zilt new <dir> -t <template>`（PATH 中的 `zilt`，或 `ZILT_BIN` 指定）
2. 找不到 `zilt` 且当前目录是 Zilt 框架仓库根 → 回退 `zig build init`

脚手架产出是**完全自包含**的项目：`src/zilt`（框架源码）与 `src/tools` 一并 vendored，
之后用 `zig build run` / `zig build dev` / `zig build bundle` 即可。

## 环境要求

- [Zig 0.17.1+](https://ziglang.org/download/)
- Windows 10/11（WebView2 运行时，Win11 自带）
- 前端模板（vue/react/svelte/solid/preact/angular）需要 Node.js 18+ 与 npm
