//! V3 回调通知解析 —— 对应 Java `notification/NotificationParser` +
//! `notification/NotificationRequest/Notification`。
//!
//! 流程(与 Java `parse` 一致):
//! 1. 外层报文 JSON 的 `resource` 字段:{ciphertext(base64), nonce, associated_data};
//! 2. AES-256-GCM 解密(key=api_v3_key)→ 明文业务 JSON(支付成功/退款通知);
//! 3. 签名校验独立(见 `verifySignature`):串 = `timestamp\nnonce\nbody\n`,
//!    平台证书公钥 RSA-SHA256 验签(应答验签共用 `v3.verifyWithPublicKeyPem`)。
const std = @import("std");
const json_util = @import("common").json_util;
const crypt = @import("crypt.zig");
pub const sign = @import("sign.zig");

pub const Error = crypt.Error;

/// 解析并解密 V3 通知,返回**明文业务 JSON**(gpa 分配,调用方 free)。
/// `body_json` 为 HTTP 原始请求体(借用,不拥有)。
/// 对应 `NotificationParser.parse(request, class)` 的解密段(证书验签由
/// HTTP 层先调 `verifySignature`,与 Java 分层一致)。
pub fn parseNotification(gpa: std.mem.Allocator, body_json: []const u8, api_v3_key: []const u8) Error![]u8 {
    var parsed = json_util.parse(gpa, body_json) catch return error.DecryptFailed;
    defer parsed.deinit();

    const res = json_util.objectOf(parsed.value, "resource") orelse return error.DecryptFailed;
    const ciphertext = switch (res.get("ciphertext") orelse return error.DecryptFailed) {
        .string => |s| s,
        else => return error.DecryptFailed,
    };
    const nonce = switch (res.get("nonce") orelse return error.DecryptFailed) {
        .string => |s| s,
        else => return error.DecryptFailed,
    };
    const aad = if (res.get("associated_data")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    return crypt.decryptResourceAes256Gcm(gpa, api_v3_key, nonce, aad, ciphertext);
}

/// 通知验签(对应 `NotificationParser` 依赖的 `SignatureVerifier`):
/// 串 = `timestamp\nnonce\nbody\n`,body 为原始请求体。
pub fn verifySignature(
    gpa: std.mem.Allocator,
    platform_pub_pem: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    body_json: []const u8,
    signature_b64: []const u8,
) !bool {
    const msg = try std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}\n", .{ timestamp, nonce, body_json });
    defer gpa.free(msg);
    return sign.verifyWithPublicKeyPem(gpa, platform_pub_pem, msg, signature_b64);
}

// ---------------------------------------------------------------------------

test "parse notification roundtrip" {
    const gpa = std.testing.allocator;
    const key_s = "0123456789abcdef0123456789abcdef"; // 32B api_v3_key
    const nonce = "abcdefghijkl";
    const aad = "transaction";
    const plain_msg = "{\"id\":\"42\",\"out_trade_no\":\"T1\",\"trade_state\":\"SUCCESS\"}";

    // 自己用同一 key 加密一段样例(与微信侧构造一致:cipher‖tag 后 base64)
    var key: [32]u8 = undefined;
    @memcpy(&key, key_s);
    var npub: [12]u8 = undefined;
    @memcpy(&npub, nonce);
    const cipher = try gpa.alloc(u8, plain_msg.len);
    defer gpa.free(cipher);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(cipher, &tag, plain_msg, aad, npub, key);
    const blob = try gpa.alloc(u8, cipher.len + 16);
    defer gpa.free(blob);
    @memcpy(blob[0..cipher.len], cipher);
    @memcpy(blob[cipher.len..], &tag);
    const b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(blob.len));
    defer gpa.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, blob);

    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"id\":\"n1\",\"resource_type\":\"encrypt-resource\",\"event_type\":\"TRANSACTION.SUCCESS\",\"resource\":{{\"original_type\":\"transaction\",\"algorithm\":\"AEAD_AES_256_GCM\",\"ciphertext\":\"{s}\",\"associated_data\":\"{s}\",\"nonce\":\"{s}\"}}}}",
        .{ b64, aad, nonce },
    );
    defer gpa.free(body);

    const got = try parseNotification(gpa, body, key_s);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(plain_msg, got);

    // 错误 key → tag 校验失败
    try std.testing.expectError(error.AuthTagMismatch, parseNotification(gpa, body, "ffffffffffffffffffffffffffffffff"));
    // 无 resource → DecryptFailed
    try std.testing.expectError(error.DecryptFailed, parseNotification(gpa, "{}", key_s));
}

test "notification signature verify" {
    const gpa = std.testing.allocator;
    var ks = try sign.KeySigner.fromPem(gpa, sign.TEST_PRIV_PEM);
    defer ks.deinit();

    const ts = "1700000000";
    const nonce = "NONCE123";
    const body = "{\"id\":\"n1\"}";
    const msg = try std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}\n", .{ ts, nonce, body });
    defer gpa.free(msg);
    const sig = try ks.signBase64(gpa, msg);
    defer gpa.free(sig);

    try std.testing.expect(try verifySignature(gpa, sign.TEST_PUB_PEM, ts, nonce, body, sig));
    try std.testing.expect(!(try verifySignature(gpa, sign.TEST_PUB_PEM, "1700000001", nonce, body, sig)));
}
