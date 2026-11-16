//! 打包器核心（Phase 3，Windows）：
//!  - ZipWriter：store 方法（不压缩）的最小 zip 写入器（CRC-32 由 std.hash 提供）
//!  - NSIS 安装器脚本生成：per-user 安装 + 开始菜单/桌面快捷方式 + 卸载器
//!    + WebView2 运行时检测与 Evergreen 引导（下载 bootstrapper 静默安装）
//!
//! 设计取舍（v0.1.0）：store-only zip 体积稍大但零依赖、实现可测；
//! NSIS 通过外部 makensis 调用（本机有则产出 setup.exe，无则仅生成 .nsi 并提示）。

const std = @import("std");

// ---------------------------------------------------------------------------
// Zip 写入器（store-only）
// ---------------------------------------------------------------------------

/// 一条待写入的文件。
pub const ZipEntry = struct {
    /// zip 内路径（用 '/' 分隔）
    name: []const u8,
    content: []const u8,
};

/// 把 entries 写成 zip 归档（store 方法）。写入 buffer。
/// 结构：[local file header + data]... [central directory] [EOCD]
pub fn writeZip(alloc: std.mem.Allocator, entries: []const ZipEntry, out: *std.ArrayList(u8)) !void {
    const w = out;

    const CentralOffset = struct { offset: u64, name: []const u8, crc: u32, size: u64 };

    var centrals = try alloc.alloc(CentralOffset, entries.len);
    defer alloc.free(centrals);

    var offset: u64 = 0;
    for (entries, 0..) |e, i| {
        const name_len = e.name.len;
        const crc = std.hash.Crc32.hash(e.content);
        const size: u64 = e.content.len;

        // local file header（PK\x03\x04）
        try appendU32(alloc, w, 0x04034b50);
        try appendU16(alloc, w, 20); // version needed
        try appendU16(alloc, w, 0x0800); // flags: UTF-8 文件名
        try appendU16(alloc, w, 0); // method: store
        try appendU16(alloc, w, 0); // mod time（固定值，确定性构建）
        try appendU16(alloc, w, 0x21); // mod date（1980-01-01）
        try appendU32(alloc, w, crc);
        try appendU32(alloc, w, @intCast(size)); // compressed
        try appendU32(alloc, w, @intCast(size)); // uncompressed
        try appendU16(alloc, w, @intCast(name_len));
        try appendU16(alloc, w, 0); // extra len
        try w.appendSlice(alloc, e.name);
        try w.appendSlice(alloc, e.content);

        centrals[i] = .{ .offset = offset, .name = e.name, .crc = crc, .size = size };
        offset += 30 + name_len + size;
    }

    // central directory（PK\x01\x02）
    const cd_start = offset;
    for (centrals) |c| {
        try appendU32(alloc, w, 0x02014b50);
        try appendU16(alloc, w, 20); // version made by
        try appendU16(alloc, w, 20); // version needed
        try appendU16(alloc, w, 0x0800);
        try appendU16(alloc, w, 0); // store
        try appendU16(alloc, w, 0);
        try appendU16(alloc, w, 0x21);
        try appendU32(alloc, w, c.crc);
        try appendU32(alloc, w, @intCast(c.size));
        try appendU32(alloc, w, @intCast(c.size));
        try appendU16(alloc, w, @intCast(c.name.len));
        try appendU16(alloc, w, 0); // extra
        try appendU16(alloc, w, 0); // comment
        try appendU16(alloc, w, 0); // disk
        try appendU16(alloc, w, 0); // internal attrs
        try appendU32(alloc, w, 0); // external attrs
        try appendU32(alloc, w, @intCast(c.offset));
        try w.appendSlice(alloc, c.name);
        offset += 46 + c.name.len;
    }
    const cd_size = offset - cd_start;

    // EOCD（PK\x05\x06）
    try appendU32(alloc, w, 0x06054b50);
    try appendU16(alloc, w, 0);
    try appendU16(alloc, w, 0);
    try appendU16(alloc, w, @intCast(entries.len));
    try appendU16(alloc, w, @intCast(entries.len));
    try appendU32(alloc, w, @intCast(cd_size));
    try appendU32(alloc, w, @intCast(cd_start));
    try appendU16(alloc, w, 0);
}

