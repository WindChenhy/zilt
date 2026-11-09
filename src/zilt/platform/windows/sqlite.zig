//! v0.1.17：sqlite3.dll 动态加载（对齐 WebView2 loader 模式：运行时发现、
//! 不静态链接、缺失时优雅降级为 error.SqliteNotFound）。
//!
//! 查找顺序：ZILT_SQLITE_PATH 环境变量 → 应用 exe 同目录 → 当前目录 →
//! 默认 DLL 搜索（PATH/System32）。API 表覆盖 prepare/step/bind/column 的
//! v2 系列接口（sqlite3 >= 3.5，Windows 上任何现代发行版均满足）。

const std = @import("std");
const win32 = @import("win32.zig");
const sql = @import("../../sql.zig");
const log = @import("../../log.zig");

pub const load_error = error{SqliteNotFound};

const SqlInt = i32;
const SqlHandle = ?*anyopaque; // sqlite3*
const StmtHandle = ?*anyopaque; // sqlite3_stmt*

const OpenFn = *const fn (filename: [*:0]const u8, db: *SqlHandle, flags: SqlInt, vfs: ?[*:0]const u8) callconv(.c) SqlInt;
const CloseFn = *const fn (db: SqlHandle) callconv(.c) SqlInt;
const PrepareFn = *const fn (db: SqlHandle, zSql: [*:0]const u8, nByte: SqlInt, stmt: *StmtHandle, tail: ?*?[*:0]const u8) callconv(.c) SqlInt;
const StepFn = *const fn (stmt: StmtHandle) callconv(.c) SqlInt;
const FinalizeFn = *const fn (stmt: StmtHandle) callconv(.c) SqlInt;
const ColumnCountFn = *const fn (stmt: StmtHandle) callconv(.c) SqlInt;
const ColumnTypeFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) SqlInt;
const ColumnInt64Fn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) i64;
const ColumnDoubleFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) f64;
const ColumnTextFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) ?[*:0]const u8;
const ColumnBytesFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) SqlInt;
const ColumnNameFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) ?[*:0]const u8;
const BindIntFn = *const fn (stmt: StmtHandle, i: SqlInt, v: i64) callconv(.c) SqlInt;
const BindDoubleFn = *const fn (stmt: StmtHandle, i: SqlInt, v: f64) callconv(.c) SqlInt;
const BindTextFn = *const fn (stmt: StmtHandle, i: SqlInt, v: [*]const u8, n: SqlInt, destructor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) SqlInt;
const BindNullFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) SqlInt;
const ChangesFn = *const fn (db: SqlHandle) callconv(.c) SqlInt;
const LastInsertRowidFn = *const fn (db: SqlHandle) callconv(.c) i64;
const ErrMsgFn = *const fn (db: SqlHandle) callconv(.c) ?[*:0]const u8;

