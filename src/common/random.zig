//! 随机串 —— 对应 Java `util/RandomUtils`（16 字符 `[a-zA-Z0-9]`）。
//! Java 用 `java.util.Random`（非 CSPRNG）；Zig 端直接用 `std.Io.randomSecure`，
//! 既满足微信要求又更安全。
const std = @import("std");

pub const ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// 写入 `buf` 长度的随机字母数字串（对应 `RandomUtils.getRandomStr()`）。
pub fn randomStr(io: std.Io, buf: []u8) !void {
    var tmp: [64]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) {
        const n = @min(buf.len - i, tmp.len);
        try std.Io.randomSecure(io, tmp[0..n]);
        for (tmp[0..n]) |b| {
            buf[i] = ALPHABET[b % ALPHABET.len];
            i += 1;
        }
    }
}

/// 分配 16 字符随机串（与 Java 默认长度一致）。
pub fn randomStr16(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const buf = try allocator.alloc(u8, 16);
    errdefer allocator.free(buf);
    try randomStr(io, buf);
    return buf;
}

test "randomStr charset and length" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var buf: [16]u8 = undefined;
    try randomStr(threaded.io(), &buf);
    for (buf) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, ALPHABET, c) != null);
    }
}
