//! OLE copy-only drag/drop. Call create/revoke/destroy/startDrag on the window's
//! UI thread, after successful OleInitialize(null), not just CoInitializeEx.
//! Revoke before destroying the HWND; destroy before OleUninitialize. startDrag
//! runs OLE's nested message loop. The allocator must outlive all COM references.
//! Callback slices are borrowed; callbacks may destroy their target, but must not
//! recursively invoke its drag methods. No WM_DROPFILES fallback is installed.
const std = @import("std");
const builtin = @import("builtin");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const shared = @import("../../drag_drop.zig");
const Allocator = std.mem.Allocator;
const HR = com.HRESULT;
const GUID = com.GUID;
const Point = win32.POINT; // POINTL and POINT both contain two LONGs.

// Existing com.zig/win32.zig use .c, which is the Windows x64 ABI, not x86 stdcall.
comptime {
    if (builtin.cpu.arch != .x86_64) @compileError("OLE drag/drop currently requires Windows x64 bindings");
}

// Verified against Zig 0.17.1's any-windows-any/oleidl.h and objidl.h.
const iid_target: GUID = .parse("00000122-0000-0000-c000-000000000046");
const iid_source: GUID = .parse("00000121-0000-0000-c000-000000000046");
const iid_data: GUID = .parse("0000010e-0000-0000-c000-000000000046");
const iid_enum: GUID = .parse("00000103-0000-0000-c000-000000000046");
const E_OUTOFMEMORY: HR = @bitCast(@as(u32, 0x8007000e));
const DV_E_FORMATETC: HR = @bitCast(@as(u32, 0x80040064));
const DV_E_DVTARGETDEVICE: HR = @bitCast(@as(u32, 0x80040065));
const DV_E_LINDEX: HR = @bitCast(@as(u32, 0x80040068));
const DV_E_TYMED: HR = @bitCast(@as(u32, 0x80040069));
const DV_E_DVASPECT: HR = @bitCast(@as(u32, 0x8004006b));
const OLE_E_ADVISENOTSUPPORTED: HR = @bitCast(@as(u32, 0x80040003));
const DRAGDROP_S_DROP: HR = 0x40100;
const DRAGDROP_S_CANCEL: HR = 0x40101;
const DRAGDROP_S_USEDEFAULTCURSORS: HR = 0x40102;
const COPY: u32 = 1;
const CF_HDROP: u16 = 15;
const TYMED_HGLOBAL: u32 = 1;
const max_payload = 64 * 1024 * 1024;

const FormatEtc = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque = null,
    dwAspect: u32 = 1, // DVASPECT_CONTENT
    lindex: i32 = -1,
    tymed: u32 = TYMED_HGLOBAL,
};
// All members of the native STGMEDIUM union are pointer-sized. Do not use a
// packed struct: x64 has padding after tymed (24 bytes total, not 20).
const StgMedium = extern struct {
    tymed: u32 = 0,
    value: extern union { hGlobal: ?*anyopaque, pointer: ?*anyopaque } = .{ .hGlobal = null },
    pUnkForRelease: ?*anyopaque = null,
};
const DropFiles = extern struct {
    pFiles: u32 = 20,
    pt: Point = .{ .x = 0, .y = 0 },
    fNC: i32 = 0,
    fWide: i32 = 1,
};
const QI = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HR;
const Ref = *const fn (*anyopaque) callconv(.c) u32;
const TargetVtbl = extern struct {
    QueryInterface: QI,
    AddRef: Ref,
    Release: Ref,
    DragEnter: *const fn (*anyopaque, ?*DataObject, u32, Point, ?*u32) callconv(.c) HR,
    DragOver: *const fn (*anyopaque, u32, Point, ?*u32) callconv(.c) HR,
    DragLeave: *const fn (*anyopaque) callconv(.c) HR,
    Drop: *const fn (*anyopaque, ?*DataObject, u32, Point, ?*u32) callconv(.c) HR,
};
const SourceVtbl = extern struct {
    QueryInterface: QI,
    AddRef: Ref,
    Release: Ref,
    QueryContinueDrag: *const fn (*anyopaque, i32, u32) callconv(.c) HR,
    GiveFeedback: *const fn (*anyopaque, u32) callconv(.c) HR,
};
const DataVtbl = extern struct {
    QueryInterface: QI,
    AddRef: Ref,
    Release: Ref,
    GetData: *const fn (*anyopaque, ?*const FormatEtc, ?*StgMedium) callconv(.c) HR,
    GetDataHere: *const fn (*anyopaque, ?*const FormatEtc, ?*StgMedium) callconv(.c) HR,
    QueryGetData: *const fn (*anyopaque, ?*const FormatEtc) callconv(.c) HR,
    GetCanonicalFormatEtc: *const fn (*anyopaque, ?*const FormatEtc, ?*FormatEtc) callconv(.c) HR,
    SetData: *const fn (*anyopaque, ?*const FormatEtc, ?*StgMedium, i32) callconv(.c) HR,
    EnumFormatEtc: *const fn (*anyopaque, u32, ?*?*FormatEnumerator) callconv(.c) HR,
    DAdvise: *const fn (*anyopaque, ?*const FormatEtc, u32, ?*anyopaque, ?*u32) callconv(.c) HR,
    DUnadvise: *const fn (*anyopaque, u32) callconv(.c) HR,
    EnumDAdvise: *const fn (*anyopaque, ?*?*anyopaque) callconv(.c) HR,
};
const EnumVtbl = extern struct {
    QueryInterface: QI,
    AddRef: Ref,
    Release: Ref,
    Next: *const fn (*anyopaque, u32, ?[*]FormatEtc, ?*u32) callconv(.c) HR,
    Skip: *const fn (*anyopaque, u32) callconv(.c) HR,
    Reset: *const fn (*anyopaque) callconv(.c) HR,
    Clone: *const fn (*anyopaque, ?*?*FormatEnumerator) callconv(.c) HR,
};

