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
/* v0.4.3 L1b：WebKit 头按 GTK 主版本选择。判据是 gtk/gtk.h 展开出的
 * GTK_MAJOR_VERSION——pkg-config 只注入**所选**包的 -I（gtk4 从不含 gtk-3.0
 * 目录，反之亦然），因此版本宏与实际链接库严格一致；两代 dev 包在
 * /usr/include 并存不影响判据（__has_include 才会撞上并存路径，L1a 实测）。
 * （L1a 曾用 ZILT_GTK4 构建期宏，但 define 需要额外接线且从未接入 build.zig，
 * `-Dgtk=gtk4` 在 translate-c 直接失败——改用 GTK_MAJOR_VERSION 后无需隐藏宏。） */
#if GTK_MAJOR_VERSION >= 4
#include <webkitgtk-6.0/webkit/webkit.h>
#else
#include <webkit2/webkit2.h>
#endif
/* v0.3.0：X11 焦点判定与 XID 提取。
 * GTK3 是 gdk_x11_window_get_xid；GTK4 改为 gdk/x11/gdkx.h 的
 * gdk_x11_surface_get_xid（L1b 起双栈统一走 gtk_compat 层）。 */
#if GTK_MAJOR_VERSION >= 4
#include <gdk/x11/gdkx.h>
#else
#include <gdk/gdkx.h>
#endif
/* 响应头（CSP / security.headers）需要 SoupMessageHeaders，
 * webkit2.h 虽然会顺带引入，但显式声明依赖更稳。 */
#include <libsoup/soup.h>
/* 全局快捷键（XGrabKey/XOpenDisplay，v0.2.6）
 * v0.4.3 L1b：窗口形状 mask（GDK4 无 shape API → XShape 直连，链接 libXext） */
#include <X11/Xlib.h>
#include <X11/extensions/shape.h>
/* v0.3.2：电源/会话事件（GDBus 订阅 org.freedesktop.login1） */
#include <gio/gio.h>
