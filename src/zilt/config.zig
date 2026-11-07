//! 应用配置。

pub const Asset = struct {
    /// URL 路径（如 "/index.html"、"/"）
    path: []const u8,
    /// 文件内容（通常来自 @embedFile）
    content: []const u8,
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

    /// 应用 URL（embedded 模式）；约定 origin 由它推导（如 https://zilt.app）
    url: []const u8 = "https://zilt.app/index.html",
    /// origin 校验允许列表（默认从 url 推导；dev.url 模式自动加入对应 origin）
    origin: ?[]const u8 = null,
    /// 应用 ID（单实例互斥体名等）
    app_id: []const u8 = "app.zilt",
    dev: Dev = .{},

    /// 系统托盘（Windows）。启用后支持 ctx.notify 与左键点击显示/隐藏窗口。
    tray: ?Tray = null,
    /// 点击关闭按钮时隐藏到托盘而非退出（需要 tray 启用）
    close_to_tray: bool = false,
    /// 单实例保护（第二实例以退出码 5 立即退出）
    single_instance: bool = false,
    /// 自动更新器（ed25519 验签）
    update: ?Update = null,

    pub const Dev = struct {
        /// dev 模式：从磁盘目录服务资产（支持热重载事件）
        dir: ?[]const u8 = null,
        /// dev 模式：直接导航到前端 dev server（如 Vite http://localhost:5173，HMR 由其承担）
        url: ?[]const u8 = null,
    };

    pub const Tray = struct {
        /// 托盘悬停提示
        tooltip: [:0]const u8 = "Zilt App",
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
    };
};