extern "ole32" fn RegisterDragDrop(win32.HWND, *DropTarget) callconv(.c) HR;
extern "ole32" fn RevokeDragDrop(win32.HWND) callconv(.c) HR;
extern "ole32" fn DoDragDrop(*DataObject, *DropSource, u32, *u32) callconv(.c) HR;
extern "ole32" fn ReleaseStgMedium(*StgMedium) callconv(.c) void;
extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.c) u32;
extern "user32" fn ScreenToClient(win32.HWND, *Point) callconv(.c) i32;
extern "user32" fn IsWindow(win32.HWND) callconv(.c) i32;
extern "kernel32" fn GlobalSize(*anyopaque) callconv(.c) usize;
extern "kernel32" fn MultiByteToWideChar(u32, u32, [*]const u8, i32, ?[*]u16, i32) callconv(.c) i32;

fn cast(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

// Explicit little-endian byte access also accepts unaligned external HGLOBAL data.
fn read16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn read32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn append16(list: *std.ArrayList(u8), alloc: Allocator, value: u16) !void {
    try list.appendSlice(alloc, &.{ @truncate(value), @truncate(value >> 8) });
}

fn encodeDropFiles(alloc: Allocator, files: []const []const u8) ![]u8 {
    if (files.len == 0) return error.NoFiles;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    const header: DropFiles = .{};
    try bytes.appendSlice(alloc, std.mem.asBytes(&header));
    for (files) |file| {
        if (file.len == 0 or std.mem.indexOfScalar(u8, file, 0) != null) return error.InvalidPath;
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, file);
        defer alloc.free(wide);
        for (wide) |unit| try append16(&bytes, alloc, unit);
        try append16(&bytes, alloc, 0);
        if (bytes.items.len > max_payload - 2) return error.PayloadTooLarge;
    }
    try append16(&bytes, alloc, 0);
    return bytes.toOwnedSlice(alloc);
}

fn freeFiles(alloc: Allocator, files: []const []const u8) void {
    for (files) |file| alloc.free(file);
    alloc.free(files);
}

fn ansiToUtf8(alloc: Allocator, bytes: []const u8) ![]u8 {
    const len = std.math.cast(i32, bytes.len) orelse return error.InvalidDropFiles;
    // CF_HDROP fWide=FALSE means the system ANSI code page, not UTF-8.
    const count = MultiByteToWideChar(0, 0, bytes.ptr, len, null, 0);
    if (count <= 0) return error.InvalidDropFiles;
    const wide = try alloc.alloc(u16, @intCast(count));
    defer alloc.free(wide);
    if (MultiByteToWideChar(0, 0, bytes.ptr, len, wide.ptr, count) != count) return error.InvalidDropFiles;
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide);
}

fn parseDropFiles(alloc: Allocator, bytes: []const u8) ![][]const u8 {
    if (bytes.len < @sizeOf(DropFiles) or bytes.len > max_payload) return error.InvalidDropFiles;
    const offset: usize = read32(bytes, 0);
    const wide = read32(bytes, 16) != 0;
    const step: usize = if (wide) 2 else 1;
    if (offset < @sizeOf(DropFiles) or offset > bytes.len or bytes.len - offset < step * 2) return error.InvalidDropFiles;
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file| alloc.free(file);
        files.deinit(alloc);
    }
    var pos = offset;
    while (true) {
        const start = pos;
        while (true) {
            if (pos > bytes.len or bytes.len - pos < step) return error.InvalidDropFiles;
            const unit = if (wide) read16(bytes, pos) else bytes[pos];
            if (unit == 0) break;
            pos += step;
        }
        if (pos == start) {
            // Empty lists still need two terminators; nonempty lists already
            // consumed the previous filename's terminator.
            if (files.items.len == 0) {
                if (bytes.len - pos < step * 2) return error.InvalidDropFiles;
                if ((if (wide) read16(bytes, pos + step) else bytes[pos + step]) != 0) return error.InvalidDropFiles;
            }
            return files.toOwnedSlice(alloc);
        }
        const path = if (wide) blk: {
            const units = try alloc.alloc(u16, (pos - start) / 2);
            defer alloc.free(units);
            for (units, 0..) |*unit, i| unit.* = read16(bytes, start + i * 2);
            break :blk try std.unicode.utf16LeToUtf8Alloc(alloc, units);
        } else try ansiToUtf8(alloc, bytes[start..pos]);
        errdefer alloc.free(path);
        try files.append(alloc, path);
        pos += step;
    }
}

const RegisteredFormat = struct { name: []const u8, id: u16 };
const Snapshot = struct {
    files: []const []const u8 = &.{},
    custom: std.ArrayList(shared.CustomFormat) = .empty,

    fn deinit(self: *Snapshot, alloc: Allocator) void {
        freeFiles(alloc, self.files);
        for (self.custom.items) |item| alloc.free(item.data);
        self.custom.deinit(alloc);
        self.* = .{};
    }
    fn supported(self: *const Snapshot) bool {
        return self.files.len != 0 or self.custom.items.len != 0;
    }
};

// GetData transfers a STGMEDIUM, not necessarily an HGLOBAL owned by us.
// Always ReleaseStgMedium (including unsupported media) so pUnkForRelease works.
fn readGlobal(alloc: Allocator, object: *DataObject, id: u16) !?[]u8 {
    const format: FormatEtc = .{ .cfFormat = id };
    var medium: StgMedium = .{};
    if (com.failed(object.lpVtbl.GetData(object, &format, &medium))) return null;
    defer ReleaseStgMedium(&medium);
    if (medium.tymed != TYMED_HGLOBAL) return null;
    const handle = medium.value.hGlobal orelse return null;
    const size = GlobalSize(handle);
    if (size == 0 or size > max_payload) return null;
    const ptr = win32.GlobalLock(handle) orelse return null;
    defer _ = win32.GlobalUnlock(handle);
    return try alloc.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..size]);
}