/// SQLITE_TRANSIENT：sqlite 自拷贝绑定串
const transient: ?*const fn (?*anyopaque) callconv(.c) void =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const Lib = struct {
    module: win32.HMODULE,
    open: OpenFn,
    close: CloseFn,
    prepare: PrepareFn,
    step: StepFn,
    finalize: FinalizeFn,
    column_count: ColumnCountFn,
    column_type: ColumnTypeFn,
    column_int64: ColumnInt64Fn,
    column_double: ColumnDoubleFn,
    column_text: ColumnTextFn,
    column_bytes: ColumnBytesFn,
    column_name: ColumnNameFn,
    bind_int: BindIntFn,
    bind_double: BindDoubleFn,
    bind_text: BindTextFn,
    bind_null: BindNullFn,
    changes: ChangesFn,
    last_insert_rowid: LastInsertRowidFn,
    errmsg: ErrMsgFn,

    fn proc(comptime T: type, module: win32.HMODULE, comptime name: [*:0]const u8) ?T {
        const p = win32.GetProcAddress(module, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    /// 从模块句柄组装 API 表；任一符号缺失 → null（版本过旧）。
    pub fn fromModule(module: win32.HMODULE) ?Lib {
        return .{
            .module = module,
            .open = proc(OpenFn, module, "sqlite3_open_v2") orelse return null,
            .close = proc(CloseFn, module, "sqlite3_close_v2") orelse return null,
            .prepare = proc(PrepareFn, module, "sqlite3_prepare_v2") orelse return null,
            .step = proc(StepFn, module, "sqlite3_step") orelse return null,
            .finalize = proc(FinalizeFn, module, "sqlite3_finalize") orelse return null,
            .column_count = proc(ColumnCountFn, module, "sqlite3_column_count") orelse return null,
            .column_type = proc(ColumnTypeFn, module, "sqlite3_column_type") orelse return null,
            .column_int64 = proc(ColumnInt64Fn, module, "sqlite3_column_int64") orelse return null,
            .column_double = proc(ColumnDoubleFn, module, "sqlite3_column_double") orelse return null,
            .column_text = proc(ColumnTextFn, module, "sqlite3_column_text") orelse return null,
            .column_bytes = proc(ColumnBytesFn, module, "sqlite3_column_bytes") orelse return null,
            .column_name = proc(ColumnNameFn, module, "sqlite3_column_name") orelse return null,
            .bind_int = proc(BindIntFn, module, "sqlite3_bind_int64") orelse return null,
            .bind_double = proc(BindDoubleFn, module, "sqlite3_bind_double") orelse return null,
            .bind_text = proc(BindTextFn, module, "sqlite3_bind_text") orelse return null,
            .bind_null = proc(BindNullFn, module, "sqlite3_bind_null") orelse return null,
            .changes = proc(ChangesFn, module, "sqlite3_changes") orelse return null,
            .last_insert_rowid = proc(LastInsertRowidFn, module, "sqlite3_last_insert_rowid") orelse return null,
            .errmsg = proc(ErrMsgFn, module, "sqlite3_errmsg") orelse return null,
        };
    }
};

/// exe 所在目录（utf8，调用方 free）。
fn exeDir(alloc: std.mem.Allocator) ?[]u8 {
    var buf: [win32.MAX_PATH_W]u16 = undefined;
    const n = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    const full = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch return null;
    const idx = std.mem.lastIndexOfScalar(u8, full, '\\') orelse {
        alloc.free(full);
        return null;
    };
    defer alloc.free(full);
    return alloc.dupe(u8, full[0..idx]) catch null;
}

/// 加载 sqlite3.dll。找不到或符号不齐 → error.SqliteNotFound。
/// 返回的 Lib 所有权归调用方（deinit 释放模块句柄）。
pub fn load(alloc: std.mem.Allocator) load_error!Lib {
    const candidates = buildCandidates(alloc) catch return error.SqliteNotFound;
    defer {
        for (candidates) |c| alloc.free(c);
        alloc.free(candidates);
    }
    for (candidates) |path| {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch continue;
        defer alloc.free(wide);
        const module = win32.LoadLibraryW(wide.ptr) orelse continue;
        if (Lib.fromModule(module)) |lib| return lib;
        _ = win32.FreeLibrary(module);
    }
    return error.SqliteNotFound;
}

/// 候选路径列表（纯逻辑，可单测）：env 覆盖 → exe 目录 → sqlite3.dll
/// → winsqlite3.dll（Windows 10/11 自带，实测 19/19 符号齐全，开箱可用）。
pub fn buildCandidates(alloc: std.mem.Allocator) ![]const []u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |c| alloc.free(c);
        list.deinit(alloc);
    }
    if (win32.getEnvUtf8(alloc, "ZILT_SQLITE_PATH")) |p| {
        try list.append(alloc, p);
    }
    if (exeDir(alloc)) |dir| {
        defer alloc.free(dir);
        try list.append(alloc, try std.fmt.allocPrint(alloc, "{s}\\sqlite3.dll", .{dir}));
    }
    try list.append(alloc, try alloc.dupe(u8, "sqlite3.dll"));
    try list.append(alloc, try alloc.dupe(u8, "winsqlite3.dll"));
    return list.toOwnedSlice(alloc);
}

pub const Opened = struct {
    lib: *const Lib,
    handle: SqlHandle,
};

/// 打开数据库文件（utf8 路径）。
pub fn open(lib: *const Lib, path: []const u8, alloc: std.mem.Allocator) !Opened {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    const narrow = try std.unicode.utf16LeToUtf8AllocZ(alloc, wide);
    defer alloc.free(narrow);
    var handle: SqlHandle = null;
    const rc = lib.open(narrow.ptr, &handle, sql.OPEN_FLAGS, null);
    if (rc != sql.SQLITE_OK) return error.SqliteOpenFailed;
    return .{ .lib = lib, .handle = handle };
}

pub fn close(db: Opened) void {
    _ = db.lib.close(db.handle);
}