fn appendU16(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(alloc, &.{ @intCast(v & 0xff), @intCast(v >> 8) });
}
fn appendU32(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(alloc, &.{
        @intCast(v & 0xff),
        @intCast((v >> 8) & 0xff),
        @intCast((v >> 16) & 0xff),
        @intCast((v >> 24) & 0xff),
    });
}

// ---------------------------------------------------------------------------
// NSIS 安装器脚本生成
// ---------------------------------------------------------------------------

pub const InstallerConfig = struct {
    app_name: []const u8,
    version: []const u8,
    publisher: []const u8,
    exe_name: []const u8,
    /// 卸载表项 ID（建议形如 "Name.appid"）
    app_id: []const u8,
    /// setup.exe 输出路径（写入 OutFile）
    out_path: []const u8,
    /// 要打包的 exe 绝对路径（写入 File 指令）
    exe_path: []const u8,
    /// v0.3.4：侧车资源目录（相对项目根；null/空 = 不打包）。生成
    /// SetOutPath + File /r 片段（resources 子目录布局与 build install 一致）。
    resources: ?[]const u8 = null,
    // ---- v0.1.15 安装器增强 ----
    /// per-machine 安装（Program Files + HKLM + 需要管理员）；默认 per-user
    per_machine: bool = false,
    /// 许可证文件（编译期 LicenseData，显示 License 页）；null = 不显示
    license_path: ?[]const u8 = null,
    /// setup.exe 图标路径；null = 不设置
    setup_icon: ?[]const u8 = null,
    /// 安装时注册的 URL 协议（如 "zilt"）
    schemes: []const []const u8 = &.{},
    /// 安装时注册的文件关联扩展名（如 ".zilt"）
    file_exts: []const []const u8 = &.{},
};

/// NSIS 字符串转义（$\ = 双引号，$$ = 字面 $）。
pub fn nsisEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "$\\"),
            '$' => try buf.appendSlice(alloc, "$$"),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// 生成 NSIS 安装脚本（per-user 安装、无需管理员）。
