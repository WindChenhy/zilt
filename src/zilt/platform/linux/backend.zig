//! Linux 平台后端 —— v0.2.0 只建立接口，GTK/WebKitGTK 实现尚未落地。
//!
//! 计划（详见 docs/v0.2-LINUX.md）：
//!   - GTK3 + WebKit2GTK 4.1 为默认栈，v0.2.5 增 GTK4 + WebKitGTK 6.0 变体
//!   - 事件循环：`g_application_run`；worker → UI 用 `g_idle_add` 封送
//!   - 资产/协议：`webkit_web_context_register_uri_scheme`
//!   - 单实例：`GApplication` 唯一 ID + 命令行转交
//!
//! 在 Linux 目标上编译时给出明确指引，而不是让用户面对「no member named run」。
const Config = @import("../../config.zig").Config;

pub const platform_name = "linux";

pub fn run(comptime config: Config) !void {
    _ = config;
    @compileError(
        \\Zilt: Linux 后端尚未实现（v0.2.0 起逐步落地）。
        \\  技术栈：GTK3 + WebKit2GTK 4.1（v0.2.5 增 GTK4 变体）
        \\  依赖：libgtk-3-dev libwebkit2gtk-4.1-dev pkg-config
        \\  计划与验收：docs/v0.2-LINUX.md
    );
}
