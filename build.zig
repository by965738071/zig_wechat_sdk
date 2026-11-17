//! 按 Java 工程的多模块结构（weixin-java-common / mp / miniapp / open / pay）
//! 把 src/ 下的每个业务目录声明为独立的 Zig 模块，模块间依赖关系：
//!
//!   common ← wechat_mp ← { wechat_miniapp, wechat_open, wechat_pay }
//!   以上全部 ← zig_wechat_sdk（聚合入口 src/root.zig）← main.zig(exe)
//!
//! 每个模块拥有独立的测试步骤：
//!   zig build test-common | test-mp | test-miniapp | test-open | test-pay
//!   zig build test          # 全部模块 + exe 的测试
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // RSA-PKCS1v15-SHA256（微信支付 V3 签名），vendored 于 vendor/zig-rsa。
    const zig_rsa = b.dependency("zig-rsa", .{
        .target = target,
        .optimize = optimize,
    }).module("zig-rsa");

    // ---- 模块声明（依赖图与 Java 工程一致）----
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
    });
    const mp = b.addModule("wechat_mp", .{
        .root_source_file = b.path("src/wechat_mp/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "common", .module = common }},
    });
    // mp 子服务拆成 a/b 两组聚合文件（services/root_a|root_b.zig），
    // 同属 wechat_mp 模块，并行开发时按文件分工互不干扰。
    const miniapp = b.addModule("wechat_miniapp", .{
        .root_source_file = b.path("src/wechat_miniapp/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common },
            .{ .name = "wechat_mp", .module = mp },
            // 服务端 API 签名(RSA-PSS-SHA256,同城配送/手机号等加密通道),
            // 与 pay 的 V3 签名共用 vendored zig-rsa。
            .{ .name = "zig-rsa", .module = zig_rsa },
        },
    });
    const open = b.addModule("wechat_open", .{
        .root_source_file = b.path("src/wechat_open/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common },
            .{ .name = "wechat_mp", .module = mp },
        },
    });
    const pay = b.addModule("wechat_pay", .{
        .root_source_file = b.path("src/wechat_pay/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common },
            .{ .name = "wechat_mp", .module = mp },
            .{ .name = "zig-rsa", .module = zig_rsa },
        },
    });
    const sdk = b.addModule("zig_wechat_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common },
            .{ .name = "wechat_mp", .module = mp },
            .{ .name = "wechat_miniapp", .module = miniapp },
            .{ .name = "wechat_open", .module = open },
            .{ .name = "wechat_pay", .module = pay },
        },
    });

    // ---- 可执行文件（脚手架示例，保留）----
    const exe = b.addExecutable(.{
        .name = "zig_wechat_sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_wechat_sdk", .module = sdk },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // ---- 每模块独立测试步骤 ----
    const test_step = b.step("test", "Run all module tests");

    const modules = [_]struct { step: []const u8, desc: []const u8, mod: *std.Build.Module }{
        .{ .step = "test-common", .desc = "Run common tests", .mod = common },
        .{ .step = "test-mp", .desc = "Run wechat_mp tests", .mod = mp },
        .{ .step = "test-miniapp", .desc = "Run wechat_miniapp tests", .mod = miniapp },
        .{ .step = "test-open", .desc = "Run wechat_open tests", .mod = open },
        .{ .step = "test-pay", .desc = "Run wechat_pay tests", .mod = pay },
        .{ .step = "test-sdk", .desc = "Run aggregate module tests", .mod = sdk },
    };
    for (modules) |m| {
        const step = b.step(m.step, m.desc);
        const t = b.addTest(.{ .root_module = m.mod });
        step.dependOn(&b.addRunArtifact(t).step);
        // 顶层 test 汇总所有模块测试
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // exe 自身的 test 块
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
