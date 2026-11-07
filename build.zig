const std = @import("std");
const project = @import("src/project.zig");
const codegen = @import("src/tools/frontend_codegen.zig");

/// 应用 exe 图标（Windows PE 资源）：
/// project.icon 指定自定义 .ico（相对项目根）时生成临时 .rc；null = 内置 Zig 图标。
fn addAppIconResource(b: *std.Build, module: *std.Build.Module, icon_path: ?[]const u8) void {
    if (icon_path) |p| {
        const base = std.fs.path.basename(p);
        const dir = std.fs.path.dirname(p) orelse ".";
        const wf = b.addWriteFiles();
        const rc_text = std.fmt.allocPrint(b.allocator, "1 ICON \"{s}\"\n", .{base}) catch @panic("OOM");
        const rc = wf.add("zilt-app-icon.rc", rc_text);
        module.addWin32ResourceFile(.{ .file = rc, .include_paths = &.{b.path(dir)} });
    } else {
        module.addWin32ResourceFile(.{
            .file = b.path("src/zilt/assets/zilt.rc"),
            .include_paths = &.{b.path("src/zilt/assets")},
        });
    }
}

pub fn build(b: *std.Build) void {
    // 默认 windows-gnu：Zig 自带 MinGW 导入库，无 MSVC 的机器也能开箱构建。
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});

    // zilt 库模块
    const zilt_mod = b.addModule("zilt", .{
        .root_source_file = b.path("src/zilt/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- 前端资产 codegen：遍历 dist → 生成 zilt-assets 模块 ----
    // （eager 执行：每次 zig build 都重新枚举，排序保证生成内容稳定 → 缓存友好）
    const frontend = project.frontend;
    const dist = frontend.dist;
    // build runner 的 cwd 不保证是项目根——统一绝对路径（joinString）
    const dist_abs = b.root.joinString(b.allocator, dist) catch dist;
    const files = codegen.collectFiles(b.allocator, dist_abs, &codegen.default_excludes) catch blk: {
        std.log.warn("[zilt] 前端 dist 遍历失败：资产表为空——先运行 `zig build frontend`", .{});
        break :blk &[_][]const u8{};
    };

    // ---- configure 缓存毒性声明（0.17 poisonCache API）----
    // zig build 会缓存 build.zig 求值结果（配置缓存）；下方 Win32 遍历/读取/落盘
    // 对求值缓存不可见——若保持 pure，前端任何变更（改/增/删文件）都不会重跑求值
    // 期 → 资产永不更新（实测踩坑）。dependOn* 声明式依赖也覆盖不了本场景：
    // 依赖集只能在上次求值时确定——新增文件不在旧依赖集内（实测漏新增），
    // 目录依赖遇 dist 缺失/被前端工具删除则 configure 直接 FileSystemFailure
    // 且缓存校验先于重求值（实测永久陷阱）。故按官方语义显式 poison：
    // configure 每次重跑（本段逻辑毫秒级），step 级编译缓存不受影响——内容寻址
    // 目录保证哈希不变时模块源字节不变 → 编译缓存仍命中，不会无谓重链。
    b.graph.poisonCache();

    // ---- 内容寻址资产目录（v0.1.5 修复）----
    // 之前的 WriteFiles 方案有两个实测坑：(1) addCopyFile 引用 dist 源文件，前端哈希
    // 改名后陈旧 manifest 因旧文件缺失直接构建失败；(2) 内联字节的 manifest 不跟踪
    // **同名文件内容变更**——原地编辑 app.js 后 zig build 命中缓存，exe 嵌入旧资产。
    // 改为：聚合内容哈希作目录名，把 assets.zig + payload/ 写成**真实文件**，模块
    // 直接指向该目录——内容变 → 目录名变 → 模块源必变 → 必然重编；旧目录保留，
    // 陈旧缓存引用永远安全。
    const assets_root = ".zilt-cache-assets";
    {
        var h = std.hash.Wyhash.init(0);
        for (files) |rel| {
            h.update(rel);
            const abs = codegen.fsJoin(b.allocator, dist_abs, rel) catch unreachable;
            defer b.allocator.free(abs);
            if (codegen.readFileAlloc(b.allocator, abs)) |bytes| {
                h.update(bytes);
                b.allocator.free(bytes);
            }
        }
        // 哈希里混入生成器版本（gz 策略/表格式变化时也换目录）
        h.update("zilt-assets-v3");
        const dir_hash = h.final();
        codegen.payload_dir_buf = std.fmt.allocPrint(b.allocator, "{s}/{x:0>8}", .{ assets_root, dir_hash }) catch @panic("OOM");
    }
    const payload_dir = codegen.payload_dir_buf.?;
    const payload_dir_abs = b.root.joinString(b.allocator, payload_dir) catch payload_dir;
    codegen.ensureDirDeep(b.allocator, payload_dir_abs) catch @panic("assets dir create failed");

    // ---- 资产预压缩（Phase C）：>8KB 且 gzip 收益 ≥10% 的文件只嵌 .gz ----
    const gz_flags = b.allocator.alloc(bool, files.len) catch @panic("OOM");
    for (files, 0..) |rel, i| {
        gz_flags[i] = false;
        const abs = codegen.fsJoin(b.allocator, dist_abs, rel) catch unreachable;
        defer b.allocator.free(abs);
        const bytes = codegen.readFileAlloc(b.allocator, abs) orelse continue;
        defer b.allocator.free(bytes);
        if (bytes.len <= codegen.gzip_min_size) continue;
        const gz = codegen.gzipCompress(b.allocator, bytes) catch continue;
        defer b.allocator.free(gz);
        if (!codegen.gzipWorthwhile(bytes.len, gz.len)) continue;
        gz_flags[i] = true;
        const gz_dst = std.fmt.allocPrint(b.allocator, "{s}/payload/{s}.gz", .{ payload_dir_abs, rel }) catch unreachable;
        defer b.allocator.free(gz_dst);
        codegen.ensureDirDeep(b.allocator, std.fs.path.dirname(gz_dst) orelse ".") catch @panic("mkdir failed");
        if (!codegen.writeFilePayload(b.allocator, gz_dst, gz)) @panic("payload gz write failed");
    }
    const generated = codegen.generateAssetsZig(b.allocator, files, gz_flags) catch @panic("assets codegen OOM");
    const assets_zig_path = std.fmt.allocPrint(b.allocator, "{s}/assets.zig", .{payload_dir_abs}) catch unreachable;
    if (!codegen.writeFilePayload(b.allocator, assets_zig_path, generated)) @panic("assets.zig write failed");
    for (files) |rel| {
        const fs_rel = codegen.fsJoin(b.allocator, dist_abs, rel) catch unreachable;
        defer b.allocator.free(fs_rel);
        const bytes = codegen.readFileAlloc(b.allocator, fs_rel) orelse @panic("payload read failed");
        defer b.allocator.free(bytes);
        const payload_dst = std.fmt.allocPrint(b.allocator, "{s}/payload/{s}", .{ payload_dir_abs, rel }) catch unreachable;
        defer b.allocator.free(payload_dst);
        codegen.ensureDirDeep(b.allocator, std.fs.path.dirname(payload_dst) orelse ".") catch @panic("mkdir failed");
        if (!codegen.writeFilePayload(b.allocator, payload_dst, bytes)) @panic("payload write failed");
    }
    const assets_mod = b.createModule(.{
        .root_source_file = b.path(codegen.fsJoinRel(b.allocator, payload_dir, "assets.zig") catch unreachable),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
        },
    });
    // 注：资产在构建图求值期已生成（内容寻址、幂等），不再需要手动 assets step

    // 应用配置（命令/事件/资产）——主程序与 gen 工具共用
    const app_config_mod = b.createModule(.{
        .root_source_file = b.path("src/app_config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "zilt_assets", .module = assets_mod },
        },
    });

    // 示例应用
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_config", .module = app_config_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zilt-app",
        .root_module = exe_mod,
    });
    // GUI 子系统：双击/安装后运行不弹出控制台窗口（日志仍写 zilt.log）
    exe.subsystem = .windows;

    // Windows 系统库（Win32 extern 声明所需的导入库）
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("ole32", .{});
    exe_mod.linkSystemLibrary("advapi32", .{});
    exe_mod.linkSystemLibrary("comdlg32", .{});
    exe_mod.linkSystemLibrary("shell32", .{});
    addAppIconResource(b, exe_mod, project.icon);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

    // ---- 前端构建（build_command；vanilla 无构建步骤 → no-op） ----
    const frontend_step = b.step("frontend", "Build the frontend (project.frontend.build_command)");
    if (frontend.build_command) |cmd| {
        const fr = b.addSystemCommand(&.{ "cmd", "/C", cmd });
        fr.setCwd(b.path(frontend.dir));
        frontend_step.dependOn(&fr.step);
    } else {
        // 无构建命令（vanilla）：资产在构建图求值期已生成，无需动作
    }

    // ---- TS 绑定生成 → frontend/bindings/zilt.ts ----
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/gen_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_config", .module = app_config_mod },
        },
    });
    const gen_exe = b.addExecutable(.{
        .name = "zilt-gen-bindings",
        .root_module = gen_mod,
    });
    const gen_run = b.addRunArtifact(gen_exe);
    const gen_step = b.step("gen", "Generate frontend TS bindings");
    gen_step.dependOn(&gen_run.step);

    // ---- capability 清单（v0.1.11）：构建时由编译期 security 配置生成 ----
    const cap_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/gen_capabilities.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_config", .module = app_config_mod },
        },
    });
    const cap_exe = b.addExecutable(.{ .name = "zilt-gen-capabilities", .root_module = cap_mod });
    const cap_run = b.addRunArtifact(cap_exe);
    const cap_step = b.step("capabilities", "Generate the runtime capability manifest");
    cap_step.dependOn(&cap_run.step);
    gen_step.dependOn(&cap_run.step);
    b.getInstallStep().dependOn(&cap_run.step);

    // ---- dev：spawn dev 命令 → TCP 等待 → 应用直连 devUrl（HMR） ----
    const dev_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/dev.zig"),
        .target = target,
        .optimize = optimize,
    });
    dev_mod.linkSystemLibrary("ws2_32", .{});
    dev_mod.linkSystemLibrary("shell32", .{});
    const dev_exe = b.addExecutable(.{
        .name = "zilt-dev",
        .root_module = dev_mod,
    });
    const dev_run = b.addRunArtifact(dev_exe);
    dev_run.addArtifactArg(exe);
    dev_run.addArg(frontend.dev_command orelse "-");
    dev_run.addArg(frontend.dev_url orelse "-");
    dev_run.addArg(std.fmt.allocPrint(b.allocator, "{d}", .{frontend.wait_timeout_secs}) catch "90");
    dev_run.addArg(frontend.dir);
    dev_run.addArg(if (frontend.dev_proxy) "1" else "-"); // 反代模式标志（Phase C）

    dev_run.step.dependOn(&gen_run.step);
    dev_run.step.dependOn(b.getInstallStep());
    const dev_step = b.step("dev", "Run frontend dev server + app (HMR)");
    dev_step.dependOn(&dev_run.step);

    // ---- 单元测试（框架 + 工具） ----
    const unit_tests = b.addTest(.{ .root_module = zilt_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const tools_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/tests.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_config", .module = app_config_mod },
        },
    });
    const tools_tests = b.addTest(.{ .root_module = tools_test_mod });
    const run_tools_tests = b.addRunArtifact(tools_tests);
    test_step.dependOn(&run_tools_tests.step);

    // ---- 打包器（exe → dist/ 便携 zip + NSIS 安装器） ----
    const app_meta_mod = b.createModule(.{
        .root_source_file = b.path("src/app_meta.zig"),
    });

    const rel_app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe, // 分发产物用 Release
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_config", .module = app_config_mod },
        },
    });
    const rel_app = b.addExecutable(.{
        .name = "zilt-app",
        .root_module = rel_app_mod,
    });
    rel_app.subsystem = .windows; // 分发产物无控制台窗口
    rel_app_mod.linkSystemLibrary("user32", .{});
    rel_app_mod.linkSystemLibrary("gdi32", .{});
    rel_app_mod.linkSystemLibrary("ole32", .{});
    rel_app_mod.linkSystemLibrary("advapi32", .{});
    rel_app_mod.linkSystemLibrary("comdlg32", .{});
    rel_app_mod.linkSystemLibrary("shell32", .{});
    addAppIconResource(b, rel_app_mod, project.icon);

    const bundle_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bundle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_meta", .module = app_meta_mod },
        },
    });
    bundle_mod.linkSystemLibrary("shell32", .{}); // CommandLineToArgvW
    const bundle_exe = b.addExecutable(.{
        .name = "zilt-bundle",
        .root_module = bundle_mod,
    });
    const bundle_run = b.addRunArtifact(bundle_exe);
    bundle_run.addArtifactArg(rel_app); // argv[1] = Release exe 路径
    const bundle_step = b.step("bundle", "Package distributables into dist/");
    bundle_step.dependOn(&bundle_run.step);

    // ---- 更新签名工具：keygen / sign ----
    const keygen = b.addExecutable(.{
        .name = "zilt-keygen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gen_keys.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    keygen.root_module.linkSystemLibrary("bcrypt", .{});
    b.installArtifact(keygen);

    const sign = b.addExecutable(.{
        .name = "zilt-sign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sign_update.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(sign);

    // ---- 差分包生成（zilt-patch v1）----
    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/diff_patch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
        },
    });
    const diff_exe = b.addExecutable(.{ .name = "zilt-diff", .root_module = diff_mod });
    b.installArtifact(diff_exe);

    // ---- 跨平台打包编排（msi/macos/appimage/deb/rpm/sign）----
    const pack_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/pack.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
            .{ .name = "app_meta", .module = app_meta_mod },
        },
    });
    const pack_exe = b.addExecutable(.{ .name = "zilt-pack", .root_module = pack_mod });
    b.installArtifact(pack_exe);
    const pack_run = b.addRunArtifact(pack_exe);
    pack_run.addArtifactArg(rel_app); // argv[1] = Release exe
    const pack_step = b.step("pack", "Cross-platform packaging (ZILT_PACK_TARGET=msi|macos|appimage|deb|rpm|sign)");
    pack_step.dependOn(&pack_run.step);

    // ---- init：项目模板创建 ----
    const init_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    init_mod.linkSystemLibrary("shell32", .{});
    init_mod.linkSystemLibrary("bcrypt", .{});
    const init_exe = b.addExecutable(.{
        .name = "zilt-init",
        .root_module = init_mod,
    });
    const init_run = b.addRunArtifact(init_exe);
    const init_step = b.step("init", "Create a new project from a template (ZILT_INIT_TEMPLATE=vue ZILT_INIT_NAME=myapp zig build init)");
    init_step.dependOn(&init_run.step);
}
