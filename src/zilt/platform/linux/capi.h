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
/* v0.3.0：X11 焦点判定（gdk_x11_window_get_xid / gdk_x11_display_get_xdisplay）。
 * GTK4 的 X11 API 是 gdk_x11_surface_get_xid（v0.3.x 重做后端时再适配）——
 * 这里对 GTK3 引入，GTK4 构建下由 @hasDecl 回退到 GTK 焦点属性。 */
#if !defined(GTK_MAJOR_VERSION) || GTK_MAJOR_VERSION < 4
#include <gdk/gdkx.h>
#endif
/* 响应头（CSP / security.headers）需要 SoupMessageHeaders，
 * webkit2.h 虽然会顺带引入，但显式声明依赖更稳。 */
#include <libsoup/soup.h>
/* 全局快捷键（XGrabKey/XOpenDisplay，v0.2.6） */
#include <X11/Xlib.h>
/* v0.3.2：电源/会话事件（GDBus 订阅 org.freedesktop.login1） */
#include <gio/gio.h>