pub fn generateNsis(alloc: std.mem.Allocator, cfg: InstallerConfig) ![]u8 {
    const name = try nsisEscape(alloc, cfg.app_name);
    const version = try nsisEscape(alloc, cfg.version);
    const publisher = try nsisEscape(alloc, cfg.publisher);
    const exe_name = try nsisEscape(alloc, cfg.exe_name);
    const app_id = try nsisEscape(alloc, cfg.app_id);
    const out_path = try nsisEscape(alloc, cfg.out_path);
    const exe_path = try nsisEscape(alloc, cfg.exe_path);
    const escaped = [_][]u8{ name, version, publisher, exe_name, app_id, out_path, exe_path };
    defer for (escaped) |e| alloc.free(e);

    // 用 allocPrint 拼接大段模板（comptime 模板 + 运行时插值）
    const tpl =
        \\; Generated by Zilt bundler - DO NOT EDIT.
        \\; Per-user installer: no admin required. WebView2 runtime auto-provisioned.
        \\Unicode true
        \\!include "LogicLib.nsh"
        \\
        \\!define APP_NAME      "{NAME}"
        \\!define APP_VERSION   "{VER}"
        \\!define APP_PUBLISHER "{PUB}"
        \\!define APP_EXE       "{EXENAME}"
        \\!define APP_ID        "{APPID}"
        \\!define UNINST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
        \\
        \\Name        "${APP_NAME} ${APP_VERSION}"
        \\OutFile     "{OUT}"
        \\InstallDir  {INSTDIR_EXPR}
        \\InstallDirRegKey @UNINST_ROOT@ "${UNINST_KEY}" "InstallLocation"
        \\RequestExecutionLevel {REQLEVEL}
        \\{ICON_LINE}
        \\SetCompressor /SOLID lzma
        \\ShowInstDetails show
        \\
        \\{LICENSE_DATA}
        \\{LICENSE_PAGE}
        \\Page directory
        \\Page instfiles
        \\UninstPage uninstConfirm
        \\UninstPage instfiles
        \\
        \\; ---- WebView2 Runtime（Evergreen）检测与引导 ----
        \\; NSIS 为 32 位进程，HKLM 读取自动落在 32 位视图（WOW6432Node）。
        \\Function MaybeInstallWebView2
        \\  ReadRegStr $R0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
        \\  ReadRegStr $R1 HKCU "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
        \\  ${If} $R0 == ""
        \\  ${AndIf} $R1 == ""
        \\    DetailPrint "WebView2 runtime not found; downloading Evergreen bootstrapper..."
        \\    NSISdl::download /TIMEOUT=60000 "https://go.microsoft.com/fwlink/?linkid=2124701" "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        \\    Pop $R2
        \\    ${If} $R2 == "success"
        \\      ExecWait '"$TEMP\MicrosoftEdgeWebview2Setup.exe" /silent /install' $R3
        \\      DetailPrint "WebView2 bootstrapper exit code: $R3"
        \\    ${Else}
        \\      MessageBox MB_ICONEXCLAMATION "无法下载 WebView2 运行时，请手动安装后重试。$\n错误: $R2"
        \\    ${EndIf}
        \\  ${Else}
        \\    DetailPrint "WebView2 runtime found ($R0$R1)"
        \\  ${EndIf}
        \\FunctionEnd
        \\
        \\Section "Install"
        \\  Call MaybeInstallWebView2
        \\{UPGRADE_CHECK}
        \\  SetOutPath "$INSTDIR"
        \\  File "{EXE}"
        \\  WriteUninstaller "$INSTDIR\Uninstall.exe"
        \\  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
        \\  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
        \\  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "DisplayName"   "${APP_NAME} ${APP_VERSION}"
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "Publisher"     "${APP_PUBLISHER}"
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "DisplayIcon"   "$INSTDIR\${APP_EXE}"
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
        \\  WriteRegStr @UNINST_ROOT@ "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
        \\{ASSOC_INSTALL}
        \\SectionEnd
        \\
        \\Section "Uninstall"
        \\  Delete "$INSTDIR\${APP_EXE}"
        \\  Delete "$INSTDIR\Uninstall.exe"
        \\  RMDir "$INSTDIR"
        \\  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
        \\  RMDir "$SMPROGRAMS\${APP_NAME}"
        \\  Delete "$DESKTOP\${APP_NAME}.lnk"
        \\  DeleteRegKey @UNINST_ROOT@ "${UNINST_KEY}"
        \\{ASSOC_UNINSTALL}
        \\SectionEnd
        \\
    ;

    var cur: []u8 = try replaceAll(alloc, tpl, "{NAME}", name);
    cur = try repStep(alloc, cur, "{VER}", version);
    cur = try repStep(alloc, cur, "{PUB}", publisher);
    cur = try repStep(alloc, cur, "{EXENAME}", exe_name);
    cur = try repStep(alloc, cur, "{APPID}", app_id);
    cur = try repStep(alloc, cur, "{OUT}", out_path);
    cur = try repStep(alloc, cur, "{EXE}", exe_path);

    // v0.1.15：per-machine / License / 图标 / 协议与文件关联 / 升级检测
    {
        cur = try repStep(alloc, cur, "{REQLEVEL}", if (cfg.per_machine) "admin" else "user");
        cur = try repStep(alloc, cur, "{INSTDIR_EXPR}", if (cfg.per_machine)
            "$PROGRAMFILES64\\${APP_ID}"
        else
            "$LOCALAPPDATA\\Programs\\${APP_ID}");
        const license_data = if (cfg.license_path) |lp| blk: {
            const esc = try nsisEscape(alloc, lp);
            defer alloc.free(esc);
            break :blk try std.fmt.allocPrint(alloc, "LicenseData \"{s}\"", .{esc});
        } else try alloc.dupe(u8, "");
        cur = try repStep(alloc, cur, "{LICENSE_DATA}", license_data);
        alloc.free(license_data);
        cur = try repStep(alloc, cur, "{LICENSE_PAGE}", if (cfg.license_path != null) "Page license" else "");

        const icon_line = if (cfg.setup_icon) |ip| blk: {
            const esc = try nsisEscape(alloc, ip);
            defer alloc.free(esc);
            break :blk try std.fmt.allocPrint(alloc, "Icon \"{s}\"", .{esc});
        } else try alloc.dupe(u8, "");
        cur = try repStep(alloc, cur, "{ICON_LINE}", icon_line);
        alloc.free(icon_line);

        const upgrade = try std.fmt.allocPrint(alloc,
            \\  ReadRegStr $R4 @UNINST_ROOT@ "${{UNINST_KEY}}" "DisplayVersion"
            \\  ${{If}} $R4 != ""
            \\    DetailPrint "已安装版本 $R4，将升级到 ${{APP_VERSION}}"
            \\  ${{EndIf}}
        , .{});
        cur = try repStep(alloc, cur, "{UPGRADE_CHECK}", upgrade);
        alloc.free(upgrade);

        const assoc_install = try buildAssocInstall(alloc, cfg);
        cur = try repStep(alloc, cur, "{ASSOC_INSTALL}", assoc_install);
        alloc.free(assoc_install);

        // v0.3.4：侧车资源（{RESOURCES_INSTALL}；cfg.resources null/空 → 空片段）
        {
            const resources_block: []const u8 = if (cfg.resources) |res_dir| blk: {
                if (res_dir.len == 0) break :blk "";
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "  SetOutPath \"$INSTDIR\\resources\"" ++ "\n" ++
                        "  File /r \"{{RES_DIR}}\\*.*\"" ++ "\n" ++
                        "  SetOutPath \"$INSTDIR\"",
                    .{},
                );
            } else "";
            cur = try repStep(alloc, cur, "{RESOURCES_INSTALL}", resources_block);
            cur = try repStep(alloc, cur, "{RES_DIR}", cfg.resources orelse "");
        }

        const assoc_uninstall = try buildAssocUninstall(alloc, cfg);
        cur = try repStep(alloc, cur, "{ASSOC_UNINSTALL}", assoc_uninstall);
        alloc.free(assoc_uninstall);

        // 最后统一展开卸载键根：此时 assoc / upgrade 片段已插入完毕
        cur = try repStep(alloc, cur, "@UNINST_ROOT@", if (cfg.per_machine) "HKLM" else "HKCU");
    }
    return cur;
}

