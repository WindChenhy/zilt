//! Linux SQLite 绑定（v0.2.3）：libsqlite3 动态加载（对齐 Windows 的
//! `platform/windows/sqlite.zig`：运行时发现、不静态链接、缺失优雅降级）。
//!
//! 查找顺序（dlopen）：ZILT_SQLITE_PATH 环境变量 → `libsqlite3.so.0`
//! （各发行版实际 SONAME）→ `libsqlite3.so`（链接器名，需 -dev 包）。
//! API 表与语义和 Windows 版完全一致（行集 JSON / {changes,last_id} / 事务迁移）。

const std = @import("std");
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
const BindTextFn = *const fn (stmt: StmtHandle, i: SqlInt, v: [*]const u8, n: SqlInt, destructor: ?*align(1) const fn (?*anyopaque) callconv(.c) void) callconv(.c) SqlInt;
const BindNullFn = *const fn (stmt: StmtHandle, i: SqlInt) callconv(.c) SqlInt;
const ChangesFn = *const fn (db: SqlHandle) callconv(.c) SqlInt;
const LastInsertRowidFn = *const fn (db: SqlHandle) callconv(.c) i64;
const ErrMsgFn = *const fn (db: SqlHandle) callconv(.c) ?[*:0]const u8;

/// SQLITE_TRANSIENT：sqlite 自拷贝绑定串（哨兵 = (usize)-1）。
/// **align(1)**：aarch64 的指针 @ptrFromInt 要求对齐（x86_64 无此检查），
/// 哨兵值本质是整型标记 → 用 align(1) 指针类型承载，调用点 @ptrCast 回对齐类型。
const transient_aligned: ?*align(1) const fn (?*anyopaque) callconv(.c) void =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const Lib = struct {
    module: std.DynLib,
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

    fn lookup(module: *std.DynLib, comptime T: type, comptime name: [:0]const u8) ?T {
        return module.lookup(T, name);
    }

    /// 从已打开的模块组装 API 表；任一符号缺失 → null（版本过旧）。
    pub fn fromModule(module: std.DynLib) ?Lib {
        var m = module;
        return .{
            .module = module,
            .open = lookup(&m, OpenFn, "sqlite3_open_v2") orelse return null,
            .close = lookup(&m, CloseFn, "sqlite3_close_v2") orelse return null,
            .prepare = lookup(&m, PrepareFn, "sqlite3_prepare_v2") orelse return null,
            .step = lookup(&m, StepFn, "sqlite3_step") orelse return null,
            .finalize = lookup(&m, FinalizeFn, "sqlite3_finalize") orelse return null,
            .column_count = lookup(&m, ColumnCountFn, "sqlite3_column_count") orelse return null,
            .column_type = lookup(&m, ColumnTypeFn, "sqlite3_column_type") orelse return null,
            .column_int64 = lookup(&m, ColumnInt64Fn, "sqlite3_column_int64") orelse return null,
            .column_double = lookup(&m, ColumnDoubleFn, "sqlite3_column_double") orelse return null,
            .column_text = lookup(&m, ColumnTextFn, "sqlite3_column_text") orelse return null,
            .column_bytes = lookup(&m, ColumnBytesFn, "sqlite3_column_bytes") orelse return null,
            .column_name = lookup(&m, ColumnNameFn, "sqlite3_column_name") orelse return null,
            .bind_int = lookup(&m, BindIntFn, "sqlite3_bind_int64") orelse return null,
            .bind_double = lookup(&m, BindDoubleFn, "sqlite3_bind_double") orelse return null,
            .bind_text = lookup(&m, BindTextFn, "sqlite3_bind_text") orelse return null,
            .bind_null = lookup(&m, BindNullFn, "sqlite3_bind_null") orelse return null,
            .changes = lookup(&m, ChangesFn, "sqlite3_changes") orelse return null,
            .last_insert_rowid = lookup(&m, LastInsertRowidFn, "sqlite3_last_insert_rowid") orelse return null,
            .errmsg = lookup(&m, ErrMsgFn, "sqlite3_errmsg") orelse return null,
        };
    }
};

/// 加载 libsqlite3。找不到或符号不齐 → error.SqliteNotFound。
pub fn load() load_error!Lib {
    for (candidateNames()) |name| {
        var module = std.DynLib.open(name) catch continue;
        if (Lib.fromModule(module)) |lib| {
            return lib;
        }
        module.close();
    }
    return error.SqliteNotFound;
}

/// 候选 SONAME 列表（纯逻辑）：env 覆盖 → 发行版 SONAME → 链接器名。
pub fn candidateNames() []const [:0]const u8 {
    if (std.c.getenv("ZILT_SQLITE_PATH")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return &.{s};
    }
    return &.{ "libsqlite3.so.0", "libsqlite3.so" };
}