fn readSnapshot(alloc: Allocator, object: *DataObject, formats: []const RegisteredFormat) !Snapshot {
    var result: Snapshot = .{};
    errdefer result.deinit(alloc);
    if (try readGlobal(alloc, object, CF_HDROP)) |bytes| {
        defer alloc.free(bytes);
        result.files = parseDropFiles(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => &.{}, // malformed external format is not accepted
        };
    }
    for (formats) |format| {
        if (try readGlobal(alloc, object, format.id)) |bytes| {
            errdefer alloc.free(bytes);
            try result.custom.append(alloc, .{ .name = format.name, .data = bytes });
        }
    }
    return result;
}

const TargetState = struct {
    alloc: Allocator,
    hwnd: win32.HWND,
    context: ?*anyopaque,
    callback: shared.Callback,
    formats: std.ArrayList(RegisteredFormat) = .empty,
    snapshot: Snapshot = .{},
    point: Point = .{ .x = 0, .y = 0 },
    registered: bool = false,
    destroyed: bool = false,
    active: bool = false,
};

pub const DropTarget = extern struct {
    lpVtbl: *const TargetVtbl = &vtable,
    refs: u32 = 1,
    state: *TargetState,
    pub const COM_IIDS: []const GUID = &.{iid_target};
    const mixin = com.ComVTableMixin(DropTarget);
    const vtable: TargetVtbl = .{
        .QueryInterface = mixin.queryInterface,
        .AddRef = mixin.addRef,
        .Release = mixin.release,
        .DragEnter = enter,
        .DragOver = over,
        .DragLeave = leave,
        .Drop = drop,
    };

    /// Copies format names. RegisterDragDrop owns an additional COM reference.
    /// Failure leaves no registration or caller-owned allocations behind.
    pub fn create(alloc: Allocator, hwnd: win32.HWND, context: ?*anyopaque, callback: shared.Callback, formats: []const []const u8) !*DropTarget {
        if (hwnd == null or IsWindow(hwnd) == 0) return error.InvalidWindow;
        const state = try alloc.create(TargetState);
        state.* = .{ .alloc = alloc, .hwnd = hwnd, .context = context, .callback = callback };
        const self = alloc.create(DropTarget) catch |err| {
            alloc.destroy(state);
            return err;
        };
        self.* = .{ .state = state };
        errdefer _ = mixin.release(self);
        for (formats) |name| {
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidFormatName;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
            defer alloc.free(wide);
            const id = RegisterClipboardFormatW(wide.ptr);
            if (id == 0) return error.RegisterFormatFailed;
            var duplicate = false;
            for (state.formats.items) |existing| {
                if (existing.id == id) duplicate = true;
            }
            if (duplicate) continue;
            const copy = try alloc.dupe(u8, name);
            errdefer alloc.free(copy);
            try state.formats.append(alloc, .{ .name = copy, .id = @intCast(id) });
        }
        if (com.failed(RegisterDragDrop(hwnd, self))) return error.RegisterDragDropFailed;
        state.registered = true;
        return self;
    }

    /// Idempotent. Keeps the caller's reference; destroy is still required.
    pub fn revoke(self: *DropTarget) !void {
        if (!self.state.registered) return;
        if (com.failed(RevokeDragDrop(self.state.hwnd))) return error.RevokeDragDropFailed;
        self.state.registered = false;
    }

    /// Call once. On revoke failure the COM registration retains the object,
    /// but callbacks are disabled so the context may safely be freed. Explicitly
    /// call revoke first if the caller needs to observe registration errors.
    pub fn destroy(self: *DropTarget) void {
        self.state.destroyed = true;
        self.revoke() catch {};
        _ = mixin.release(self);
    }

    pub fn comDestroy(self: *DropTarget) void {
        const state = self.state;
        const alloc = state.alloc;
        state.snapshot.deinit(alloc);
        for (state.formats.items) |format| alloc.free(format.name);
        state.formats.deinit(alloc);
        alloc.destroy(state);
        alloc.destroy(self);
    }

    fn emit(self: *DropTarget, kind: shared.Kind) void {
        const s = self.state;
        if (s.destroyed or !s.registered) return;
        s.callback(s.context, .{ .kind = kind, .x = s.point.x, .y = s.point.y, .files = s.snapshot.files, .custom = s.snapshot.custom.items });
    }
    fn position(self: *DropTarget, point: Point) bool {
        var client = point;
        if (ScreenToClient(self.state.hwnd, &client) == 0) return false;
        self.state.point = client;
        return true;
    }
    fn effect(self: *DropTarget, allowed: u32) u32 {
        const s = self.state;
        return if (s.registered and !s.destroyed and s.snapshot.supported()) allowed & COPY else 0;
    }
    fn enter(raw: *anyopaque, object: ?*DataObject, _: u32, point: Point, effect_out: ?*u32) callconv(.c) HR {
        const self = cast(DropTarget, raw);
        _ = mixin.addRef(self);
        defer _ = mixin.release(self);
        const out = effect_out orelse return com.E_POINTER;
        const allowed = out.*;
        out.* = 0;
        const s = self.state;
        s.snapshot.deinit(s.alloc);
        s.active = false;
        if (s.destroyed or !s.registered) return com.S_OK;
        const data = object orelse return com.E_POINTER;
        if (!self.position(point)) return com.E_FAIL;
        s.snapshot = readSnapshot(s.alloc, data, s.formats.items) catch return E_OUTOFMEMORY;
        s.active = true;
        self.emit(.enter);
        out.* = self.effect(allowed);
        return com.S_OK;
    }
    fn over(raw: *anyopaque, _: u32, point: Point, effect_out: ?*u32) callconv(.c) HR {
        const self = cast(DropTarget, raw);
        _ = mixin.addRef(self);
        defer _ = mixin.release(self);
        const out = effect_out orelse return com.E_POINTER;
        const allowed = out.*;
        out.* = 0;
        if (!self.state.active or self.state.destroyed or !self.state.registered) return com.S_OK;
        if (!self.position(point)) return com.E_FAIL;
        self.emit(.over);
        out.* = self.effect(allowed);
        return com.S_OK;
    }
    fn leave(raw: *anyopaque) callconv(.c) HR {
        const self = cast(DropTarget, raw);
        _ = mixin.addRef(self);
        defer _ = mixin.release(self);
        if (self.state.active) self.emit(.leave);
        self.state.active = false;
        self.state.snapshot.deinit(self.state.alloc);
        return com.S_OK;
    }
    fn drop(raw: *anyopaque, object: ?*DataObject, _: u32, point: Point, effect_out: ?*u32) callconv(.c) HR {
        const self = cast(DropTarget, raw);
        _ = mixin.addRef(self);
        defer _ = mixin.release(self);
        const s = self.state;
        defer {
            s.active = false;
            s.snapshot.deinit(s.alloc);
        }
        const out = effect_out orelse return com.E_POINTER;
        const allowed = out.*;
        out.* = 0;
        if (s.destroyed or !s.registered) return com.S_OK;
        const data = object orelse return com.E_POINTER;
        if (!self.position(point)) return com.E_FAIL;
        // The drop IDataObject can differ from the enter object; refresh data.
        s.snapshot.deinit(s.alloc);
        s.snapshot = readSnapshot(s.alloc, data, s.formats.items) catch return E_OUTOFMEMORY;
        // Never dispatch an actionable drop when the source forbids copying.
        if (self.effect(allowed) != 0) {
            self.emit(.drop);
            out.* = self.effect(allowed);
        }
        return com.S_OK;
    }
};

