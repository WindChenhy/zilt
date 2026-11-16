//! 电源/会话事件（v0.3.2）。平台事件码 → 统一事件名的纯函数映射：
//! - Windows：WM_POWERBROADCAST wParam（PBT_*）与 WM_WTSSESSION_CHANGE wParam（WTS_*）
//! - Linux：org.freedesktop.login1 的 PrepareForSleep/Lock/Unlock 信号（platform/linux 映射）
//!
//! 事件语义（前端 `window.zilt.on(...)`）：
//! - `powerSuspend`   系统进入睡眠
//! - `powerResume`    系统从睡眠恢复
//! - `powerStatusChanged` 电源状态变化（AC/电池/电量等级）
//! - `sessionLock`    会话锁定（Win+L / 锁屏）
//! - `sessionUnlock`  会话解锁
//!
//! 无载荷（载荷统一为 null）——订阅者按事件名分类即可。

const std = @import("std");

// ---- Windows 事件码（winuser.h / winbase.h）----
pub const PBT_APMSUSPEND: u32 = 4;
pub const PBT_APMRESUMESUSPEND: u32 = 7;
pub const PBT_APMPOWERSTATUSCHANGE: u32 = 10;
pub const PBT_APMRESUMEAUTOMATIC: u32 = 18;

pub const WTS_SESSION_LOGON: u32 = 5;
pub const WTS_SESSION_LOGOFF: u32 = 6;
pub const WTS_SESSION_LOCK: u32 = 7;
pub const WTS_SESSION_UNLOCK: u32 = 8;

pub const event_power_suspend = "powerSuspend";
pub const event_power_resume = "powerResume";
pub const event_power_status = "powerStatusChanged";
pub const event_session_lock = "sessionLock";
pub const event_session_unlock = "sessionUnlock";

/// WM_POWERBROADCAST wParam → 事件名；不关心的事件返回 null。
/// RESUMEAUTOMATIC 与 RESUMESUSPEND 都映射为 resume（前者是自动恢复标志，
/// 后者随后必到一次；语义上应用只需知道「已恢复」）。
pub fn powerEventName(code: u32) ?[]const u8 {
    return switch (code) {
        PBT_APMSUSPEND => event_power_suspend,
        PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND => event_power_resume,
        PBT_APMPOWERSTATUSCHANGE => event_power_status,
        else => null,
    };
}

/// WM_WTSSESSION_CHANGE wParam → 事件名；不关心的事件返回 null。
pub fn sessionEventName(code: u32) ?[]const u8 {
    return switch (code) {
        WTS_SESSION_LOCK => event_session_lock,
        WTS_SESSION_UNLOCK => event_session_unlock,
        else => null, // logon/logoff 场景有限，暂不暴露（进程随之退出）
    };
}

/// Linux logind PrepareForSleep 的 start 参数（true=进入睡眠）→ 事件名。
pub fn sleepEventName(start: bool) []const u8 {
    return if (start) event_power_suspend else event_power_resume;
}

const testing = std.testing;

test "v0.3.2: 电源事件码映射（suspend/resume/status/未知）" {
    try testing.expectEqualStrings("powerSuspend", powerEventName(PBT_APMSUSPEND).?);
    try testing.expectEqualStrings("powerResume", powerEventName(PBT_APMRESUMEAUTOMATIC).?);
    try testing.expectEqualStrings("powerResume", powerEventName(PBT_APMRESUMESUSPEND).?);
    try testing.expectEqualStrings("powerStatusChanged", powerEventName(PBT_APMPOWERSTATUSCHANGE).?);
    try testing.expect(powerEventName(0) == null);
    try testing.expect(powerEventName(32768) == null);
}

test "v0.3.2: 会话事件码映射（lock/unlock/logon/logoff 忽略）" {
    try testing.expectEqualStrings("sessionLock", sessionEventName(WTS_SESSION_LOCK).?);
    try testing.expectEqualStrings("sessionUnlock", sessionEventName(WTS_SESSION_UNLOCK).?);
    try testing.expect(sessionEventName(WTS_SESSION_LOGON) == null);
    try testing.expect(sessionEventName(WTS_SESSION_LOGOFF) == null);
    try testing.expect(sessionEventName(0) == null);
}

test "v0.3.2: logind sleep 参数映射" {
    try testing.expectEqualStrings("powerSuspend", sleepEventName(true));
    try testing.expectEqualStrings("powerResume", sleepEventName(false));
}
