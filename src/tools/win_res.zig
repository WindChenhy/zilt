//! Windows PE 资源生成（v0.1.15）：VERSIONINFO + 应用 manifest。
//!
//! 资源脚本（.rc）由 build 期插值生成，因此版本号/产品名/公司名始终与
//! `project.zig` 同源，不会出现「exe 属性里还是上个版本」的漂移。
//! manifest 单独放在 `src/zilt/assets/app.manifest`（静态内容，无版本号）。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    app_name: []const u8 = "Zilt",
    publisher: []const u8 = "Zilt",
    /// "0.1.14" / "1.2" / "1.2.3.4" 均可
    version: []const u8 = "0.1.0",
    exe_name: []const u8 = "zilt-app.exe",
    /// ICON 文件名（相对 include path）；null = 不写图标资源
    icon_file: ?[]const u8 = "zilt.ico",
    /// manifest 文件名（相对 include path）；null = 不嵌入
    manifest_file: ?[]const u8 = "app.manifest",
    /// 语言/代码页块（默认英文 US + Unicode）
    lang_id: u16 = 0x0409,
    codepage: u16 = 1200,
    /// 附加到 rc 顶部的注释（build 用它写入 manifest 哈希，保证内容变化触发重编）
    extra_comment: ?[]const u8 = null,
};

/// "0.1.14" → [4]u16{0,1,14,0}；缺省段补 0，超过 4 段截断。
pub fn versionTuple(version: []const u8) [4]u16 {
    var out = [4]u16{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, version, '.');
    var i: usize = 0;
    while (it.next()) |seg| : (i += 1) {
        if (i >= 4) break;
        // 允许 "14-beta" 这类后缀：只取前导数字
        var end: usize = 0;
        while (end < seg.len and seg[end] >= '0' and seg[end] <= '9') end += 1;
        if (end == 0) continue;
        out[i] = std.fmt.parseInt(u16, seg[0..end], 10) catch 0;
    }
    return out;
}

fn renderVersionQuad(buf: []u8, v: [4]u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d},{d},{d},{d}", .{ v[0], v[1], v[2], v[3] }) catch "0,0,0,0";
}

