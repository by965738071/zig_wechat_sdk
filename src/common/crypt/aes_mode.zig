//! AES 分组模式的补齐 —— std.crypto 在 0.18-dev 只提供分组密码（Aes128/Aes256）与
//! GCM/SIV 等 AEAD，**没有 CBC / ECB 模式**；而微信两处核心协议都要用到：
//! - `WxCryptUtil`：AES-256-CBC(NoPadding) + 自定义 PKCS7(block=32)（公众号/企业号安全模式消息）；
//! - 小程序数据解密：AES-128-CBC(NoPadding) + 手动去 PKCS7（session_key/iv）；
//! - 微信支付退款通知 req_info：AES-256-ECB(PKCS5Padding)（密钥 = md5(mchKey) 小写）。
//!
//! 因此这里在 std 分组密码之上手写这三个模式。输入输出均为分组对齐数据，
//! 填充策略由调用方（pkcs7.zig）负责。
const std = @import("std");

pub const block_size = 16;

pub const Error = error{ BadBlockSize, BadKeySize };

/// CBC 加密（NoPadding 语义：src.len 必须为 16 的倍数；dst.len == src.len）。
/// Ctx 为 `Aes128.EncryptCtx` / `Aes256.EncryptCtx`（由 initEnc 返回）。
pub fn cbcEncrypt(ctx: anytype, dst: []u8, src: []const u8, iv: *const [block_size]u8) !void {
    if (src.len % block_size != 0 or dst.len != src.len) return error.BadBlockSize;
    var prev: [block_size]u8 = iv.*;
    var i: usize = 0;
    while (i < src.len) : (i += block_size) {
        var block: [block_size]u8 = undefined;
        for (0..block_size) |j| block[j] = src[i + j] ^ prev[j];
        var out: [block_size]u8 = undefined;
        ctx.encrypt(&out, &block); // 分组密码要求编译期定长数组指针
        @memcpy(dst[i..][0..block_size], &out);
        prev = out;
    }
}

/// CBC 解密（NoPadding 语义）。
pub fn cbcDecrypt(ctx: anytype, dst: []u8, src: []const u8, iv: *const [block_size]u8) !void {
    if (src.len % block_size != 0 or dst.len != src.len) return error.BadBlockSize;
    var prev: [block_size]u8 = iv.*;
    var i: usize = 0;
    while (i < src.len) : (i += block_size) {
        var in: [block_size]u8 = undefined;
        @memcpy(&in, src[i..][0..block_size]);
        var out: [block_size]u8 = undefined;
        ctx.decrypt(&out, &in);
        for (0..block_size) |j| dst[i + j] = out[j] ^ prev[j];
        prev = in;
    }
}

/// ECB 单块解密（退款通知用）。
pub fn ecbDecryptBlock(ctx: anytype, dst: *[block_size]u8, src: *const [block_size]u8) void {
    ctx.decrypt(dst[0..], src[0..]);
}

/// ECB 解密并去 PKCS5/PKCS7 填充（Java `AES/ECB/PKCS5Padding` 等价物）。
pub fn ecbDecryptPkcs7(ctx: anytype, dst: []u8, src: []const u8) ![]const u8 {
    if (src.len == 0 or src.len % block_size != 0 or dst.len < src.len) return error.BadBlockSize;
    var i: usize = 0;
    while (i < src.len) : (i += block_size) {
        var in: [block_size]u8 = undefined;
        @memcpy(&in, src[i..][0..block_size]);
        var out: [block_size]u8 = undefined;
        ecbDecryptBlock(ctx, &out, &in);
        @memcpy(dst[i..][0..block_size], &out);
    }
    const plain_pad = dst[src.len - 1];
    if (plain_pad == 0 or plain_pad > block_size) return dst[0..src.len];
    return dst[0 .. src.len - plain_pad];
}

// ---------------------------------------------------------------------------

fn key16() [16]u8 {
    var k: [16]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    return k;
}

test "cbc matches openssl NIST vector (AES-128-CBC)" {
    const Aes128 = std.crypto.core.aes.Aes128;
    const key = key16();
    const iv = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff };
    const plain = "hello wechat!!!x"; // 16 bytes
    var enc: [16]u8 = undefined;
    var dec: [16]u8 = undefined;

    var ectx = Aes128.initEnc(key);
    var dctx = Aes128.initDec(key);
    try cbcEncrypt(&ectx, &enc, plain, &iv);
    try cbcDecrypt(&dctx, &dec, &enc, &iv);
    try std.testing.expectEqualStrings(plain, &dec);

    // 单块 ECB == CBC 首块
    var expected_first: [16]u8 = undefined;
    for (0..16) |j| expected_first[j] = plain[j] ^ iv[j];
    var tmp: [16]u8 = undefined;
    ectx.encrypt(&tmp, &expected_first);
    try std.testing.expectEqualSlices(u8, &tmp, &enc);
}

test "aes256 cbc roundtrip multi block" {
    const Aes256 = std.crypto.core.aes.Aes256;
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i * 7);
    const iv: [16]u8 = @splat(1); // [_]u8{1} ** 16;
    const plain = "0123456789abcdef0123456789abcdef0123456789abcdef"; // 48 bytes
    var enc: [plain.len]u8 = undefined;
    var dec: [plain.len]u8 = undefined;
    var ectx = Aes256.initEnc(key);
    var dctx = Aes256.initDec(key);
    try cbcEncrypt(&ectx, &enc, plain, &iv);
    try cbcDecrypt(&dctx, &dec, &enc, &iv);
    try std.testing.expectEqualStrings(plain, &dec);
}
