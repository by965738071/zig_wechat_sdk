//! 微信支付回调/敏感信息解密 —— 对应 Java:
//! - V2 退款通知 `req_info`: AES-256-ECB(PKCS5),key = md5HexLower(mchKey) 的 **ASCII 字节**(32B);
//! - V3 回调 resource: AES-256-GCM,key=api_v3_key(32B ASCII),nonce=resource.nonce,
//!   aad=associated_data,密文 base64 尾部 16B 为 tag。
const std = @import("std");
const aes_mode = @import("common").crypt.aes_mode;
const sign_mod = @import("common").crypt.sign;

pub const Error = error{
    BadBase64,
    BadCipherSize,
    AuthTagMismatch,
    DecryptFailed,
} || std.mem.Allocator.Error || std.base64.Error;

/// V2 退款通知 req_info 解密(对应 `WxPayRefundNotifyResult` 的 AES 解密)。
pub fn decryptReqInfo(gpa: std.mem.Allocator, mch_key: []const u8, req_info_b64: []const u8) Error![]u8 {
    const key_hex = try sign_mod.md5HexLower(gpa, mch_key); // 32 个小写 hex 字符当密钥字节
    defer gpa.free(key_hex);

    const n = std.base64.standard.Decoder.calcSizeForSlice(req_info_b64) catch return error.BadBase64;
    if (n == 0 or n % 16 != 0) return error.BadCipherSize;
    const cipher = try gpa.alloc(u8, n);
    defer gpa.free(cipher);
    std.base64.standard.Decoder.decode(cipher, req_info_b64) catch return error.BadBase64;

    const plain = try gpa.alloc(u8, n);
    errdefer gpa.free(plain); // 失败路径统一由 errdefer 释放
    var k32: [32]u8 = undefined;
    @memcpy(&k32, key_hex);
    var dctx = std.crypto.core.aes.Aes256.initDec(k32);
    const out = aes_mode.ecbDecryptPkcs7(&dctx, plain, cipher) catch return error.DecryptFailed;
    // 把去填充后的视图变成独立所有权(缩短长度不能直接交给调用方 free)
    const owned = try gpa.dupe(u8, out);
    gpa.free(plain);
    return owned;
}

/// V3 回调 resource 解密(对应 `NotificationParser` 的 AEAD 部分;
/// 证书验签在 service 层桩)。返回明文 JSON(gpa 分配)。
pub fn decryptResourceAes256Gcm(
    gpa: std.mem.Allocator,
    api_v3_key: []const u8,
    nonce: []const u8,
    associated_data: []const u8,
    ciphertext_b64: []const u8,
) Error![]u8 {
    if (api_v3_key.len != 32) return error.DecryptFailed;
    if (nonce.len != 12) return error.DecryptFailed;

    const n = try std.base64.standard.Decoder.calcSizeForSlice(ciphertext_b64);
    if (n <= 16) return error.BadCipherSize;
    const blob = try gpa.alloc(u8, n);
    defer gpa.free(blob);
    std.base64.standard.Decoder.decode(blob, ciphertext_b64) catch return error.BadBase64;

    const c = blob[0 .. n - 16];
    var tag: [16]u8 = undefined;
    @memcpy(&tag, blob[n - 16 ..]); // 切片不能直接 .*,经 memcpy 拷进定长数组

    const plain = try gpa.alloc(u8, c.len);
    errdefer gpa.free(plain);
    var key: [32]u8 = undefined;
    @memcpy(&key, api_v3_key);
    var npub: [12]u8 = undefined;
    @memcpy(&npub, nonce);

    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plain, c, tag, associated_data, npub, key) catch
        return error.AuthTagMismatch;
    return plain;
}

// ---------------------------------------------------------------------------

fn b64dup(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    errdefer gpa.free(out);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

test "v2 refund notify req_info roundtrip" {
    const gpa = std.testing.allocator;
    const mch_key = "abcdefghij1234567890abcdefghij123456"; // 32 字符
    const key_hex = try sign_mod.md5HexLower(gpa, mch_key);
    defer gpa.free(key_hex);

    const plain_xml = "<out_refund_no>R123</out_refund_no>";
    const pad: usize = 16 - plain_xml.len % 16;
    const padded = try gpa.alloc(u8, plain_xml.len + pad);
    defer gpa.free(padded);
    @memcpy(padded[0..plain_xml.len], plain_xml);
    @memset(padded[plain_xml.len..], @intCast(pad));

    var k32: [32]u8 = undefined;
    @memcpy(&k32, key_hex);
    var ectx = std.crypto.core.aes.Aes256.initEnc(k32);
    const cipher = try gpa.alloc(u8, padded.len);
    defer gpa.free(cipher);
    var off: usize = 0;
    while (off < padded.len) : (off += 16) {
        // 分组加密需编译期定长数组指针,经栈块中转
        var blk: [16]u8 = undefined;
        @memcpy(&blk, padded[off..][0..16]);
        var outb: [16]u8 = undefined;
        ectx.encrypt(&outb, &blk);
        @memcpy(cipher[off..][0..16], &outb);
    }
    const req_b64 = try b64dup(gpa, cipher);
    defer gpa.free(req_b64);

    const got = try decryptReqInfo(gpa, mch_key, req_b64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(plain_xml, got);
}

test "v3 notify gcm roundtrip" {
    const gpa = std.testing.allocator;
    const key_s = "0123456789abcdef0123456789abcdef"; // 32B api_v3_key
    const nonce = "abcdefghijkl"; // 12B
    const aad = "transaction";
    const plain_msg = "{\"id\":\"42\",\"out_trade_no\":\"T1\"}";

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
    const b64 = try b64dup(gpa, blob);
    defer gpa.free(b64);

    const got = try decryptResourceAes256Gcm(gpa, key_s, nonce, aad, b64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(plain_msg, got);

    // 篡改 AAD → tag 校验失败
    try std.testing.expectError(error.AuthTagMismatch, decryptResourceAes256Gcm(gpa, key_s, nonce, "wrong", b64));
}
