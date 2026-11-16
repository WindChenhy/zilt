//! 应用配置。

const service_mod = @import("services.zig");
pub const Service = service_mod.Service;

pub const Asset = struct {
    /// URL 路径（如 "/index.html"、"/"）
    path: []const u8,
    /// 存储字节：原始内容或 gzip 压缩内容（见 encoding）
    content: []const u8,
    /// content 的存储编码。.gzip 时服务端首次请求惰性解压并缓存进程内
    /// （Tauri brotli 同款：预压缩收益为 exe 体积，服务字节始终 identity——
    /// 实测 WebView2 custom scheme 响应不经过网络栈内容解码，不能下发压缩字节）。
    encoding: Encoding = .identity,

    pub const Encoding = enum { identity, gzip };
};

pub const Config = struct {
    /// 命令命名空间：`pub fn 名字(ctx: Context, args: struct{...}) !结果`（JS→Zig 调用）
    commands: type,
    /// 事件命名空间：`pub fn 名字(ctx: Context, payload: struct{...}) void`（JS→Zig 事件，可选）
    events: type = struct {},
    /// 内嵌资产表（release/embedded 模式经 custom scheme 服务）
    assets: []const Asset = &.{},

    /// 窗口标题
    title: [:0]const u8 = "Zilt App",
    width: u32 = 900,
    height: u32 = 640,
    /// 初始位置（null = 系统默认）
    x: ?i32 = null,
    y: ?i32 = null,
    /// 创建时是否可见
    visible: bool = true,
    /// 是否可调整大小
    resizable: bool = true,
    /// 是否带原生标题栏/边框
    decorations: bool = true,
    /// v0.1.23：覆盖式标题栏——客户区覆盖整个窗口（无原生标题栏/边框），前端自绘。
    /// 需要配合 `data-zilt-drag-region` 实现拖动，四边仍可缩放。
    titlebar_overlay: bool = false,
    /// WebView 背景透明（桌面透出）
    transparent: bool = false,
    /// 窗口置顶
    always_on_top: bool = false,
    /// 从任务栏/Alt-Tab 隐藏
    skip_taskbar: bool = false,
    /// 最小/最大窗口尺寸（外层像素）
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    /// WebView 默认背景色（0xRRGGBB；null = 白色）
    background_color: ?u32 = null,
    /// 主窗口关闭前发 windowCloseRequested（需前端调用 windowClose 才关闭）
    close_requested_event: bool = false,

    /// 应用 URL（embedded 模式）；约定 origin 由它推导（如 https://zilt.app）
    url: []const u8 = "https://zilt.app/index.html",
    /// origin 校验允许列表（默认从 url 推导；dev.url 模式自动加入对应 origin）
    origin: ?[]const u8 = null,
    /// 应用 ID（单实例互斥体名等）
    app_id: []const u8 = "app.zilt",
    dev: Dev = .{},
    /// CSP / 导航白名单 / capability ACL / 远程内容边界（v0.1.8 + v0.1.11）
    security: @import("security.zig").Options = .{},
    /// WebView 引擎选项：事件面、Settings、下载、权限、渲染进程恢复（v0.1.9/v0.1.10）
    webview: @import("webview.zig").Options = .{},
    /// WebView2 环境选项：UA / 语言 / 代理 / 浏览器参数 / 运行时通道（v0.1.10）
    environment: @import("environment.zig").Options = .{},
    /// v0.1.19：注入到每个页面 document-start 的用户脚本（对齐 Tauri initialization_script）。
    /// 在框架 runtime 之后注入，可直接使用 window.zilt。
    init_scripts: []const []const u8 = &.{},
    /// v0.1.24：应用自定义协议处理器（`/__proto/<name>/…`，见 protocol.zig）。
    protocols: []const @import("protocol.zig").Protocol = &.{},
    /// 主窗口状态持久化键（null = 不持久化；与 persist_window_state 配合按窗口 label 保存）
    state_key: ?[]const u8 = null,
    /// 所有窗口按 label 持久化位置/尺寸/最大化/全屏（v0.1.8）
    persist_window_state: bool = false,
    /// 迁移旧的 %TEMP%\zilt-app-webview2 共享数据目录（v0.1.8）
    migrate_legacy_profile: bool = false,
    /// 监听系统剪贴板变化并发 clipboardChanged 事件（v0.1.12）
    /// v0.3.5：store 值加密（Windows DPAPI 当前用户作用域；`dpapi:` 前缀标记）。
    /// Linux 无 DPAPI → 忽略（明文落盘，文档化；libsecret 列 v0.4+）。
    store_encrypted: bool = false,
    clipboard_change_event: bool = false,
    /// OLE 拖放自定义格式名（v0.1.12）
    drag_formats: []const []const u8 = &.{},

    /// 系统托盘（Windows）。启用后支持左键点击显示/隐藏窗口；
    /// ctx.notify 经 WinRT Toast 主通道发送（无需托盘），托盘气球仅作降级。
    tray: ?Tray = null,
    /// 点击关闭按钮时隐藏到托盘而非退出（需要 tray 启用）
    close_to_tray: bool = false,
    /// 单实例保护（第二实例以退出码 5 立即退出）
    single_instance: bool = false,
    /// 自动更新器（ed25519 验签）
    update: ?Update = null,
    /// 窗口/托盘默认图标（资产路径，如 "/app.ico"；null = 内置 Zig 官方图标）
    icon: ?[]const u8 = null,
    /// 深链接 / 文件关联（Windows；v0.1.6）
    deep_link: ?DeepLink = null,

    /// 原生菜单栏（叶子项触发 "menu" IPC 事件）
    menu: ?[]const MenuItem = null,
    /// 全局快捷键（触发 "hotkey" IPC 事件）
    hotkeys: ?[]const Hotkey = null,

    /// 应用服务（v0.1.16）：框架按注册顺序 init、逆序 deinit，
    /// 并把名称/作用域/状态暴露给 `window.zilt.services.*`。
    /// 服务的方法由应用自行持有（框架不解释 state），因此 JS 侧只能查询状态
    /// 与触发 start/stop，不能直接调用任意方法 —— 需要方法级桥接请用 commands。
    services: []const Service = &.{},

    pub const Dev = struct {
        /// dev 模式：从磁盘目录服务资产（支持热重载事件）
        dir: ?[]const u8 = null,
        /// dev 模式：直接导航到前端 dev server（如 Vite http://localhost:5173，HMR 由其承担）
        url: ?[]const u8 = null,
    };

    pub const Tray = struct {
        /// 托盘悬停提示
        tooltip: [:0]const u8 = "Zilt App",
        /// 托盘右键菜单（复用菜单树格式；null = 无右键菜单）
        menu: ?[]const MenuItem = null,
        /// 托盘图标（资产路径；null = 用 Config.icon（默认内置 Zig 图标））
        icon: ?[]const u8 = null,
        /// v0.3.3：托盘附着窗口（label；托盘左键点击切换该窗口显示/隐藏，
        ///     窗口建议同时 hide_on_focus_lost=true 以获得弹窗行为）
        attach_window: ?[]const u8 = null,
    };

    /// 深链接 / 文件关联（HKCU 注册，per-user 无需管理员）。
    pub const DeepLink = struct {
        /// URL 协议名（如 "zilt" → zilt://…）
        scheme: []const u8 = "zilt",
        /// 启动时注册协议处理器
        register: bool = false,
        /// 注册文件关联扩展名（如 ".zilt"）
        file_ext: ?[]const u8 = null,
    };

    /// 菜单项：label "-" 为分隔符；items 非空为子菜单；叶子需 id（emit 事件用）。
    pub const MenuItem = struct {
        label: []const u8,
        id: ?[]const u8 = null,
        items: ?[]const MenuItem = null,
        /// 加速键展示（v0.1.13）：`"Ctrl+N"`，菜单项右侧以 `\t` 对齐显示；
        /// v0.1.18 起同时参与 ACCEL 表，真正响应键盘。
        accel: ?[]const u8 = null,
        /// v0.1.18：预定义角色（undo/redo/cut/copy/paste/delete/select_all），
        /// 有 role 的项必须同时给 id（菜单 id 表按叶子顺序，缺 id 会错位）。
        role: ?[]const u8 = null,
        /// v0.1.18：菜单项左侧图标（.ico 路径，16×16 渲染）
        icon: ?[]const u8 = null,
    };

    /// 全局快捷键（key: "A"-"Z"/"0"-"9"/"F1"-"F12"，编译期校验）。
    pub const Hotkey = struct {
        id: []const u8,
        key: []const u8,
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        win: bool = false,
    };

    pub const Update = struct {
        /// 更新清单 URL（JSON：version/notes/pub_date/url/sha256/signature）
        manifest_url: []const u8,
        /// ed25519 公钥（64 个 hex 字符 = 32 字节），发布方私钥签名安装包
        public_key_hex: []const u8,
        /// 当前应用版本（用于比较）
        current_version: []const u8,
        /// 更新包内 exe 的文件名
        exe_name: []const u8 = "zilt-app.exe",
        /// 暂存成功后自动重启应用（v0.1.5；false = 应用收到 updateStaged 事件后自行调 ctx.restartToApply）
        auto_restart: bool = false,
        /// 订阅通道（v0.1.15）："stable" | "beta"。beta 同时接受 stable 清单。
        channel: []const u8 = "stable",
        /// v0.3.4：GitHub Releases provider——"owner/repo"。设置后 check 先请求
        /// `releases/latest` 并解析 `zilt-manifest.json` asset 作为清单 URL
        ///（manifest_url 仍作为回退/普通模式）。用户跳过的版本存 skipped.json。
        github_repo: ?[]const u8 = null,
    };
};