/// 生成资源脚本：图标 + VERSIONINFO（+ manifest 引用）。
pub fn renderRc(alloc: Allocator, opts: Options) ![]u8 {
    var vbuf: [32]u8 = undefined;
    const quad = renderVersionQuad(&vbuf, versionTuple(opts.version));
    const internal_name = blk: {
        const base = std.fs.path.basename(opts.exe_name);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        break :blk base[0..dot];
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    if (opts.extra_comment) |c| {
        const head = try std.fmt.allocPrint(alloc, "// {s}\n", .{c});
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
    }

    if (opts.icon_file) |icon| {
        const line = try std.fmt.allocPrint(alloc, "1 ICON \"{s}\"\n", .{icon});
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    if (opts.manifest_file) |mf| {
        // RT_MANIFEST = 24，id 1 = 进程级 manifest
        const line = try std.fmt.allocPrint(alloc, "1 24 \"{s}\"\n", .{mf});
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }

    try out.appendSlice(alloc, "\n1 VERSIONINFO\n");
    const hdr = try std.fmt.allocPrint(
        alloc,
        " FILEVERSION {s}\n PRODUCTVERSION {s}\n FILEFLAGSMASK 0x3fL\n FILEFLAGS 0x0L\n" ++
            " FILEOS 0x40004L\n FILETYPE 0x1L\n FILESUBTYPE 0x0L\nBEGIN\n",
        .{ quad, quad },
    );
    defer alloc.free(hdr);
    try out.appendSlice(alloc, hdr);

    const string_block = try std.fmt.allocPrint(
        alloc,
        "    BLOCK \"StringFileInfo\"\n    BEGIN\n        BLOCK \"{x:0>4}{x:0>4}\"\n        BEGIN\n" ++
            "            VALUE \"CompanyName\", \"{s}\"\n" ++
            "            VALUE \"FileDescription\", \"{s}\"\n" ++
            "            VALUE \"FileVersion\", \"{s}\"\n" ++
            "            VALUE \"InternalName\", \"{s}\"\n" ++
            "            VALUE \"OriginalFilename\", \"{s}\"\n" ++
            "            VALUE \"ProductName\", \"{s}\"\n" ++
            "            VALUE \"ProductVersion\", \"{s}\"\n" ++
            "        END\n    END\n" ++
            "    BLOCK \"VarFileInfo\"\n    BEGIN\n        VALUE \"Translation\", 0x{x:0>4}, {d}\n    END\nEND\n",
        .{
            opts.lang_id, opts.codepage,
            opts.publisher,
            opts.app_name,
            opts.version,
            internal_name,
            opts.exe_name,
            opts.app_name,
            opts.version,
            opts.lang_id, opts.codepage,
        },
    );
    defer alloc.free(string_block);
    try out.appendSlice(alloc, string_block);

    return out.toOwnedSlice(alloc);
}

/// 生成 manifest（供模板/未随包分发场景使用；repo 内使用静态 app.manifest）。
pub fn renderManifest(alloc: Allocator, opts: Options) ![]u8 {
    const v = versionTuple(opts.version);
    return std.fmt.allocPrint(
        alloc,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        \\  <assemblyIdentity type="win32" name="{s}" version="{d}.{d}.{d}.{d}" processorArchitecture="*"/>
        \\  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
        \\    <security>
        \\      <requestedPrivileges>
        \\        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
        \\      </requestedPrivileges>
        \\    </security>
        \\  </trustInfo>
        \\  <application xmlns="urn:schemas-microsoft-com:asm.v3">
        \\    <windowsSettings>
        \\      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
        \\      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
        \\      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
        \\    </windowsSettings>
        \\  </application>
        \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
        \\    <application>
        \\      <supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/>
        \\      <supportedOS Id="{{4f476546-937f-4d9b-b2f2-4d4d5aa10d28}}"/>
        \\    </application>
        \\  </compatibility>
        \\</assembly>
        \\
    , .{ opts.app_name, v[0], v[1], v[2], v[3] });
}

const testing = std.testing;

test "version tuple parsing" {
    try testing.expectEqual([4]u16{ 0, 1, 14, 0 }, versionTuple("0.1.14"));
    try testing.expectEqual([4]u16{ 1, 2, 3, 4 }, versionTuple("1.2.3.4"));
    try testing.expectEqual([4]u16{ 2, 0, 0, 0 }, versionTuple("2"));
    try testing.expectEqual([4]u16{ 0, 1, 14, 0 }, versionTuple("0.1.14-beta1"));
    try testing.expectEqual([4]u16{ 1, 2, 3, 4 }, versionTuple("1.2.3.4.5"));
    try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, versionTuple(""));
}

test "rc carries versioninfo, icon and manifest" {
    const rc = try renderRc(testing.allocator, .{
        .app_name = "Zilt",
        .publisher = "Zilt",
        .version = "0.1.14",
        .exe_name = "zilt-app.exe",
    });
    defer testing.allocator.free(rc);

    try testing.expect(std.mem.indexOf(u8, rc, "1 ICON \"zilt.ico\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "1 24 \"app.manifest\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "FILEVERSION 0,1,14,0") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "PRODUCTVERSION 0,1,14,0") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "VALUE \"CompanyName\", \"Zilt\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "VALUE \"ProductName\", \"Zilt\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "VALUE \"ProductVersion\", \"0.1.14\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "VALUE \"InternalName\", \"zilt-app\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "BLOCK \"040904b0\"") != null);
    try testing.expect(std.mem.indexOf(u8, rc, "VALUE \"Translation\", 0x0409, 1200") != null);
}

test "rc can omit icon and manifest" {
    const rc = try renderRc(testing.allocator, .{ .icon_file = null, .manifest_file = null, .version = "1.0" });
    defer testing.allocator.free(rc);
    try testing.expect(std.mem.indexOf(u8, rc, "ICON") == null);
    try testing.expect(std.mem.indexOf(u8, rc, "1 24") == null);
    try testing.expect(std.mem.indexOf(u8, rc, "FILEVERSION 1,0,0,0") != null);
}

test "manifest declares dpi, long path and supported os" {
    const mf = try renderManifest(testing.allocator, .{ .app_name = "Zilt", .version = "0.1.14" });
    defer testing.allocator.free(mf);
    try testing.expect(std.mem.indexOf(u8, mf, "PerMonitorV2") != null);
    try testing.expect(std.mem.indexOf(u8, mf, "longPathAware") != null);
    try testing.expect(std.mem.indexOf(u8, mf, "asInvoker") != null);
    try testing.expect(std.mem.indexOf(u8, mf, "version=\"0.1.14.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, mf, "8e0f7a12") != null); // Win10/11
}
