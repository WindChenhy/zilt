//! 项目元数据与前端工程配置——build.zig 与应用共用的单一配置源。
//! 纯数据（无模块依赖），build.zig 可直接 @import。

pub const app_name = "Zilt";
pub const publisher = "Zilt";
/// 运行时版本在 `src/zilt/version.zig`（zilt 模块内）；两处必须一致，
/// build.zig 顶部有编译期断言强制校验（不一致直接编译失败）。
pub const version = "0.5.6";
pub const app_id = "app.zilt.desktop";
pub const exe_name = "zilt-app.exe";

// 应用图标（.ico，相对项目根）。null = 内置 Zig 官方图标（窗口/托盘/exe 资源共用）。
// 自定义示例：pub const icon: ?[]const u8 = "frontend/app.ico";
pub const icon: ?[]const u8 = null;

// 前端工程配置（语义对齐 Tauri build 四件套）
// v0.3.4：侧车资源（resources）——随安装器/便携包分发的外部文件（相对项目根）。
// 目录 = 整树复制；文件 = 单文件。安装布局：<安装目录>/resources/<相对路径>。
// 运行时经 `window.zilt.path.resource(rel)` 解析（exe 目录 + resources/rel）。
pub const resources = [_][]const u8{
    "resources",
};

// v0.3.11 E1b：external_bin sidecar——按 target-triple 解析的外部二进制。
// 约定：<项目根>/bin/<name>-<triple>[.exe]（triple 如 x86_64-linux-gnu /
// x86_64-windows-gnu）；安装/打包时落在 exe 旁边（<name>[.exe]）。
// 运行时经 `window.zilt.path.sidecar(name)` 解析；spawn 走 process op
// （argv[0] 用绝对路径，ACL 声明 `shell:<name>`）。
pub const external_bin = [_][]const u8{};

pub const frontend = .{
    // 前端工程目录（package.json 所在处；build_command 的 cwd）
    .dir = "frontend",
    // 构建产物目录（嵌入来源；vanilla/htmx 无构建步骤时 = dir）
    .dist = "frontend",
    // dev 模式启动命令（如 "npm run dev"；null = 不 spawn，用 Dev.dir 轮询热重载）
    .dev_command = @as(?[]const u8, null),
    // dev server 地址（设置则 dev 模式直连，HMR 由 dev server 承担）
    .dev_url = @as(?[]const u8, null),
    // 生产构建命令（如 "npm run build"；null = 无需构建）
    .build_command = @as(?[]const u8, null),
    // 反代 dev 模式（Phase C）：true = dev 模式注入 ZILT_DEV_PROXY——应用保持自身
    // origin（custom scheme），资产请求转发 dev_url 上游；适合同源 cookie/fetch/SW 场景
    .dev_proxy = false,
    // 等待 dev_url 就绪超时（秒）
    .wait_timeout_secs = 90,
};
