//! SHA-1 签名 —— 对应 Java `util/crypto/SHA1`。
//!
//! 微信回调验签方案：把 {token, timestamp, nonce, encrypt} 四个串按**字典序排序**
//! 后直接拼接（无分隔符），做 SHA-1 取小写 hex。
//! 另有 `genWithAmple`（"&" 连接）供个别接口使用。
const std = @import("std");

/// 40 字符小写 hex 的 SHA-1（无分配）。
pub fn hex(out: *[40]u8, data: []const u8) *const [40]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    const hexed = std.fmt.bytesToHex(&digest, .lower);
    out.* = hexed;
    return out;
}

/// 对应 `SHA1.gen(String...)`：字典序排序 → 拼接 → SHA-1 小写 hex（gpa 分配）。
pub fn gen(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return genJoin(gpa, parts, "");
}

/// 对应 `SHA1.genWithAmple`：字典序排序 → "&" 连接 → SHA-1。
pub fn genWithAmple(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return genJoin(gpa, parts, "&");
}

fn genJoin(gpa: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    const sorted = try gpa.dupe([]const u8, parts);
    defer gpa.free(sorted);
    // 0.18-dev 无 std.sort.memSort；签名串最多 4 个元素，插入排序足够
    std.sort.insertion([]const u8, sorted, {}, orderLess);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (sorted, 0..) |p, i| {
        if (i > 0) try joined.appendSlice(gpa, sep);
        try joined.appendSlice(gpa, p);
    }
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined.items, &digest, .{});
    const hx = std.fmt.bytesToHex(digest, .lower); // 无 fmtSliceHexLower，改用定长数组转 hex
    return gpa.dupe(u8, &hx);
}

fn orderLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// 验签：对应 `checkSignature(timestamp, nonce, signature)`（不加密消息路径，
/// 参与签名的只有 token/timestamp/nonce 三个串）。
pub fn checkSignature(gpa: std.mem.Allocator, token: []const u8, timestamp: []const u8, nonce: []const u8, signature: []const u8) !bool {
    const expect = try gen(gpa, &.{ token, timestamp, nonce });
    defer gpa.free(expect);
    return std.mem.eql(u8, expect, signature);
}

/// 验签（加密消息路径）：token/timestamp/nonce/encrypt 四串。
pub fn checkSignatureEncrypted(
    gpa: std.mem.Allocator,
    token: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    encrypt: []const u8,
    signature: []const u8,
) !bool {
    const expect = try gen(gpa, &.{ token, timestamp, nonce, encrypt });
    defer gpa.free(expect);
    return std.mem.eql(u8, expect, signature);
}

test "sha1 gen is sorted concatenation" {
    const gpa = std.testing.allocator;
    // 与 Java SHA1.gen("b","a") 一致：排序后 "ab" 的 sha1
    const s = try gen(gpa, &.{ "b", "a" });
    defer gpa.free(s);
    var buf: [40]u8 = undefined;
    _ = hex(&buf, "ab");
    try std.testing.expectEqualStrings(&buf, s);
}