const EnumState = struct { alloc: Allocator, index: u32 = 0 };
// The data object exposes one device-independent format. Each enumerator and
// clone owns its cursor; ptd is always null (no shallow DVTARGETDEVICE copies).
const FormatEnumerator = extern struct {
    lpVtbl: *const EnumVtbl = &vtable,
    refs: u32 = 1,
    state: *EnumState,
    pub const COM_IIDS: []const GUID = &.{iid_enum};
    const mixin = com.ComVTableMixin(FormatEnumerator);
    const vtable: EnumVtbl = .{
        .QueryInterface = mixin.queryInterface,
        .AddRef = mixin.addRef,
        .Release = mixin.release,
        .Next = next,
        .Skip = skip,
        .Reset = reset,
        .Clone = clone,
    };
    fn create(alloc: Allocator, index: u32) !*FormatEnumerator {
        const s = try alloc.create(EnumState);
        errdefer alloc.destroy(s);
        s.* = .{ .alloc = alloc, .index = index };
        const self = try alloc.create(FormatEnumerator);
        self.* = .{ .state = s };
        return self;
    }
    pub fn comDestroy(self: *FormatEnumerator) void {
        const alloc = self.state.alloc;
        alloc.destroy(self.state);
        alloc.destroy(self);
    }
    fn next(raw: *anyopaque, count: u32, output: ?[*]FormatEtc, fetched: ?*u32) callconv(.c) HR {
        if (fetched) |ptr| ptr.* = 0;
        if (fetched == null and count != 1) return com.E_POINTER;
        if (count == 0) return com.S_OK;
        const out = output orelse return com.E_POINTER;
        const s = cast(FormatEnumerator, raw).state;
        const n: u32 = if (s.index == 0) 1 else 0;
        if (n == 1) out[0] = .{ .cfFormat = CF_HDROP };
        s.index += n;
        if (fetched) |ptr| ptr.* = n;
        return if (n == count) com.S_OK else com.S_FALSE;
    }
    fn skip(raw: *anyopaque, count: u32) callconv(.c) HR {
        const s = cast(FormatEnumerator, raw).state;
        const n = @min(count, 1 - s.index);
        s.index += n;
        return if (n == count) com.S_OK else com.S_FALSE;
    }
    fn reset(raw: *anyopaque) callconv(.c) HR {
        cast(FormatEnumerator, raw).state.index = 0;
        return com.S_OK;
    }
    fn clone(raw: *anyopaque, output: ?*?*FormatEnumerator) callconv(.c) HR {
        const out = output orelse return com.E_POINTER;
        out.* = null;
        const s = cast(FormatEnumerator, raw).state;
        out.* = create(s.alloc, s.index) catch return E_OUTOFMEMORY;
        return com.S_OK;
    }
};

