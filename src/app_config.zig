//! 示例应用配置（命令 + 事件 + 内嵌资产）。主程序与 gen 工具共用。
//! 资产表由 build.zig 资产 codegen 从 frontend dist 自动生成（zilt_assets 模块）。

const std = @import("std");
const zilt = @import("zilt");

/// v0.3.10 C2：isolation 演示密钥（64 字符 hex = 32 字节；生产应用应自行生成并保守）
pub const iso_key_hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

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
            // v0.3.8 B8：POST 经表单导航——Chromium 的 fetch/XHR 只允许 http(s)/
            // blob/data 等 scheme（自定义 scheme 的请求根本不会发出，与 CORS 无关；
            // 实测 /inner fetch 也不达处理器）；表单导航是文档级导航，body 经
            // get_Content 链路读取。DOMContentLoaded 后提交（脚本先于 body 存在）。
            "document.addEventListener('DOMContentLoaded',function(){" ++
            "var f=document.createElement('form');" ++
            "f.method='POST';f.action='/inner-post?relay=1';" ++
            "var h=document.createElement('input');h.name='probe';h.value='ok';" ++
            "f.appendChild(h);document.body.appendChild(f);f.submit();" ++
            "});" ++
            "</script>"),
        };
    }
    // v0.3.8 B8：表单 POST 的落点（HTML 自报 body——iframe 内脚本文档级导航回传）
    if (std.mem.endsWith(u8, req.path, "inner-post")) {
        const b = req.body orelse "";
        // 仅转义 JS 字符串敏感字符（' 与 \；冒烟载荷为纯 ASCII 表单体）
        var esc: std.ArrayListUnmanaged(u8) = .empty;
        for (b) |c| {
            switch (c) {
                '\'' => try esc.appendSlice(alloc, "\\'"),
                '\\' => try esc.appendSlice(alloc, "\\\\"),
                else => try esc.append(alloc, c),
            }
        }
        return .{
            .content_type = "text/html; charset=utf-8",
            .body = try std.fmt.allocPrint(alloc,
                "<!doctype html><script>parent.postMessage({{postOk:true,body:'{s}'}},'*');</script>", .{esc.items}),
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

/// v0.3.8 B8：POST body 回显（`/__proto/postecho/<path>` 或真 scheme `postecho://`）
/// → `post|<len>|<body>`。验证 get_Content（Windows）/ http_body（Linux）读取链路。
fn protocolPostEcho(req: zilt.protocol.Request, alloc: std.mem.Allocator) anyerror!zilt.protocol.Response {
    const b = req.body orelse "";
    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = try std.fmt.allocPrint(alloc, "post|{d}|{s}", .{ b.len, b }),
        .headers = &.{.{ .name = "X-Proto-Body", .value = "yes" }},
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
    .{ .name = "postecho", .handle = protocolPostEcho },
};
