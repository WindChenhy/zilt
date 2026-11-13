#!/usr/bin/env bash
# 开发辅助：在 WSL/容器里跑 zig build test（与 Windows 构建隔离缓存目录）。
# 用法：wsl -d Ubuntu-22.04 -- bash /mnt/d/Projects/ZigProjects/Zilt/scripts/linux/dev-test.sh
set -eu
cd "$(dirname "$0")/../.."

export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

exec zig build test "$@"
