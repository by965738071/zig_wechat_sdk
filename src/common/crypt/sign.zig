//! 通用签名小工具 —— 对应 Java `util/SignUtils`（及 pay 模块 V2 签名的底座）。
//!
//! - `createHmacSha256Sign`：HmacSHA256 → hex **大写**（公众号 JS 签名等场景）；
//! - `md5HexUpper/Lower`：V2 支付签名的 MD5 路径；
//! - `hmacSha256HexUpper`：V2 支付签名的 HMAC 路径。
const std = @import("std");

// 0.18-dev：路径 std.crypto.auth.hmac.sha2.HmacSha256（顶层只有 HmacMd5/HmacSha1）
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// 对应 `SignUtils.createHmacSha256Sign(message, key)`（hex 大写）。
pub fn hmacSha256HexUpper(gpa: std.mem.Allocator, message: []const u8, key: []const u8) ![]u8 {
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, message, key);
    const hx = std.fmt.bytesToHex(mac, .upper);
    return gpa.dupe(u8, &hx);
}

/// MD5 → hex 大写（V2 签名默认）。
pub fn md5HexUpper(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const hx = std.fmt.bytesToHex(digest, .upper);
    return gpa.dupe(u8, &hx);
}

/// MD5 → hex 小写（退款通知 req_info 的派生密钥用）。
pub fn md5HexLower(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const hx = std.fmt.bytesToHex(digest, .lower);
    return gpa.dupe(u8, &hx);
}

test "sign utils match known vectors" {
    const gpa = std.testing.allocator;
    // RFC 4231 test case 2: key="Jefe", data="what do ya want for nothing?"
    const h = try hmacSha256HexUpper(gpa, "what do ya want for nothing?", "Jefe");
    defer gpa.free(h);
    try std.testing.expectEqualStrings(
        "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843",
        h,
    );
    // md5("") = d41d8cd98f00b204e9800998ecf8427e
    const m = try md5HexLower(gpa, "");
    defer gpa.free(m);
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", m);
}