/// 一次完整 query/execute：open → prepare → bind → step* → finalize → close。
/// query 的结果由 alloc 持有；execute 返回 {changes,last_id} JSON。
pub fn run(
    alloc: std.mem.Allocator,
    db_path: []const u8,
    stmt_sql: []const u8,
    params: []const sql.SqlValue,
    want_rows: bool,
) ![]u8 {
    const lib_ptr = try alloc.create(Lib);
    defer alloc.destroy(lib_ptr);
    lib_ptr.* = try load(alloc);

    const db = try open(lib_ptr, db_path, alloc);
    defer close(db);

    // allocSentinel 只分配（末尾补 0），不拷贝内容——必须显式 memcpy
    // （漏掉会得到未初始化内存，prepare 报 near "ªªª…" 语法错误）
    const stmt_sql_z = try alloc.allocSentinel(u8, stmt_sql.len, 0);
    defer alloc.free(stmt_sql_z);
    @memcpy(stmt_sql_z[0..stmt_sql.len], stmt_sql);
    var stmt: StmtHandle = null;
    const rc_prepare = db.lib.prepare(db.handle, stmt_sql_z.ptr, @intCast(stmt_sql_z.len), &stmt, null);
    if (rc_prepare != sql.SQLITE_OK) {
        const msg = db.lib.errmsg(db.handle) orelse "";
        log.print("[sql] prepare failed rc={d} msg={s} sql={s}", .{ rc_prepare, std.mem.span(msg), stmt_sql });
        return error.SqlitePrepareFailed;
    }
    defer _ = db.lib.finalize(stmt);

    for (params, 0..) |p, i| {
        const idx: SqlInt = @intCast(i + 1);
        const rc: SqlInt = switch (p.kind) {
            .text => blk: {
                const t = p.text orelse "";
                break :blk db.lib.bind_text(stmt, idx, t.ptr, @intCast(t.len), transient);
            },
            .int => db.lib.bind_int(stmt, idx, p.int),
            .real => db.lib.bind_double(stmt, idx, p.real),
            .nul => db.lib.bind_null(stmt, idx),
        };
        if (rc != sql.SQLITE_OK) return error.SqliteBindFailed;
    }

    if (!want_rows) {
        while (db.lib.step(stmt) == sql.SQLITE_ROW) {} // 无返回值语句不应有 ROW；防御
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.print(alloc, "{{\"changes\":{d},\"last_id\":{d}}}", .{
            db.lib.changes(db.handle),
            db.lib.last_insert_rowid(db.handle),
        });
        return out.toOwnedSlice(alloc);
    }

    const ncols: usize = @intCast(@max(0, db.lib.column_count(stmt)));
    var columns: std.ArrayListUnmanaged([]const u8) = .empty;
    var rows: std.ArrayListUnmanaged([]sql.SqlValue) = .empty;
    errdefer {
        for (columns.items) |c| alloc.free(c);
        columns.deinit(alloc);
        for (rows.items) |r| alloc.free(r);
        rows.deinit(alloc);
    }

    var ci: usize = 0;
    while (ci < ncols) : (ci += 1) {
        const name = db.lib.column_name(stmt, @intCast(ci)) orelse "";
        try columns.append(alloc, try alloc.dupe(u8, std.mem.span(name)));
    }

    while (true) {
        const rc = db.lib.step(stmt);
        if (rc == sql.SQLITE_DONE) break;
        if (rc != sql.SQLITE_ROW) return error.SqliteStepFailed;
        var row = try alloc.alloc(sql.SqlValue, ncols);
        errdefer alloc.free(row);
        for (0..ncols) |i| {
            const t = db.lib.column_type(stmt, @intCast(i));
            row[i] = switch (t) {
                1 => sql.SqlValue.intOf(db.lib.column_int64(stmt, @intCast(i))),
                2 => sql.SqlValue.realOf(db.lib.column_double(stmt, @intCast(i))),
                3 => blk: {
                    const txt = db.lib.column_text(stmt, @intCast(i)) orelse break :blk sql.SqlValue.nul();
                    const n: usize = @intCast(@max(0, db.lib.column_bytes(stmt, @intCast(i))));
                    break :blk sql.SqlValue.textOf(try alloc.dupe(u8, txt[0..n]));
                },
                else => sql.SqlValue.nul(),
            };
        }
        try rows.append(alloc, row);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try sql.serializeRows(alloc, &out, .{ .columns = columns.items, .rows = rows.items });
    // 列名/行值的分配已并入 out 消费方管理范围之外——这里统一释放
    for (columns.items) |c| alloc.free(c);
    columns.deinit(alloc);
    for (rows.items) |r| alloc.free(r);
    rows.deinit(alloc);
    return out.toOwnedSlice(alloc);
}
