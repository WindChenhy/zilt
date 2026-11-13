/* Zilt Linux 的 C API 入口（v0.2.0）
 *
 * Zig 0.17 移除了 @cImport，改为构建期 translate-c：
 *   build.zig -> addTranslateC(capi.h) -> 模块 "gtk"
 * 所以这里只做头文件聚合，不放任何逻辑；需要新的 GTK/WebKit API 时
 * 直接改 src/zilt/platform/linux/backend.zig 里的 c.xxx 调用即可。
 *
 * 依赖（Ubuntu/Debian）：libgtk-3-dev libwebkit2gtk-4.1-dev pkg-config
 * 头文件路径由 build.zig 通过 pkg-config --cflags-only-I 注入。
 */
#pragma once

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
/* 响应头（CSP / security.headers）需要 SoupMessageHeaders，
 * webkit2.h 虽然会顺带引入，但显式声明依赖更稳。 */
#include <libsoup/soup.h>
/* 全局快捷键（XGrabKey/XOpenDisplay，v0.2.6） */
#include <X11/Xlib.h>