pub const Opened = struct {
    lib: *const Lib,
    handle: SqlHandle,
};

/// 打开数据库文件（utf8 路径；父目录需已存在）。
pub fn open(lib: *const Lib, path: []const u8, alloc: std.mem.Allocator) !Opened {
    const path_z = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(path_z);
    @memcpy(path_z[0..path.len], path);
    var handle: SqlHandle = null;
    const rc = lib.open(path_z.ptr, &handle, sql.OPEN_FLAGS, null);
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
    lib_ptr.* = try load();

    const db = try open(lib_ptr, db_path, alloc);
    defer close(db);

    // allocSentinel 只分配（末尾补 0），不拷贝内容——必须显式 memcpy
    //（漏掉会得到未初始化内存，prepare 报 near "ªªª…" 语法错误）
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
                break :blk db.lib.bind_text(stmt, idx, t.ptr, @intCast(t.len), transient_aligned);
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
    for (columns.items) |c| alloc.free(c);
    columns.deinit(alloc);
    for (rows.items) |r| alloc.free(r);
    rows.deinit(alloc);
    return out.toOwnedSlice(alloc);
}

/// v0.1.22 对齐：事务化迁移——依次执行 statements，成功后把 `PRAGMA
/// user_version` 设为 version；任一步失败回滚（含已执行的部分）。
pub fn migrate(
    alloc: std.mem.Allocator,
    db_path: []const u8,
    statements: []const []const u8,
    version: i32,
) !void {
    const lib_ptr = try alloc.create(Lib);
    defer alloc.destroy(lib_ptr);
    lib_ptr.* = try load();

    const db = try open(lib_ptr, db_path, alloc);
    defer close(db);

    try execSimple(alloc, db, "BEGIN");
    for (statements) |st| {
        execSimple(alloc, db, st) catch |e| {
            execSimple(alloc, db, "ROLLBACK") catch {};
            log.print("[sql] migrate step failed: {s}", .{@errorName(e)});
            return e;
        };
    }
    const pragma = try std.fmt.allocPrint(alloc, "PRAGMA user_version = {d}", .{version});
    defer alloc.free(pragma);
    execSimple(alloc, db, pragma) catch |e| {
        execSimple(alloc, db, "ROLLBACK") catch {};
        return e;
    };
    try execSimple(alloc, db, "COMMIT");
}

/// 单条无参数 SQL（prepare → step 到 DONE → finalize）。
fn execSimple(alloc: std.mem.Allocator, db: Opened, sql_text: []const u8) !void {
    const z = try alloc.allocSentinel(u8, sql_text.len, 0);
    defer alloc.free(z);
    @memcpy(z[0..sql_text.len], sql_text);

    var stmt: StmtHandle = null;
    if (db.lib.prepare(db.handle, z.ptr, @intCast(z.len), &stmt, null) != sql.SQLITE_OK) {
        const msg = db.lib.errmsg(db.handle) orelse "";
        log.print("[sql] exec prepare failed: {s}", .{std.mem.span(msg)});
        return error.SqlitePrepareFailed;
    }
    defer _ = db.lib.finalize(stmt);
    const rc = db.lib.step(stmt);
    if (rc != sql.SQLITE_DONE and rc != sql.SQLITE_ROW) return error.SqliteStepFailed;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "candidateNames: env 覆盖优先，缺省含发行版 SONAME" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 2), candidateNames().len);
    try testing.expectEqualStrings("libsqlite3.so.0", candidateNames()[0]);
    // 有 ZILT_SQLITE_PATH 时只剩一项
    //（不在此测 env 写入——candidateNames 每次读环境，进程内写 env 不安全）
}

test "sqlite: 打开内存库并执行往返" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const lib_ptr = try testing.allocator.create(Lib);
    defer testing.allocator.destroy(lib_ptr);
    lib_ptr.* = load() catch return error.SkipZigTest; // 本机无 libsqlite3 → skip

    const db = try open(lib_ptr, ":memory:", testing.allocator);
    defer close(db);

    var stmt: StmtHandle = null;
    const ddl = "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)";
    const z = try testing.allocator.allocSentinel(u8, ddl.len, 0);
    defer testing.allocator.free(z);
    @memcpy(z[0..ddl.len], ddl);
    try testing.expectEqual(sql.SQLITE_OK, db.lib.prepare(db.handle, z.ptr, @intCast(z.len), &stmt, null));
    try testing.expectEqual(sql.SQLITE_DONE, db.lib.step(stmt));
    try testing.expectEqual(sql.SQLITE_OK, db.lib.finalize(stmt));
}
