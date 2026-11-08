//! 应用配置。

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
    /// 主窗口状态持久化键（null = 不持久化；与 persist_window_state 配合按窗口 label 保存）
    state_key: ?[]const u8 = null,
    /// 所有窗口按 label 持久化位置/尺寸/最大化/全屏（v0.1.8）
    persist_window_state: bool = false,
    /// 迁移旧的 %TEMP%\zilt-app-webview2 共享数据目录（v0.1.8）
    migrate_legacy_profile: bool = false,
    /// 监听系统剪贴板变化并发 clipboardChanged 事件（v0.1.12）
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
        /// 加速键展示（v0.1.13）：`"Ctrl+N"`，菜单项右侧以 `\t` 对齐显示
        accel: ?[]const u8 = null,
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
    };
};
