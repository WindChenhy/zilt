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
    dev: Dev = .{},

    pub const Dev = struct {
        /// dev 模式：从磁盘目录服务资产（支持热重载事件）
        dir: ?[]const u8 = null,
        /// dev 模式：直接导航到前端 dev server（如 Vite http://localhost:5173，HMR 由其承担）
        url: ?[]const u8 = null,
    };
};
