//! COM 基础设施：GUID / HRESULT / IUnknown / 事件处理器公共实现（引用计数）。
//!
//! 约定（本项目手写绑定的统一模式）：
//!  - 所有「我们实现的 COM 对象」= extern struct，首字段 lpVtbl，字段 refs: u32（原子操作）。
//!  - vtable 中函数指针的 this 参数一律用 *anyopaque，由 mixin 内部 @ptrCast 回具体类型，
//!    这样函数指针可以直赋给 vtable 字段。
//!  - Impl 需提供：`pub const COM_IIDS: []const GUID`（可 QI 出的接口）与
//!    `pub fn comDestroy(self: *Impl) void`（引用归零时释放）。

const std = @import("std");

pub const HRESULT = i32;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}
pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(a: GUID, b: GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }

    /// 编译期解析 "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" 或无花括号形式。
    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(20000);
        var t = s;
        if (t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}') t = t[1 .. t.len - 1];

        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (t) |c| {
            if (c == '-') continue;
            if (n >= 32) @compileError("GUID string has too many hex digits");
            buf[n] = c;
            n += 1;
        }
        if (n != 32) @compileError("GUID string must contain 32 hex digits");

        const hex = struct {
            fn v(ch: u8) u8 {
                return switch (ch) {
                    '0'...'9' => ch - '0',
                    'a'...'f' => ch - 'a' + 10,
                    'A'...'F' => ch - 'A' + 10,
                    else => @compileError("invalid hex digit in GUID string"),
                };
            }
        }.v;

        var g: GUID = undefined;
        g.data1 = std.fmt.parseInt(u32, buf[0..8], 16) catch unreachable;
        g.data2 = std.fmt.parseInt(u16, buf[8..12], 16) catch unreachable;
        g.data3 = std.fmt.parseInt(u16, buf[12..16], 16) catch unreachable;
        for (0..8) |i| {
            g.data4[i] = (hex(buf[16 + i * 2]) << 4) | hex(buf[17 + i * 2]);
        }
        return g;
    }
};

pub const IID_IUnknown: GUID = .parse("{00000000-0000-0000-C000-000000000046}");

/// 消费侧的标准 IUnknown 声明（用于 vtable 前三项类型对齐）。
pub const IUnknown = extern struct {
    lpVtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.c) u32,
        Release: *const fn (*IUnknown) callconv(.c) u32,
    };
};

/// 事件处理器 / CompletedHandler 的 QueryInterface-AddRef-Release 公共实现。
pub fn ComVTableMixin(comptime Impl: type) type {
    return struct {
        pub fn queryInterface(self_: *anyopaque, riid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
            out.* = null;
            if (riid.eql(IID_IUnknown)) {
                out.* = self_;
            } else {
                var hit = false;
                inline for (Impl.COM_IIDS) |iid| {
                    if (!hit and riid.eql(iid)) {
                        out.* = self_;
                        hit = true;
                    }
                }
                if (!hit) return E_NOINTERFACE;
            }
            _ = addRef(self_);
            return S_OK;
        }

        pub fn addRef(self_: *anyopaque) callconv(.c) u32 {
            const self: *Impl = @ptrCast(@alignCast(self_));
            const prev = @atomicRmw(u32, &self.refs, .Add, 1, .monotonic);
            return prev + 1;
        }

        pub fn release(self_: *anyopaque) callconv(.c) u32 {
            const self: *Impl = @ptrCast(@alignCast(self_));
            const prev = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
            if (prev == 1) {
                self.comDestroy();
            }
            return prev - 1;
        }
    };
}

/// 事件注册令牌（WebView2 的 add_/remove_ 事件对使用）。
pub const EventRegistrationToken = extern struct {
    value: i64,
};
