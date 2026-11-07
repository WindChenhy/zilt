const std = @import("std");
const project = @import("src/project.zig");
const codegen = @import("src/tools/frontend_codegen.zig");

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
    const wf = b.addWriteFiles();
    const files = codegen.collectFiles(b.allocator, dist_abs, &codegen.default_excludes) catch blk: {
        std.log.warn("[zilt] 前端 dist 遍历失败：资产表为空——先运行 `zig build frontend`", .{});
        break :blk &[_][]const u8{};
    };
    // ---- 资产预压缩（Phase C）：>8KB 且 gzip 收益 ≥10% 的文件附带 .gz 变体 ----
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
        const gz_rel = std.fmt.allocPrint(b.allocator, "zilt-assets/payload/{s}.gz", .{rel}) catch unreachable;
        defer b.allocator.free(gz_rel);
        _ = wf.add(gz_rel, gz);
    }
    const generated = codegen.generateAssetsZig(b.allocator, files, gz_flags) catch @panic("assets codegen OOM");
    _ = wf.add("zilt-assets/assets.zig", generated);
    // payload 一律读入内存后 wf.add（内联字节进 manifest）——不用 addCopyFile 引用
    // dist 源文件：前端重新构建会更换哈希文件名，addCopyFile 的陈旧 manifest 会因
    // 旧文件不存在而使 zig build 直接失败（实测踩坑）。
    for (files) |rel| {
        const fs_rel = codegen.fsJoin(b.allocator, dist_abs, rel) catch unreachable;
        defer b.allocator.free(fs_rel);
        const bytes = codegen.readFileAlloc(b.allocator, fs_rel) orelse @panic("payload read failed");
        defer b.allocator.free(bytes);
        const payload_rel = codegen.fsJoin(b.allocator, "zilt-assets/payload", rel) catch unreachable;
        defer b.allocator.free(payload_rel);
        _ = wf.add(payload_rel, bytes);
    }
    const assets_mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "zilt-assets/assets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
        },
    });
    const assets_step = b.step("assets", "Regenerate embedded assets table");
    assets_step.dependOn(&wf.step);

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

    // Windows 系统库（Win32 extern 声明所需的导入库）
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("ole32", .{});
    exe_mod.linkSystemLibrary("advapi32", .{});
    exe_mod.linkSystemLibrary("comdlg32", .{});

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
        frontend_step.dependOn(assets_step);
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
    rel_app_mod.linkSystemLibrary("user32", .{});
    rel_app_mod.linkSystemLibrary("gdi32", .{});
    rel_app_mod.linkSystemLibrary("ole32", .{});
    rel_app_mod.linkSystemLibrary("advapi32", .{});
    rel_app_mod.linkSystemLibrary("comdlg32", .{});

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
