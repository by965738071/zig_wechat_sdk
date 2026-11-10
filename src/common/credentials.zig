//! 凭证注入接缝 —— 对应 Java 侧从 `WxPayConfig` / 配置文件 / 环境变量加载商户凭据。
//!
//! 提供最小、安全的「来源 → 字节」读取:文件路径 / 环境变量 / 直接文本。
//! 安全约束(硬约束,勿放宽):
//!  - 返回值由 gpa 拥有,调用方负责 `free`;
//!  - 错误信息只暴露「来源标识」(路径/变量名),**绝不回显密钥材料**;
//!  - SDK 不内嵌任何真实凭证(离线测试一律用内嵌测试密钥对)。
//!
//! 工具链核对(Zig 0.18.0-dev.954+60635c2bd):旧版 `std.process.getEnvVarOwned`
//! 已移除,`std.fs.Dir.readFileAlloc` 迁到 `std.Io.Dir.readFileAlloc`;环境变量
//! 改由 `std.process.Environ` 提供(生产 = 调用方 `Io.Threaded.environ`,
//! 离线测试 = `Environ.Map.createPosixBlock` 构造,不依赖真实进程环境)。
const std = @import("std");

/// 凭证来源。各变体携带的是「来源标识」(路径/变量名/文本),本身不是秘密,
/// 可以安全地出现在日志与错误信息里。
pub const Source = union(enum) {
    /// 直接文本(上层已加载 / 离线测试)。值本身即材料。
    text: []const u8,
    /// 文件路径:走 `std.Io.Dir.cwd().readFileAlloc` 读取。
    file: []const u8,
    /// 环境变量名:由 `environ` 查表。生产 environ 由调用方注入
    /// (`Io.Threaded.environ`),离线测试由 `Environ.Map.createPosixBlock` 构造。
    env: struct { name: []const u8, environ: std.process.Environ },

    /// 供错误信息使用的来源标识(绝不含材料本身)。
    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .text => "inline text",
            .file => |p| p,
            .env => |e| e.name,
        };
    }
};

/// 单个凭证文件读取上限(64 KiB),覆盖 PEM/私钥/证书文本;超限报 `StreamTooLong`。
pub const max_credential_bytes: usize = 64 * 1024;

/// 从来源读出凭证字节(gpa 拥有,调用方 free)。
/// `io` 供文件读取;`env` 变体用自带 `environ`,不碰进程全局状态。
pub fn read(gpa: std.mem.Allocator, io: std.Io, src: Source) ![]u8 {
    return switch (src) {
        .text => |t| try gpa.dupe(u8, t),
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_credential_bytes)),
        .env => |e| try e.environ.getAlloc(gpa, e.name),
    };
}

// ---------------------------------------------------------------------------
// 离线单测:三种来源 + 缺变量。只用内嵌测试材料,不触碰网络/真实凭证。
// ---------------------------------------------------------------------------

const TEST_PEM_TEXT = "-----BEGIN PRIVATE KEY-----\nTESTKEYMATERIAL\n-----END PRIVATE KEY-----\n";

test "Source.label never leaks key material" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("inline text", (Source{ .text = TEST_PEM_TEXT }).label());
    try std.testing.expectEqualStrings("/path/to/key.pem", (Source{ .file = "/path/to/key.pem" }).label());
    // label 只回显变量名/路径,即便 text 里是真实材料也不进 label。
    const inline_src = Source{ .text = TEST_PEM_TEXT };
    try std.testing.expect(std.mem.indexOf(u8, inline_src.label(), "TESTKEYMATERIAL") == null);
    _ = gpa;
}

test "read(text) returns owned dupe" {
    const gpa = std.testing.allocator;
    const got = try read(gpa, undefined, .{ .text = TEST_PEM_TEXT });
    defer gpa.free(got);
    try std.testing.expectEqualStrings(TEST_PEM_TEXT, got);
    // 是独立副本:与输入不共享内存
    try std.testing.expect(got.ptr != TEST_PEM_TEXT.ptr);
}

test "read(env) from constructed Environ; missing -> EnvironmentVariableMissing" {
    const gpa = std.testing.allocator;
    var map = std.process.Environ.Map.init(gpa);
    defer map.deinit();
    try map.put("WX_TEST_PRIV_PEM", TEST_PEM_TEXT);
    try map.put("WX_TEST_EMPTY", "");
    const environ = std.process.Environ{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    {
        const got = try read(gpa, undefined, .{ .env = .{ .name = "WX_TEST_PRIV_PEM", .environ = environ } });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(TEST_PEM_TEXT, got);
    }
    {
        const got = try read(gpa, undefined, .{ .env = .{ .name = "WX_TEST_EMPTY", .environ = environ } });
        defer gpa.free(got);
        try std.testing.expectEqualStrings("", got);
    }
    // 缺变量:报 EnvironmentVariableMissing,不回显任何材料
    try std.testing.expectError(error.EnvironmentVariableMissing, read(gpa, undefined, .{ .env = .{ .name = "WX_TEST_MISSING", .environ = environ } }));
}

test "read(file) reads PEM bytes from a temp file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "/tmp/zig_wechat_sdk_credential_test.pem";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = path, .data = TEST_PEM_TEXT });
    defer cwd.deleteFile(io, path) catch {};

    const got = try read(gpa, io, .{ .file = path });
    defer gpa.free(got);
    try std.testing.expectEqualStrings(TEST_PEM_TEXT, got);
}
