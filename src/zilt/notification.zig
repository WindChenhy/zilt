//! Platform-neutral notification data. All options are borrowed for the call only.
pub const Action = struct {
    title: []const u8,
    arguments: []const u8 = "",
    /// A registered protocol URI enables cold start. Without this, foreground
    /// activation is delivered only while the Windows Toast instance is alive.
    /// Protocol activation goes to the OS URI handler, not the Toast callback;
    /// Windows does not forward text input through that URI.
    launch: ?[]const u8 = null,
    input_id: ?[]const u8 = null,
};

pub const Input = struct {
    id: []const u8,
    placeholder: []const u8 = "",
    title: []const u8 = "",
};

pub const Progress = struct {
    title: []const u8 = "",
    /// null = indeterminate; otherwise finite and in [0, 1].
    value: ?f64 = null,
    value_string: []const u8 = "",
    status: []const u8,
};

pub const Options = struct {
    title: []const u8,
    body: []const u8,
    /// Windows replacement key is (AUMID, tag, group). Group requires a tag.
    tag: ?[]const u8 = null,
    group: ?[]const u8 = null,
    /// Registered protocol URI for clicking the toast body; no URI registration
    /// is performed here. Actions must opt in separately using Action.launch.
    launch: ?[]const u8 = null,
    actions: []const Action = &.{},
    input: ?Input = null,
    progress: ?Progress = null,
};

pub const UserInput = struct { id: []const u8, value: []const u8 };
pub const DismissalReason = enum(u32) { user_canceled = 0, application_hidden = 1, timed_out = 2, _ };
pub const Event = struct {
    tag: ?[]const u8 = null,
    group: ?[]const u8 = null,
    kind: union(enum) {
        activated: struct {
            arguments: []const u8,
            user_input: []const UserInput,
            /// True if an ABI/conversion/allocation error prevented complete decoding.
            data_error: bool = false,
        },
        dismissed: DismissalReason,
        failed: i32,
    },
};

/// Called on a WinRT thread, potentially concurrently for different toasts.
/// All event data is borrowed ONLY until return: copy it before queueing to main.
/// Do not call Toast methods/deinit from this callback (teardown waits for it).
/// Context must remain valid until Toast.deinit returns. Callbacks must not block
/// on the owner thread. The backend does not retain any caller option slices.
pub const Callback = struct {
    context: ?*anyopaque = null,
    function: *const fn (?*anyopaque, Event) void,
};

/// This is the notifier setting, not proof of banner visibility or history.
/// Focus Assist/Do Not Disturb can suppress banners even when enabled.
pub const Status = enum(u32) {
    enabled = 0,
    disabled_for_application = 1,
    disabled_for_user = 2,
    disabled_by_group_policy = 3,
    disabled_by_manifest = 4,
    _,
};

test {
    // Standalone test root: zig test src/zilt/notification.zig -lole32 -lshell32
    if (@import("builtin").os.tag == .windows) _ = @import("platform/windows/toast.zig");
}
