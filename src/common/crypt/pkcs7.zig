//! 自定义 PKCS7 —— 对应 Java `util/crypto/PKCS7Encoder`。
//!
//! 注意：这**不是**标准 PKCS7！微信的填充块大小是 32（而非 AES 的 16），
//! 填充作用在「random + len + msg + appid」整个明文包上，AES 本身 NoPadding。
//! 填充长度恒为 1..32（count % 32 == 0 时也补满 32）。
const std = @import("std");

pub const BLOCK_SIZE = 32;

/// 计算 `count` 长度数据需要的填充字节数（1..32）。
pub fn padLen(count: usize) usize {
    return BLOCK_SIZE - (count % BLOCK_SIZE);
}

/// 返回 `data` 补齐后的新切片（gpa 分配）；总长为 32 的倍数，也因此是 16 的倍数。
pub fn encode(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const pad = padLen(data.len);
    const out = try gpa.alloc(u8, data.len + pad);
    errdefer gpa.free(out);
    @memcpy(out[0..data.len], data);
    @memset(out[data.len..], @intCast(pad));
    return out;
}

/// 就地去掉尾部填充（对应 Java `decode`）。
/// pad 非法（∉[1,32] 或超过数据长度）时按 Java 行为当作 0 处理。
pub fn decode(data: []const u8) []const u8 {
    if (data.len == 0) return data;
    var pad: usize = data[data.len - 1];
    if (pad < 1 or pad > BLOCK_SIZE) pad = 0;
    if (pad > data.len) pad = 0;
    return data[0 .. data.len - pad];
}

test "pkcs7 encode/decode roundtrip" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 0, 1, 31, 32, 33, 63, 64, 100 }) |n| {
        const plain = try gpa.alloc(u8, n);
        defer gpa.free(plain);
        @memset(plain, 'x');
        const padded = try encode(gpa, plain);
        defer gpa.free(padded);
        try std.testing.expectEqual(@as(usize, 0), padded.len % BLOCK_SIZE);
        try std.testing.expect(padded.len > plain.len and padded.len - plain.len <= BLOCK_SIZE);
        try std.testing.expectEqualSlices(u8, plain, decode(padded));
    }
}