const DataState = struct { alloc: Allocator, bytes: []u8 };
const DataObject = extern struct {
    lpVtbl: *const DataVtbl = &vtable,
    refs: u32 = 1,
    state: *DataState,
    pub const COM_IIDS: []const GUID = &.{iid_data};
    const mixin = com.ComVTableMixin(DataObject);
    const vtable: DataVtbl = .{
        .QueryInterface = mixin.queryInterface,
        .AddRef = mixin.addRef,
        .Release = mixin.release,
        .GetData = getData,
        .GetDataHere = getDataHere,
        .QueryGetData = queryGetData,
        .GetCanonicalFormatEtc = canonical,
        .SetData = setData,
        .EnumFormatEtc = enumFormats,
        .DAdvise = advise,
        .DUnadvise = unadvise,
        .EnumDAdvise = enumAdvise,
    };
    fn create(alloc: Allocator, files: []const []const u8) !*DataObject {
        const bytes = try encodeDropFiles(alloc, files);
        errdefer alloc.free(bytes);
        const s = try alloc.create(DataState);
        errdefer alloc.destroy(s);
        s.* = .{ .alloc = alloc, .bytes = bytes };
        const self = try alloc.create(DataObject);
        self.* = .{ .state = s };
        return self;
    }
    pub fn comDestroy(self: *DataObject) void {
        const s = self.state;
        const alloc = s.alloc;
        alloc.free(s.bytes);
        alloc.destroy(s);
        alloc.destroy(self);
    }
    fn queryGetData(_: *anyopaque, input: ?*const FormatEtc) callconv(.c) HR {
        const f = input orelse return com.E_POINTER;
        if (f.cfFormat != CF_HDROP) return DV_E_FORMATETC;
        if (f.ptd != null) return DV_E_DVTARGETDEVICE;
        if (f.dwAspect != 1) return DV_E_DVASPECT;
        if (f.lindex != -1) return DV_E_LINDEX;
        if (f.tymed & TYMED_HGLOBAL == 0) return DV_E_TYMED;
        return com.S_OK;
    }
    fn getData(raw: *anyopaque, input: ?*const FormatEtc, output: ?*StgMedium) callconv(.c) HR {
        const out = output orelse return com.E_POINTER;
        out.* = .{};
        const hr = queryGetData(raw, input);
        if (com.failed(hr)) return hr;
        const bytes = cast(DataObject, raw).state.bytes;
        const handle = win32.GlobalAlloc(0x42, bytes.len) orelse return E_OUTOFMEMORY; // MOVEABLE | ZEROINIT
        const ptr = win32.GlobalLock(handle) orelse {
            _ = win32.GlobalFree(handle);
            return E_OUTOFMEMORY;
        };
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
        _ = win32.GlobalUnlock(handle);
        out.* = .{ .tymed = TYMED_HGLOBAL, .value = .{ .hGlobal = handle } };
        return com.S_OK; // receiver must ReleaseStgMedium
    }
    fn getDataHere(_: *anyopaque, _: ?*const FormatEtc, _: ?*StgMedium) callconv(.c) HR {
        return com.E_NOTIMPL;
    }
    fn canonical(_: *anyopaque, _: ?*const FormatEtc, output: ?*FormatEtc) callconv(.c) HR {
        const out = output orelse return com.E_POINTER;
        out.ptd = null;
        return com.E_NOTIMPL;
    }
    fn setData(_: *anyopaque, _: ?*const FormatEtc, _: ?*StgMedium, _: i32) callconv(.c) HR {
        return com.E_NOTIMPL; // never claim ownership of a rejected medium
    }
    fn enumFormats(raw: *anyopaque, direction: u32, output: ?*?*FormatEnumerator) callconv(.c) HR {
        const out = output orelse return com.E_POINTER;
        out.* = null;
        if (direction != 1) return com.E_NOTIMPL; // DATADIR_GET only
        out.* = FormatEnumerator.create(cast(DataObject, raw).state.alloc, 0) catch return E_OUTOFMEMORY;
        return com.S_OK;
    }
    fn advise(_: *anyopaque, _: ?*const FormatEtc, _: u32, _: ?*anyopaque, connection: ?*u32) callconv(.c) HR {
        if (connection) |out| out.* = 0;
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn unadvise(_: *anyopaque, _: u32) callconv(.c) HR {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn enumAdvise(_: *anyopaque, output: ?*?*anyopaque) callconv(.c) HR {
        if (output) |out| out.* = null;
        return OLE_E_ADVISENOTSUPPORTED;
    }
};

const SourceState = struct { alloc: Allocator };
const DropSource = extern struct {
    lpVtbl: *const SourceVtbl = &vtable,
    refs: u32 = 1,
    state: *SourceState,
    pub const COM_IIDS: []const GUID = &.{iid_source};
    const mixin = com.ComVTableMixin(DropSource);
    const vtable: SourceVtbl = .{
        .QueryInterface = mixin.queryInterface,
        .AddRef = mixin.addRef,
        .Release = mixin.release,
        .QueryContinueDrag = continueDrag,
        .GiveFeedback = feedback,
    };
    fn create(alloc: Allocator) !*DropSource {
        const s = try alloc.create(SourceState);
        errdefer alloc.destroy(s);
        s.* = .{ .alloc = alloc };
        const self = try alloc.create(DropSource);
        self.* = .{ .state = s };
        return self;
    }
    pub fn comDestroy(self: *DropSource) void {
        const alloc = self.state.alloc;
        alloc.destroy(self.state);
        alloc.destroy(self);
    }
    fn continueDrag(_: *anyopaque, escape: i32, keys: u32) callconv(.c) HR {
        if (escape != 0 or keys & 2 != 0) return DRAGDROP_S_CANCEL; // Escape or right button
        if (keys & 1 == 0) return DRAGDROP_S_DROP; // left button released
        return com.S_OK;
    }
    fn feedback(_: *anyopaque, _: u32) callconv(.c) HR {
        return DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

/// Starts a left-button file drag on the OLE-initialized UI thread. Paths are
/// copied immediately; callers should supply absolute UTF-8 filesystem paths.
/// Cancellation is normal success. Only DROPEFFECT_COPY is offered, even when
/// Shift is pressed. This function never moves/deletes files or sets MOVE data.
pub fn startDrag(alloc: Allocator, hwnd: win32.HWND, files: []const []const u8) !void {
    if (hwnd == null or IsWindow(hwnd) == 0) return error.InvalidWindow;
    const data = try DataObject.create(alloc, files);
    defer _ = DataObject.mixin.release(data);
    const source = try DropSource.create(alloc);
    defer _ = DropSource.mixin.release(source);
    var effect: u32 = 0;
    const hr = DoDragDrop(data, source, COPY, &effect);
    if (hr != DRAGDROP_S_DROP and hr != DRAGDROP_S_CANCEL and com.failed(hr)) return error.DoDragDropFailed;
}

test "DROPFILES Unicode roundtrip, header and double termination" {
    const alloc = std.testing.allocator;
    const paths = [_][]const u8{ "C:\\a.txt", "D:\\文件\\\u{1f642}.txt" };
    const bytes = try encodeDropFiles(alloc, &paths);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(u32, 20), read32(bytes, 0));
    try std.testing.expectEqual(@as(u32, 1), read32(bytes, 16));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[bytes.len - 4 ..]);
    const parsed = try parseDropFiles(alloc, bytes);
    defer freeFiles(alloc, parsed);
    try std.testing.expectEqual(paths.len, parsed.len);
    for (paths, parsed) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectError(error.NoFiles, encodeDropFiles(alloc, &.{}));
    try std.testing.expectError(error.InvalidPath, encodeDropFiles(alloc, &.{""}));
    try std.testing.expectError(error.InvalidPath, encodeDropFiles(alloc, &.{"a\x00b"}));
}

test "DROPFILES rejects truncation, bad offsets and invalid UTF16" {
    const alloc = std.testing.allocator;
    const bytes = try encodeDropFiles(alloc, &.{"C:\\a"});
    defer alloc.free(bytes);
    for (0..bytes.len) |len| {
        try std.testing.expectError(error.InvalidDropFiles, parseDropFiles(alloc, bytes[0..len]));
    }
    bytes[0] = 19;
    try std.testing.expectError(error.InvalidDropFiles, parseDropFiles(alloc, bytes));
    bytes[0] = 255;
    try std.testing.expectError(error.InvalidDropFiles, parseDropFiles(alloc, bytes));
    bytes[0] = 20;
    bytes[20] = 0;
    bytes[21] = 0xd8;
    try std.testing.expectError(error.ExpectedSecondSurrogateHalf, parseDropFiles(alloc, bytes));
}

test "DROPFILES empty list, unaligned offset and trailing global padding" {
    const alloc = std.testing.allocator;
    var bytes: [32]u8 = @splat(0);
    bytes[0] = 21;
    bytes[16] = 1;
    const empty = try parseDropFiles(alloc, &bytes);
    defer freeFiles(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    bytes[21] = 'a';
    bytes[31] = 255; // HGLOBAL padding after double NUL is not a filename
    const files = try parseDropFiles(alloc, &bytes);
    defer freeFiles(alloc, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("a", files[0]);
}

test "IEnumFORMATETC Next Skip Reset Clone and COM identity" {
    const e = try FormatEnumerator.create(std.testing.allocator, 0);
    defer _ = e.lpVtbl.Release(e);
    var formats: [2]FormatEtc = undefined;
    var fetched: u32 = 123;
    try std.testing.expectEqual(com.E_POINTER, e.lpVtbl.Next(e, 2, &formats, null));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Next(e, 0, null, &fetched));
    try std.testing.expectEqual(@as(u32, 0), fetched);
    try std.testing.expectEqual(com.S_FALSE, e.lpVtbl.Next(e, 2, &formats, &fetched));
    try std.testing.expectEqual(@as(u32, 1), fetched);
    try std.testing.expectEqual(CF_HDROP, formats[0].cfFormat);
    try std.testing.expect(formats[0].ptd == null);
    var copy: ?*FormatEnumerator = null;
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Clone(e, &copy));
    defer _ = copy.?.lpVtbl.Release(copy.?);
    try std.testing.expectEqual(com.S_FALSE, copy.?.lpVtbl.Next(copy.?, 1, &formats, null));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Reset(e));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Next(e, 1, &formats, null));
    try std.testing.expectEqual(com.S_FALSE, e.lpVtbl.Skip(e, std.math.maxInt(u32)));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Skip(e, 0));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Reset(e));
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.Skip(e, 1));
    var unknown: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, e.lpVtbl.QueryInterface(e, &com.IID_IUnknown, &unknown));
    try std.testing.expect(unknown.? == @as(*anyopaque, @ptrCast(e)));
    _ = e.lpVtbl.Release(unknown.?);
    try std.testing.expectEqual(com.E_NOINTERFACE, e.lpVtbl.QueryInterface(e, &iid_data, &unknown));
    try std.testing.expect(unknown == null);
}

