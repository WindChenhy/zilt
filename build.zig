const std = @import("std");

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

    // 应用配置（命令/事件/资产）——主程序与 gen 工具共用
    const app_config_mod = b.createModule(.{
        .root_source_file = b.path("src/app_config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

    // 绑定生成：zig build gen → src/frontend/zilt-bindings.ts
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

    // 单元测试（ipc 协议/分发 + 绑定 codegen + 打包器）
    const unit_tests = b.addTest(.{ .root_module = zilt_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Phase 3: 打包 —— zig build bundle → dist/（便携 zip + NSIS 安装器）
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

    // 更新签名工具：keygen（生成密钥对）/ sign（签名安装包产出 manifest）
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
    sign.root_module.linkSystemLibrary("advapi32", .{}); // 无需，保守链接（win32 helper 依赖）
    b.installArtifact(sign);
}
