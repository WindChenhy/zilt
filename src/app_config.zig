//! 示例应用配置（命令 + 事件 + 内嵌资产）。主程序与 gen 工具共用。
//! 资产表由 build.zig 资产 codegen 从 frontend dist 自动生成（zilt_assets 模块）。

const std = @import("std");
const zilt = @import("zilt");

pub const commands = @import("commands.zig");
pub const events = @import("events.zig");

pub const assets = @import("zilt_assets").assets;

/// v0.1.8/v0.1.11：CSP/导航白名单/capability ACL。构建时生成
/// frontend/bindings/capabilities.json，运行时按同一份声明强制。
pub const security: zilt.security.Options = .{    .capabilities = &.{.{
        .name = "demo-local",
        .windows = &.{"*"},
        .commands = &.{"*"},
        .events = &.{"*"},
        .receive_events = &.{"*"},
        // v0.1.21：资源 scope（fs/http/shell）。声明后进入强制模式；
        // 应用私有目录（appData/appConfig/appCache）始终可用。
        .scopes = &.{
            "fs:appData/**",
            "fs:appCache/**",
            "fs:appConfig/**",
            "http:http://127.0.0.1:*",
            "http:ws://127.0.0.1:*",
            "http:wss://127.0.0.1:*",
            "shell:cmd",
            // v0.3.0：Linux 冒烟的子进程检查（/bin/echo；cmd 为 Windows 侧用）
            "shell:echo",
            "shell:sh",
        },
    }},
    // v0.1.21：冻结 window.zilt + 内建原型（防原型链篡改）
    .freeze_prototype = true,
    .deny_commands = &.{"blockedDemo"}, // 冒烟用：未授权命令须返回 PermissionDenied
    .navigation_origins = &.{"https://zilt.app"},
    .external_links = .system_browser,
};

// ---------------------------------------------------------------------------
// v0.1.24：应用自定义协议（`https://zilt.app/__proto/<name>/…`）
// ---------------------------------------------------------------------------

/// 回显：`/__proto/echo/<path>?<query>` → `echo|<path>|<query>|<method>|<ua>`
fn protocolEcho(req: zilt.protocol.Request, alloc: std.mem.Allocator) anyerror!zilt.protocol.Response {
    // v0.3.2：真 scheme 的 CORS 探针——WebView2 实测：https 页面 fetch 自定义
    // scheme（authority 模式）即使响应带 Access-Control-Allow-Origin 也被 CORS
    // 判定拒绝（iframe 导航正常）；同 scheme origin 的请求"总是允许"（官方
    // spec），所以冒烟经 iframe 内同源 fetch + postMessage 中继拿响应体。
    // Chromium 规范化会在 authority 空路径后补 '/'（echo://x → echo://x/），
    // 且 authority 段并入 path（echo://a/cors-probe → path=a/cors-probe）——
    // 所以此处用 endsWith 匹配。
    if (std.mem.endsWith(u8, req.path, "cors-probe")) {
        return .{
            .content_type = "text/html; charset=utf-8",
            .body = try alloc.dupe(u8,
            "<!doctype html><script>" ++
            "fetch('/inner?relay=1').then(function(r){return r.text();})" ++
            ".then(function(t){parent.postMessage({ok:true,body:t},'*');})" ++
            ".catch(function(e){parent.postMessage({ok:false,error:String(e)},'*');});" ++
            "</script>"),
        };
    }
    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = try std.fmt.allocPrint(alloc, "echo|{s}|{s}|{s}|{s}", .{
            req.path, req.query, req.method, req.user_agent orelse "-",
        }),
        .headers = &.{.{ .name = "X-Proto", .value = "zilt" }},
    };
}

/// JSON：验证内容类型与状态码自定义
fn protocolJson(req: zilt.protocol.Request, alloc: std.mem.Allocator) anyerror!zilt.protocol.Response {
    _ = req;
    return .{
        .status = 201,
        .content_type = "application/json",
        .body = try alloc.dupe(u8, "{\"proto\":true,\"framework\":\"zilt\"}"),
    };
}

/// 二进制：验证非文本体（4 字节 0x00 0x01 0xFE 0xFF）
fn protocolBin(req: zilt.protocol.Request, alloc: std.mem.Allocator) anyerror!zilt.protocol.Response {
    _ = req;
    const bytes = try alloc.alloc(u8, 4);
    @memcpy(bytes, &[_]u8{ 0x00, 0x01, 0xfe, 0xff });
    return .{ .content_type = "application/octet-stream", .body = bytes };
}

pub const protocols = [_]zilt.protocol.Protocol{
    .{ .name = "echo", .handle = protocolEcho },
    .{ .name = "json", .handle = protocolJson },
    .{ .name = "bin", .handle = protocolBin },
};