test "IDataObject format negotiation and copy-only source" {
    const data = try DataObject.create(std.testing.allocator, &.{"C:\\a.txt"});
    defer _ = data.lpVtbl.Release(data);
    var format: FormatEtc = .{ .cfFormat = CF_HDROP };
    try std.testing.expectEqual(com.S_OK, data.lpVtbl.QueryGetData(data, &format));
    format.tymed = 3;
    try std.testing.expectEqual(com.S_OK, data.lpVtbl.QueryGetData(data, &format));
    format.tymed = 2;
    try std.testing.expectEqual(DV_E_TYMED, data.lpVtbl.QueryGetData(data, &format));
    format.tymed = 1;
    format.lindex = 0;
    try std.testing.expectEqual(DV_E_LINDEX, data.lpVtbl.QueryGetData(data, &format));
    format.lindex = -1;
    format.dwAspect = 2;
    try std.testing.expectEqual(DV_E_DVASPECT, data.lpVtbl.QueryGetData(data, &format));
    format.dwAspect = 1;
    format.cfFormat = 1;
    try std.testing.expectEqual(DV_E_FORMATETC, data.lpVtbl.QueryGetData(data, &format));
    var enumerator: ?*FormatEnumerator = null;
    try std.testing.expectEqual(com.E_NOTIMPL, data.lpVtbl.EnumFormatEtc(data, 2, &enumerator));
    try std.testing.expect(enumerator == null);
    const source = try DropSource.create(std.testing.allocator);
    defer _ = source.lpVtbl.Release(source);
    try std.testing.expectEqual(com.S_OK, source.lpVtbl.QueryContinueDrag(source, 0, 1));
    try std.testing.expectEqual(DRAGDROP_S_DROP, source.lpVtbl.QueryContinueDrag(source, 0, 0));
    try std.testing.expectEqual(DRAGDROP_S_CANCEL, source.lpVtbl.QueryContinueDrag(source, 1, 1));
    try std.testing.expectEqual(DRAGDROP_S_CANCEL, source.lpVtbl.QueryContinueDrag(source, 0, 3));
    try std.testing.expectEqual(DRAGDROP_S_USEDEFAULTCURSORS, source.lpVtbl.GiveFeedback(source, COPY));
}

test "all public entry points compile without backend wiring" {
    const Callback = struct {
        fn call(_: ?*anyopaque, _: shared.Event) void {}
    };
    try std.testing.expectError(error.InvalidWindow, DropTarget.create(std.testing.allocator, null, null, Callback.call, &.{}));
    try std.testing.expectError(error.InvalidWindow, startDrag(std.testing.allocator, null, &.{"C:\\a"}));
}

