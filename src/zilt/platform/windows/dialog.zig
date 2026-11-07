//! 原生对话框：MessageBox / 打开文件 / 保存文件（comdlg32）。
//!
//! 约定：只能在 UI 线程调用（命令分发天然在 UI 线程）；模态对话框会阻塞
//! UI 线程直至用户关闭——与 Tauri 同步对话框语义一致。

const std = @import("std");
const win32 = @import("win32.zig");
const ipc = @import("../../ipc.zig");

// ---------------------------------------------------------------------------
// MessageBox
// ---------------------------------------------------------------------------

pub fn runMessageBox(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.MessageBoxOptions) !ipc.Button {
    _ = alloc;
    const icon: win32.UINT = switch (opts.kind) {
        .info => win32.MB_ICONINFORMATION,
        .warning => win32.MB_ICONWARNING,
        .err => win32.MB_ICONERROR,
    };
    const buttons: win32.UINT = switch (opts.buttons) {
        .ok => win32.MB_OK,
        .ok_cancel => win32.MB_OKCANCEL,
        .yes_no => win32.MB_YESNO,
    };

    const text_w = win32.utf16zFrom(opts.text);
    defer std.heap.page_allocator.free(text_w);
    const caption_w = win32.utf16zFrom(opts.caption);
    defer std.heap.page_allocator.free(caption_w);

    const r = win32.MessageBoxW(hwnd, text_w.ptr, caption_w.ptr, icon | buttons | win32.MB_SETFOREGROUND);
    return mapMsgBoxResult(r);
}

/// win32 结果码 → 语义化按钮。
pub fn mapMsgBoxResult(code: i32) ipc.Button {
    return switch (code) {
        win32.IDYES => .yes,
        win32.IDNO => .no,
        win32.IDCANCEL => .cancel,
        else => .ok,
    };
}

// ---------------------------------------------------------------------------
// 文件对话框
// ---------------------------------------------------------------------------

/// 过滤器 → 双 NUL 结尾 UTF-16 对（"名称\0模式\0...\0\0"）。
pub fn buildFilterUtf16(alloc: std.mem.Allocator, filters: []const ipc.Filter) ![:0]u16 {
    var buf: std.ArrayList(u16) = .empty;
    errdefer buf.deinit(alloc);
    for (filters) |f| {
        try appendUtf16Z(&buf, alloc, f.name); // 含结尾 NUL
        try appendUtf16Z(&buf, alloc, f.pattern);
    }
    try buf.append(alloc, 0); // 整体结尾双 NUL 的第二个
    return buf.toOwnedSliceSentinel(alloc, 0);
}

fn appendUtf16Z(buf: *std.ArrayList(u16), alloc: std.mem.Allocator, s: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
    defer alloc.free(w);
    try buf.appendSlice(alloc, w); // 字符（appendSlice 不含哨兵 NUL）
    try buf.append(alloc, 0); // 段尾 NUL
}

/// 打开文件对话框。取消返回 null；路径用 alloc 分配。
pub fn runOpenFile(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FileDialogOptions) !?[]u8 {
    return runFileDialog(alloc, hwnd, opts, false);
}

/// 保存文件对话框（覆盖提示）。
pub fn runSaveFile(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FileDialogOptions) !?[]u8 {
    return runFileDialog(alloc, hwnd, opts, true);
}

fn runFileDialog(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FileDialogOptions, save_mode: bool) !?[]u8 {
    const filter = try buildFilterUtf16(alloc, opts.filters);
    defer alloc.free(filter);

    var buffers = win32.makeOfn(hwnd, opts.title, filter, opts.default_name, save_mode);
    // buffers.filter 即 filter（makeOfn 透传不拷贝，所有权仍在上方 defer）；
    // file/title/def_ext 由 makeOfn 以 page_allocator 分配，须用同源释放。
    defer {
        std.heap.page_allocator.free(buffers.file);
        std.heap.page_allocator.free(buffers.title);
        if (buffers.def_ext) |d| std.heap.page_allocator.free(d);
    }

    const ok = if (save_mode)
        win32.GetSaveFileNameW(&buffers.ofn)
    else
        win32.GetOpenFileNameW(&buffers.ofn);
    if (ok == 0) return null; // 取消

    // 文件缓冲以双 NUL 结尾（单选时一个路径）
    var len: usize = 0;
    while (buffers.file[len] != 0) len += 1;
    return try std.unicode.utf16LeToUtf8Alloc(alloc, buffers.file[0..len]);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "mapMsgBoxResult: 结果码映射" {
    try testing.expectEqual(ipc.Button.ok, mapMsgBoxResult(win32.IDOK));
    try testing.expectEqual(ipc.Button.cancel, mapMsgBoxResult(win32.IDCANCEL));
    try testing.expectEqual(ipc.Button.yes, mapMsgBoxResult(win32.IDYES));
    try testing.expectEqual(ipc.Button.no, mapMsgBoxResult(win32.IDNO));
    try testing.expectEqual(ipc.Button.ok, mapMsgBoxResult(0)); // 未知兜底
}

test "buildFilterUtf16: 双 NUL 结构回读" {
    const f = try buildFilterUtf16(testing.allocator, &.{
        .{ .name = "文本", .pattern = "*.txt" },
        .{ .name = "所有", .pattern = "*.*" },
    });
    defer testing.allocator.free(f);

    // 结构：文本\0*.txt\0所有\0*.*\0\0（w.len 不含哨兵，每段占 w.len + 1 NUL）
    var i: usize = 0;
    const expect = [_][]const u8{ "文本", "*.txt", "所有", "*.*" };
    for (expect) |e| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, e);
        defer testing.allocator.free(w);
        try testing.expectEqualSlices(u16, w, f[i..][0..w.len]);
        try testing.expectEqual(@as(u16, 0), f[i + w.len]); // 段尾 NUL
        i += w.len + 1;
    }
    try testing.expectEqual(@as(u16, 0), f[i]); // 整体双 NUL 的第二个
    try testing.expectEqual(@as(u16, 0), f[i + 1]);
}

test "buildFilterUtf16: 空过滤器" {
    const f = try buildFilterUtf16(testing.allocator, &.{});
    defer testing.allocator.free(f);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(@as(u16, 0), f[0]);
}

test "makeOfn: 结构尺寸与标志" {
    const filter = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, "All\x00*.*\x00");
    defer std.heap.page_allocator.free(filter);
    const buffers = win32.makeOfn(@ptrFromInt(0x1000), "打开", filter, "a.txt", false);
    defer std.heap.page_allocator.free(buffers.file);
    defer std.heap.page_allocator.free(buffers.title);

    try testing.expectEqual(@sizeOf(win32.OPENFILENAMEW), buffers.ofn.lStructSize);
    try testing.expect(buffers.ofn.Flags & win32.OFN_FILEMUSTEXIST != 0);
    try testing.expect(buffers.ofn.Flags & win32.OFN_HIDEREADONLY != 0);
    try testing.expect(buffers.ofn.Flags & win32.OFN_OVERWRITEPROMPT == 0);
    try testing.expectEqual(@as(usize, 4096), buffers.ofn.nMaxFile);

    // 保存模式
    const b2 = win32.makeOfn(null, "保存", filter, "", true);
    defer std.heap.page_allocator.free(b2.file);
    defer std.heap.page_allocator.free(b2.title);
    try testing.expect(b2.ofn.Flags & win32.OFN_OVERWRITEPROMPT != 0);
    try testing.expect(b2.ofn.Flags & win32.OFN_FILEMUSTEXIST == 0);
}