/// 安装段：URL 协议注册（v0.1.15）。每个 scheme 生成 4 条 WriteRegStr。
fn buildAssocInstall(alloc: std.mem.Allocator, cfg: InstallerConfig) ![]u8 {
    const scheme_tpl =
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@SCHEME@" "" "URL:${APP_NAME}"
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@SCHEME@" "URL Protocol" ""
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@SCHEME@\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@SCHEME@\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'
        \\
    ;
    const ext_tpl =
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@EXT@" "" "@PROGID@"
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@PROGID@" "" "${APP_NAME} Document"
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@PROGID@\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
        \\  WriteRegStr @UNINST_ROOT@ "Software\Classes\@PROGID@\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'
        \\
    ;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    for (cfg.schemes) |scheme| {
        const esc = try nsisEscape(alloc, scheme);
        defer alloc.free(esc);
        const chunk = try replaceAll(alloc, scheme_tpl, "@SCHEME@", esc);
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    for (cfg.file_exts) |ext| {
        const esc = try nsisEscape(alloc, ext);
        defer alloc.free(esc);
        const progid = try std.fmt.allocPrint(alloc, "${{APP_NAME}}{s}", .{esc});
        defer alloc.free(progid);
        var chunk = try replaceAll(alloc, ext_tpl, "@EXT@", esc);
        chunk = try repStep(alloc, chunk, "@PROGID@", progid);
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    return out.toOwnedSlice(alloc);
}

/// 卸载段：删除协议与文件关联键（顺序与安装相反）。
fn buildAssocUninstall(alloc: std.mem.Allocator, cfg: InstallerConfig) ![]u8 {
    const scheme_tpl =
        \\  DeleteRegKey @UNINST_ROOT@ "Software\Classes\@SCHEME@"
        \\
    ;
    const ext_tpl =
        \\  DeleteRegKey @UNINST_ROOT@ "Software\Classes\@PROGID@"
        \\  DeleteRegKey @UNINST_ROOT@ "Software\Classes\@EXT@"
        \\
    ;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    for (cfg.file_exts) |ext| {
        const esc = try nsisEscape(alloc, ext);
        defer alloc.free(esc);
        const progid = try std.fmt.allocPrint(alloc, "${{APP_NAME}}{s}", .{esc});
        defer alloc.free(progid);
        var chunk = try replaceAll(alloc, ext_tpl, "@EXT@", esc);
        chunk = try repStep(alloc, chunk, "@PROGID@", progid);
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    for (cfg.schemes) |scheme| {
        const esc = try nsisEscape(alloc, scheme);
        defer alloc.free(esc);
        const chunk = try replaceAll(alloc, scheme_tpl, "@SCHEME@", esc);
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    return out.toOwnedSlice(alloc);
}

/// 替换一步并释放上一步缓冲（失败时也释放）。
fn repStep(alloc: std.mem.Allocator, cur: []u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const next = replaceAll(alloc, cur, needle, replacement) catch |err| {
        alloc.free(cur);
        return err;
    };
    alloc.free(cur);
    return next;
}

fn replaceAll(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) {
            try buf.appendSlice(alloc, replacement);
            i += needle.len;
        } else {
            try buf.append(alloc, haystack[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeZip: 结构 + CRC + 内容回读（手工解析）" {
    const entries = [_]ZipEntry{
        .{ .name = "Zilt-0.1.0/zilt-app.exe", .content = "MZ-fake-binary-bytes" },
        .{ .name = "Zilt-0.1.0/README.txt", .content = "hello zilt\n" },
        .{ .name = "Zilt-0.1.0/empty.dat", .content = "" },
    };

    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(testing.allocator);
    try writeZip(testing.allocator, &entries, &zip_bytes);

    // EOCD 定位（尾部 22 字节）
    const tail = zip_bytes.items[zip_bytes.items.len - 22 ..];
    try testing.expectEqualSlices(u8, &.{ 'P', 'K', 5, 6 }, tail[0..4]);
    const entry_count = std.mem.readInt(u16, tail[10..12], .little);
    try testing.expectEqual(@as(u16, 3), entry_count);
    const cd_size = std.mem.readInt(u32, tail[12..16], .little);
    const cd_start = std.mem.readInt(u32, tail[16..20], .little);

    // 遍历 central directory → 跳到 local header → 校验名称/CRC/内容
    var pos: usize = cd_start;
    const cd_end = cd_start + cd_size;
    var found: usize = 0;
    while (pos < cd_end) {
        try testing.expectEqualSlices(u8, &.{ 'P', 'K', 1, 2 }, zip_bytes.items[pos..][0..4]);
        const crc = std.mem.readInt(u32, zip_bytes.items[pos + 16 ..][0..4], .little);
        const size = std.mem.readInt(u32, zip_bytes.items[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, zip_bytes.items[pos + 28 ..][0..2], .little);
        const lfh_off = std.mem.readInt(u32, zip_bytes.items[pos + 42 ..][0..4], .little);
        const name = zip_bytes.items[pos + 46 ..][0..name_len];
        pos += 46 + name_len;
        found += 1;

        // local header
        try testing.expectEqualSlices(u8, &.{ 'P', 'K', 3, 4 }, zip_bytes.items[lfh_off..][0..4]);
        const l_name_len = std.mem.readInt(u16, zip_bytes.items[lfh_off + 26 ..][0..2], .little);
        const data_start = lfh_off + 30 + l_name_len;
        const data = zip_bytes.items[data_start..][0..size];
        try testing.expectEqual(crc, std.hash.Crc32.hash(data));

        // 与源数据比对
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                try testing.expectEqualSlices(u8, e.content, data);
                break;
            }
        } else {
            return error.TestUnexpectedResult; // 未知条目名
        }
    }
    try testing.expectEqual(@as(usize, 3), found);
}

test "writeZip: 无效与极端文件名" {
    const entries = [_]ZipEntry{
        .{ .name = "a/b/c.txt", .content = "x" },
    };
    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(testing.allocator);
    try writeZip(testing.allocator, &entries, &zip_bytes);
    try testing.expect(zip_bytes.items.len > 30 + 46 + 8);
}

test "nsisEscape" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "plain", .want = "plain" },
        .{ .in = "a\"b", .want = "a$\\b" },
        .{ .in = "$100", .want = "$$100" },
    };
    for (cases) |c| {
        const got = try nsisEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "generateNsis: 关键指令与插值" {
    const script = try generateNsis(testing.allocator, .{
        .app_name = "Zilt",
        .version = "0.1.0",
        .publisher = "Zilt Project",
        .exe_name = "zilt-app.exe",
        .app_id = "app.zilt.desktop",
        .out_path = "dist/Zilt-0.1.0-x64-setup.exe",
        .exe_path = "C:\\build\\zilt-app.exe",
    });
    defer testing.allocator.free(script);

    // 基础头
    try testing.expect(std.mem.indexOf(u8, script, "Unicode true") != null);
    try testing.expect(std.mem.indexOf(u8, script, "!define APP_NAME      \"Zilt\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "!define APP_VERSION   \"0.1.0\"") != null);
    // 插值完整（!define 侧为 Zig 替换；脚本体中 ${APP_ID} 等是 NSIS 编译期展开）
    try testing.expect(std.mem.indexOf(u8, script, "!define APP_ID        \"app.zilt.desktop\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "OutFile     \"dist/Zilt-0.1.0-x64-setup.exe\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "File \"C:\\build\\zilt-app.exe\"") != null);
    // WebView2 引导：官方 GUID + 官方 bootstrapper URL + 静默安装
    try testing.expect(std.mem.indexOf(u8, script, "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}") != null);
    try testing.expect(std.mem.indexOf(u8, script, "https://go.microsoft.com/fwlink/?linkid=2124701") != null);
    try testing.expect(std.mem.indexOf(u8, script, "/silent /install") != null);
    // per-user：无 admin + 卸载表项
    try testing.expect(std.mem.indexOf(u8, script, "RequestExecutionLevel user") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Uninstall\\${APP_ID}") != null);
    try testing.expect(std.mem.indexOf(u8, script, "WriteUninstaller") != null);
    // 快捷方式
    try testing.expect(std.mem.indexOf(u8, script, "CreateShortCut") != null);
}

test "replaceAll" {
    const r = try replaceAll(testing.allocator, "a{X}b{X}c", "{X}", "-");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a-b-c", r);
}

// ---------------------------------------------------------------------------
// zip 读取（仅支持本项目写出的 store 条目；用于更新器提取新版本 exe）
// ---------------------------------------------------------------------------

pub const ZipReadError = error{ Corrupted, EntryNotFound, NotStored, CrcMismatch, OutOfMemory };

/// 按名称读取 store 条目内容（返回拷贝）。name 为完整 zip 内路径。
pub fn readZipStoreEntry(alloc: std.mem.Allocator, zip_bytes: []const u8, name: []const u8) ZipReadError![]u8 {
    if (zip_bytes.len < 22) return error.Corrupted;

    // 从尾部扫描 EOCD（含 65535 字节注释容差）
    var eocd: ?usize = null;
    var i: usize = zip_bytes.len - 22;
    while (true) : (i -= 1) {
        if (std.mem.eql(u8, zip_bytes[i..][0..4], &.{ 'P', 'K', 5, 6 })) {
            eocd = i;
            break;
        }
        if (i == 0) break;
    }
    const e = eocd orelse return error.Corrupted;
    const cd_size = std.mem.readInt(u32, zip_bytes[e + 12 ..][0..4], .little);
    const cd_start: usize = std.mem.readInt(u32, zip_bytes[e + 16 ..][0..4], .little);

    var pos = cd_start;
    const cd_end = cd_start + cd_size;
    while (pos + 46 <= cd_end and pos + 46 <= zip_bytes.len) {
        if (!std.mem.eql(u8, zip_bytes[pos..][0..4], &.{ 'P', 'K', 1, 2 })) return error.Corrupted;
        const crc = std.mem.readInt(u32, zip_bytes[pos + 16 ..][0..4], .little);
        const size = std.mem.readInt(u32, zip_bytes[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, zip_bytes[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip_bytes[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, zip_bytes[pos + 32 ..][0..2], .little);
        const lfh_off: usize = std.mem.readInt(u32, zip_bytes[pos + 42 ..][0..4], .little);
        const entry_name = zip_bytes[pos + 46 ..][0..name_len];
        pos += 46 + name_len + extra_len + comment_len;

        if (!std.mem.eql(u8, entry_name, name)) continue;

        // local header
        if (lfh_off + 30 > zip_bytes.len) return error.Corrupted;
        if (!std.mem.eql(u8, zip_bytes[lfh_off..][0..4], &.{ 'P', 'K', 3, 4 })) return error.Corrupted;
        const method = std.mem.readInt(u16, zip_bytes[lfh_off + 8 ..][0..2], .little);
        if (method != 0) return error.NotStored; // 本项目写出的都是 store；解压 deflate 属 Phase 后续
        const l_name_len = std.mem.readInt(u16, zip_bytes[lfh_off + 26 ..][0..2], .little);
        const l_extra_len = std.mem.readInt(u16, zip_bytes[lfh_off + 28 ..][0..2], .little);
        const data_start = lfh_off + 30 + l_name_len + l_extra_len;
        if (data_start + size > zip_bytes.len) return error.Corrupted;
        const data = zip_bytes[data_start..][0..size];
        if (std.hash.Crc32.hash(data) != crc) return error.CrcMismatch;
        return alloc.dupe(u8, data) catch return error.OutOfMemory;
    }
    return error.EntryNotFound;
}

/// 按后缀匹配读取（zip 内目录前缀不固定时使用，如 "<dir>/zilt-app.exe"）。
pub fn readZipStoreEntrySuffix(alloc: std.mem.Allocator, zip_bytes: []const u8, name_suffix: []const u8) ZipReadError![]u8 {
    // 复用读取逻辑：先取全部条目名过于繁琐，这里直接线性扫 central directory
    if (zip_bytes.len < 22) return error.Corrupted;
    var eocd: ?usize = null;
    var i: usize = zip_bytes.len - 22;
    while (true) : (i -= 1) {
        if (std.mem.eql(u8, zip_bytes[i..][0..4], &.{ 'P', 'K', 5, 6 })) {
            eocd = i;
            break;
        }
        if (i == 0) break;
    }
    const e = eocd orelse return error.Corrupted;
    const cd_size = std.mem.readInt(u32, zip_bytes[e + 12 ..][0..4], .little);
    const cd_start: usize = std.mem.readInt(u32, zip_bytes[e + 16 ..][0..4], .little);

    var pos = cd_start;
    const cd_end = cd_start + cd_size;
    while (pos + 46 <= cd_end and pos + 46 <= zip_bytes.len) {
        const name_len = std.mem.readInt(u16, zip_bytes[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip_bytes[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, zip_bytes[pos + 32 ..][0..2], .little);
        const entry_name = zip_bytes[pos + 46 ..][0..name_len];
        const advance = 46 + name_len + extra_len + comment_len;
        if (entry_name.len >= name_suffix.len and
            std.mem.eql(u8, entry_name[entry_name.len - name_suffix.len ..], name_suffix))
        {
            // 命中：交给精确读取复用 CRC/校验路径
            const full_name = alloc.dupe(u8, entry_name) catch return error.OutOfMemory;
            defer alloc.free(full_name);
            return readZipStoreEntry(alloc, zip_bytes, full_name);
        }
        pos += advance;
    }
    return error.EntryNotFound;
}

test "readZipStoreEntry: 回读 / 未命中 / CRC 篡改" {
    const entries = [_]ZipEntry{
        .{ .name = "Zilt-9.9.9-x64/zilt-app.exe", .content = "\x4d\x5a-new-binary-\xff\xee" },
        .{ .name = "Zilt-9.9.9-x64/README.txt", .content = "readme content" },
    };
    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(testing.allocator);
    try writeZip(testing.allocator, &entries, &zip_bytes);

    // 精确读取
    const exe = try readZipStoreEntry(testing.allocator, zip_bytes.items, "Zilt-9.9.9-x64/zilt-app.exe");
    defer testing.allocator.free(exe);
    try testing.expectEqualSlices(u8, entries[0].content, exe);

    // 后缀读取
    const exe2 = try readZipStoreEntrySuffix(testing.allocator, zip_bytes.items, "/zilt-app.exe");
    defer testing.allocator.free(exe2);
    try testing.expectEqualSlices(u8, entries[0].content, exe2);

    // 未命中
    try testing.expectError(error.EntryNotFound, readZipStoreEntry(testing.allocator, zip_bytes.items, "nope.txt"));

    // CRC 篡改：翻转 exe 数据第一个字节
    var tampered = try testing.allocator.dupe(u8, zip_bytes.items);
    defer testing.allocator.free(tampered);
    const cd = cdStartOf(tampered);
    const lfh_off = std.mem.readInt(u32, tampered[cd + 42 ..][0..4], .little);
    const l_name_len = std.mem.readInt(u16, tampered[lfh_off + 26 ..][0..2], .little);
    const l_extra_len = std.mem.readInt(u16, tampered[lfh_off + 28 ..][0..2], .little);
    const data_start = lfh_off + 30 + l_name_len + l_extra_len;
    tampered[data_start] ^= 0xff;
    try testing.expectError(error.CrcMismatch, readZipStoreEntry(testing.allocator, tampered, "Zilt-9.9.9-x64/zilt-app.exe"));
}

/// 测试辅助：取 EOCD 里的 cd_start。
fn cdStartOf(zip_bytes: []const u8) usize {
    var i: usize = zip_bytes.len - 22;
    while (i > 0) : (i -= 1) {
        if (std.mem.eql(u8, zip_bytes[i..][0..4], &.{ 'P', 'K', 5, 6 })) {
            return std.mem.readInt(u32, zip_bytes[i + 16 ..][0..4], .little);
        }
    }
    unreachable;
}

test "nsis installer: per-machine uses admin, Program Files and HKLM" {
    const script = try generateNsis(testing.allocator, .{
        .app_name = "Zilt",
        .version = "1.2.3",
        .publisher = "Zilt",
        .exe_name = "zilt-app.exe",
        .app_id = "Zilt.zilt",
        .out_path = "out-setup.exe",
        .exe_path = "C://build//zilt-app.exe",
        .per_machine = true,
    });
    defer testing.allocator.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "RequestExecutionLevel admin") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$PROGRAMFILES64") != null);
    try testing.expect(std.mem.indexOf(u8, script, "HKLM") != null);
    try testing.expect(std.mem.indexOf(u8, script, "RequestExecutionLevel user") == null);
    try testing.expect(std.mem.indexOf(u8, script, "{REQLEVEL}") == null);
    try testing.expect(std.mem.indexOf(u8, script, "@UNINST_ROOT@") == null);
    try testing.expect(std.mem.indexOf(u8, script, "WriteRegStr HKLM") != null);
}

test "nsis installer: per-user keeps HKCU and LOCALAPPDATA" {
    const script = try generateNsis(testing.allocator, .{
        .app_name = "Zilt",
        .version = "1.2.3",
        .publisher = "Zilt",
        .exe_name = "zilt-app.exe",
        .app_id = "Zilt.zilt",
        .out_path = "out-setup.exe",
        .exe_path = "C://build//zilt-app.exe",
    });
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "RequestExecutionLevel user") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$LOCALAPPDATA\\Programs") != null);
    try testing.expect(std.mem.indexOf(u8, script, "WriteRegStr HKCU") != null);
    // WebView2 检测仍读 HKCU（与安装范围无关）
    try testing.expect(std.mem.indexOf(u8, script, "ReadRegStr $R1 HKCU") != null);
}

test "nsis installer: license, icon, protocol and file association" {
    const script = try generateNsis(testing.allocator, .{
        .app_name = "Zilt",
        .version = "1.2.3",
        .publisher = "Zilt",
        .exe_name = "zilt-app.exe",
        .app_id = "Zilt.zilt",
        .out_path = "out-setup.exe",
        .exe_path = "C://build//zilt-app.exe",
        .license_path = "LICENSE.txt",
        .setup_icon = "installer.ico",
        .schemes = &.{"zilt"},
        .file_exts = &.{".zilt"},
    });
    defer testing.allocator.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "LicenseData \"LICENSE.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Page license") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Icon \"installer.ico\"") != null);

    // URL 协议
    try testing.expect(std.mem.indexOf(u8, script, "\"URL Protocol\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "URL:${APP_NAME}") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Software\\Classes\\zilt") != null);

    // 文件关联
    try testing.expect(std.mem.indexOf(u8, script, "Software\\Classes\\.zilt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "${APP_NAME}.zilt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "shell\\open\\command") != null);

    // 卸载清理
    try testing.expect(std.mem.indexOf(u8, script, "DeleteRegKey @UNINST_ROOT@") == null);

    // 升级检测
    try testing.expect(std.mem.indexOf(u8, script, "ReadRegStr $R4") != null);
    // 占位符必须全部替换干净
    try testing.expect(std.mem.indexOf(u8, script, "{ASSOC_INSTALL}") == null);
    try testing.expect(std.mem.indexOf(u8, script, "{ASSOC_UNINSTALL}") == null);
    try testing.expect(std.mem.indexOf(u8, script, "{LICENSE_PAGE}") == null);
    try testing.expect(std.mem.indexOf(u8, script, "{ICON_LINE}") == null);
    try testing.expect(std.mem.indexOf(u8, script, "{UPGRADE_CHECK}") == null);
}

test "nsis installer: no license means no license page" {
    const script = try generateNsis(testing.allocator, .{
        .app_name = "Zilt",
        .version = "1.0",
        .publisher = "Zilt",
        .exe_name = "zilt-app.exe",
        .app_id = "Zilt.zilt",
        .out_path = "o.exe",
        .exe_path = "a.exe",
    });
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "Page license") == null);
    try testing.expect(std.mem.indexOf(u8, script, "LicenseData") == null);
}