test "x64 ABI sizes offsets and every COM vtable slot" {
    // These values were independently checked with zig cc static assertions
    // against the installed MinGW oleidl.h/objidl.h/shlobj.h, not inferred from
    // these Zig declarations. Zig 0.17 no longer supports @cImport.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(FormatEtc));
    inline for (.{ "cfFormat", "ptd", "dwAspect", "lindex", "tymed" }, .{ 0, 8, 16, 20, 24 }) |field, offset| {
        try std.testing.expectEqual(@as(usize, offset), @offsetOf(FormatEtc, field));
    }
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(DropFiles));
    inline for (.{ "pFiles", "pt", "fNC", "fWide" }, .{ 0, 4, 12, 16 }) |field, offset| {
        try std.testing.expectEqual(@as(usize, offset), @offsetOf(DropFiles, field));
    }
    inline for (.{
        .{ TargetVtbl, .{ "QueryInterface", "AddRef", "Release", "DragEnter", "DragOver", "DragLeave", "Drop" } },
        .{ SourceVtbl, .{ "QueryInterface", "AddRef", "Release", "QueryContinueDrag", "GiveFeedback" } },
        .{ DataVtbl, .{ "QueryInterface", "AddRef", "Release", "GetData", "GetDataHere", "QueryGetData", "GetCanonicalFormatEtc", "SetData", "EnumFormatEtc", "DAdvise", "DUnadvise", "EnumDAdvise" } },
        .{ EnumVtbl, .{ "QueryInterface", "AddRef", "Release", "Next", "Skip", "Reset", "Clone" } },
    }) |types| {
        try std.testing.expectEqual(@as(usize, types[1].len * 8), @sizeOf(types[0]));
        inline for (types[1], 0..) |field, index| try std.testing.expectEqual(index * 8, @offsetOf(types[0], field));
    }
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(StgMedium));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(StgMedium));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(StgMedium, "tymed"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(StgMedium, "value"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(StgMedium, "pUnkForRelease"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Point));
}

test "HGLOBAL GetData returns independent media and roundtrips through reader" {
    const alloc = std.testing.allocator;
    const data = try DataObject.create(alloc, &.{"C:\\file.txt"});
    defer _ = data.lpVtbl.Release(data);
    const format: FormatEtc = .{ .cfFormat = CF_HDROP };
    var a: StgMedium = .{};
    var b: StgMedium = .{};
    try std.testing.expectEqual(com.S_OK, data.lpVtbl.GetData(data, &format, &a));
    defer ReleaseStgMedium(&a);
    try std.testing.expectEqual(com.S_OK, data.lpVtbl.GetData(data, &format, &b));
    defer ReleaseStgMedium(&b);
    try std.testing.expect(a.value.hGlobal != b.value.hGlobal);
    var snapshot = try readSnapshot(alloc, data, &.{});
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.supported());
    try std.testing.expectEqualStrings("C:\\file.txt", snapshot.files[0]);
}

test "ANSI DROPFILES uses bounded codepage conversion" {
    const alloc = std.testing.allocator;
    var bytes: [25]u8 = @splat(0);
    bytes[0] = 20;
    bytes[20] = 'a';
    const files = try parseDropFiles(alloc, &bytes);
    defer freeFiles(alloc, files);
    try std.testing.expectEqualStrings("a", files[0]);
    @memset(bytes[20..], 'x');
    try std.testing.expectError(error.InvalidDropFiles, parseDropFiles(alloc, &bytes));
}

fn allocationPaths(alloc: Allocator) !void {
    const data = try DataObject.create(alloc, &.{ "C:\\one", "D:\\two" });
    defer _ = data.lpVtbl.Release(data);
    const parsed = try parseDropFiles(alloc, data.state.bytes);
    defer freeFiles(alloc, parsed);
    const enumerator = try FormatEnumerator.create(alloc, 0);
    defer _ = enumerator.lpVtbl.Release(enumerator);
    const source = try DropSource.create(alloc);
    defer _ = source.lpVtbl.Release(source);
}

test "allocation failure cleanup for payloads and COM objects" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPaths, .{});
}

const TestMediumOwner = extern struct {
    lpVtbl: *const VTable = &vtable,
    refs: u32 = 1,
    handle: ?*anyopaque = null,
    releases: *u32,
    pub const COM_IIDS: []const GUID = &.{};
    const VTable = extern struct { QueryInterface: QI, AddRef: Ref, Release: Ref };
    const mixin = com.ComVTableMixin(TestMediumOwner);
    const vtable: VTable = .{ .QueryInterface = mixin.queryInterface, .AddRef = mixin.addRef, .Release = mixin.release };
    pub fn comDestroy(self: *TestMediumOwner) void {
        self.releases.* += 1;
        _ = win32.GlobalFree(self.handle);
        self.handle = null;
    }
};

const TestProvider = extern struct {
    lpVtbl: *const DataVtbl = &vtable,
    medium: StgMedium,
    id: u16,
    const vtable = blk: {
        var table = DataObject.vtable;
        table.GetData = get;
        break :blk table;
    };
    fn get(raw: *anyopaque, input: ?*const FormatEtc, output: ?*StgMedium) callconv(.c) HR {
        const self = cast(TestProvider, raw);
        const out = output orelse return com.E_POINTER;
        out.* = .{};
        const format = input orelse return com.E_POINTER;
        if (format.cfFormat != self.id) return DV_E_FORMATETC;
        out.* = self.medium;
        self.medium = .{}; // transfer exactly once, including the owner's reference
        return com.S_OK;
    }
};

test "external media are released through pUnkForRelease even when rejected" {
    const alloc = std.testing.allocator;
    var releases: u32 = 0;
    var owner: TestMediumOwner = .{ .releases = &releases };
    var provider: TestProvider = .{ .id = CF_HDROP, .medium = .{ .tymed = 4, .pUnkForRelease = &owner } };
    try std.testing.expect((try readGlobal(alloc, @ptrCast(&provider), CF_HDROP)) == null);
    try std.testing.expectEqual(@as(u32, 1), releases);
    owner.refs = 1;
    provider.medium = .{ .tymed = TYMED_HGLOBAL, .pUnkForRelease = &owner };
    try std.testing.expect((try readGlobal(alloc, @ptrCast(&provider), CF_HDROP)) == null);
    try std.testing.expectEqual(@as(u32, 2), releases);
    owner.refs = 1;
    owner.handle = win32.GlobalAlloc(2, 0) orelse return error.OutOfMemory;
    provider.medium = .{ .tymed = TYMED_HGLOBAL, .value = .{ .hGlobal = owner.handle }, .pUnkForRelease = &owner };
    try std.testing.expect((try readGlobal(alloc, @ptrCast(&provider), CF_HDROP)) == null);
    try std.testing.expectEqual(@as(u32, 3), releases);
}

test "custom bytes survive medium release and unsupported formats are omitted" {
    const alloc = std.testing.allocator;
    const payload = "\x00\xff\x01binary\x00";
    var releases: u32 = 0;
    var owner: TestMediumOwner = .{ .releases = &releases };
    owner.handle = win32.GlobalAlloc(0x42, payload.len) orelse return error.OutOfMemory;
    const ptr = win32.GlobalLock(owner.handle.?) orelse {
        _ = win32.GlobalFree(owner.handle);
        return error.OutOfMemory;
    };
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..payload.len], payload);
    _ = win32.GlobalUnlock(owner.handle.?);
    var provider: TestProvider = .{ .id = 0xc001, .medium = .{
        .tymed = TYMED_HGLOBAL,
        .value = .{ .hGlobal = owner.handle },
        .pUnkForRelease = &owner,
    } };
    var snapshot = try readSnapshot(alloc, @ptrCast(&provider), &.{
        .{ .id = 0xc001, .name = "Zilt.Test.Bytes" },
        .{ .id = 0xc002, .name = "Zilt.Test.Missing" },
    });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), releases);
    try std.testing.expectEqual(@as(usize, 0), snapshot.files.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.custom.items.len);
    try std.testing.expectEqualStrings("Zilt.Test.Bytes", snapshot.custom.items[0].name);
    try std.testing.expectEqualSlices(u8, payload, snapshot.custom.items[0].data[0..payload.len]);
}

// Windows smoke test: actual OLE registration, but deterministic direct vtable
// dispatch, not an interactive Explorer drag or DoDragDrop nested message loop.
test "registered target client coordinates lifecycle copy effect and callback destruction" {
    const Native = struct {
        extern "ole32" fn OleInitialize(?*anyopaque) callconv(.c) HR;
        extern "ole32" fn OleUninitialize() callconv(.c) void;
        extern "user32" fn ClientToScreen(win32.HWND, *Point) callconv(.c) i32;
    };
    const Events = struct {
        kinds: [8]shared.Kind = undefined,
        len: usize = 0,
        valid: bool = true,
        target: ?*DropTarget = null,
        destroy_on_event: bool = false,
        fn callback(raw: ?*anyopaque, event: shared.Event) void {
            const self = cast(@This(), raw.?);
            self.kinds[self.len] = event.kind;
            self.len += 1;
            self.valid = self.valid and event.x == -7 and event.y == 9 and event.files.len == 1;
            if (event.files.len == 1) self.valid = self.valid and std.mem.eql(u8, event.files[0], "C:\\test.txt");
            if (self.destroy_on_event) {
                self.target.?.destroy();
                self.target = null;
                // Borrowed data remains alive until this callback returns.
                self.valid = self.valid and std.mem.eql(u8, event.files[0], "C:\\test.txt");
            }
        }
    };
    try std.testing.expect(com.succeeded(Native.OleInitialize(null)));
    defer Native.OleUninitialize();
    const hwnd = win32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Zilt OLE test"), 0, 80, 100, 100, 100, null, null, null, null);
    try std.testing.expect(hwnd != null);
    defer _ = win32.DestroyWindow(hwnd);
    var events: Events = .{};
    events.target = try DropTarget.create(std.testing.allocator, hwnd, &events, Events.callback, &.{ "Zilt.Test.Bytes", "Zilt.Test.Bytes" });
    defer if (events.target) |target| target.destroy();
    const target = events.target.?;
    try std.testing.expectEqual(@as(usize, 1), target.state.formats.items.len);
    const data = try DataObject.create(std.testing.allocator, &.{"C:\\test.txt"});
    defer _ = data.lpVtbl.Release(data);
    var point: Point = .{ .x = -7, .y = 9 };
    try std.testing.expect(Native.ClientToScreen(hwnd, &point) != 0);
    var effect: u32 = 3; // COPY | MOVE: the target must return COPY only.
    try std.testing.expectEqual(com.S_OK, target.lpVtbl.DragEnter(target, data, 0, point, &effect));
    try std.testing.expectEqual(COPY, effect);
    effect = 3;
    try std.testing.expectEqual(com.S_OK, target.lpVtbl.DragOver(target, 0, point, &effect));
    try std.testing.expectEqual(COPY, effect);
    try std.testing.expectEqual(com.S_OK, target.lpVtbl.DragLeave(target));
    effect = 3;
    _ = target.lpVtbl.DragEnter(target, data, 0, point, &effect);
    effect = 3;
    try std.testing.expectEqual(com.S_OK, target.lpVtbl.Drop(target, data, 0, point, &effect));
    try std.testing.expectEqual(COPY, effect);
    try std.testing.expectEqualSlices(shared.Kind, &.{ .enter, .over, .leave, .enter, .drop }, events.kinds[0..events.len]);
    effect = 2; // MOVE-only drops must not dispatch an actionable callback.
    _ = target.lpVtbl.DragEnter(target, data, 0, point, &effect);
    try std.testing.expectEqual(@as(u32, 0), effect);
    effect = 2;
    _ = target.lpVtbl.Drop(target, data, 0, point, &effect);
    try std.testing.expectEqual(@as(u32, 0), effect);
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try target.revoke();
    try target.revoke();
    target.destroy();
    events.target = null;
    events.target = try DropTarget.create(std.testing.allocator, hwnd, &events, Events.callback, &.{});
    events.destroy_on_event = true;
    const last_target = events.target.?;
    effect = COPY;
    try std.testing.expectEqual(com.S_OK, last_target.lpVtbl.DragEnter(last_target, data, 0, point, &effect));
    try std.testing.expect(events.target == null);
    try std.testing.expect(events.valid);
}
