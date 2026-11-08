//! 小程序数据解密 —— 对应 Java `util.WxMaCryptUtils`
//! (`decrypt(sessionKey, encryptedData, iv)` / `getUserPhoneInfo`)。
//!
//! 协议(AES-128-CBC NoPadding + **标准 PKCS7 去填充**):
//! - key = base64decode(session_key)(16 字节)
//! - iv  = base64decode(iv)
//! - 密文 = base64decode(encrypted_data),解密后按尾字节去填充(1..16)。
//! 与公众号 WxCryptUtil 的区别:那边是自定义 block=32 填充 + 拼包;这里是标准 16。
const std = @import("std");
const aes_mode = @import("common").crypt.aes_mode;

pub const Error = error{
    BadBase64,
    BadCipherSize,
    BadPadding,
    DecryptFailed,
} || std.mem.Allocator.Error;

/// 去标准 PKCS7 填充(块 16;校验尾 n 字节都等于 n)。
fn removePkcs7(buf: []const u8) Error![]const u8 {
    if (buf.len == 0 or buf.len % 16 != 0) return error.BadPadding;
    const n: usize = buf[buf.len - 1];
    if (n == 0 or n > 16 or n > buf.len) return error.BadPadding;
    for (buf[buf.len - n ..]) |b| if (b != @as(u8, @intCast(n))) return error.BadPadding;
    return buf[0 .. buf.len - n];
}

/// 对应 `WxMaCryptUtils.decrypt(sessionKey, encryptedData, iv)`。
/// 返回明文(gpa 分配,通常是 JSON 字符串,调用方释放)。
pub fn decrypt(gpa: std.mem.Allocator, session_key_b64: []const u8, encrypted_data_b64: []const u8, iv_b64: []const u8) Error![]u8 {
    var key: [16]u8 = undefined;
    if ((std.base64.standard.Decoder.calcSizeForSlice(session_key_b64) catch 0) != 16) return error.BadBase64;
    std.base64.standard.Decoder.decode(&key, session_key_b64) catch return error.BadBase64;

    var iv: [16]u8 = undefined;
    if ((std.base64.standard.Decoder.calcSizeForSlice(iv_b64) catch 0) != 16) return error.BadBase64;
    std.base64.standard.Decoder.decode(&iv, iv_b64) catch return error.BadBase64;

    const n = std.base64.standard.Decoder.calcSizeForSlice(encrypted_data_b64) catch return error.BadBase64;
    if (n == 0 or n % 16 != 0) return error.BadCipherSize;
    const buf = try gpa.alloc(u8, n);
    defer gpa.free(buf); // 纯暂存区:成功路径也要释放(dupe 先于 defer 完成)
    std.base64.standard.Decoder.decode(buf, encrypted_data_b64) catch return error.BadBase64;

    var dctx = std.crypto.core.aes.Aes128.initDec(key);
    aes_mode.cbcDecrypt(&dctx, buf, buf, &iv) catch return error.DecryptFailed;

    const plain = try removePkcs7(buf);
    return try gpa.dupe(u8, plain);
}

/// 对应 `WxMaPhoneNumberInfo`/`WxMaUserService.getPhoneNoInfo`:手机号 JSON 走
/// 同一条解密路径,解析后返回结构化字段。骨架收录 Java `WxMaPhoneNumberInfo`
/// 的 3 个字符串字段(phoneNumber/purePhoneNumber/countryCode),
/// 略去嵌套的 watermark 对象。三个字段均为 gpa 拥有,deinit 统一释放。
pub const PhoneInfo = struct {
    phone_number: []const u8, // gpa 拥有
    pure_phone_number: []const u8,
    country_code: []const u8,

    pub fn deinit(self: *PhoneInfo, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.phone_number));
        gpa.free(@constCast(self.pure_phone_number));
        gpa.free(@constCast(self.country_code));
    }
};

pub fn getUserPhoneInfo(gpa: std.mem.Allocator, session_key_b64: []const u8, encrypted_data_b64: []const u8, iv_b64: []const u8) (Error || error{BadJson})!PhoneInfo {
    const json_mod = @import("common").json_util;
    const plain = try decrypt(gpa, session_key_b64, encrypted_data_b64, iv_b64);
    defer gpa.free(plain);
    const parsed = json_mod.parse(gpa, plain) catch return error.BadJson;
    defer parsed.deinit();
    const obj = json_mod.object(parsed.value) orelse return error.BadJson;
    _ = obj;
    var out = PhoneInfo{
        .phone_number = try gpa.dupe(u8, json_mod.getStr(parsed.value, "phoneNumber") orelse ""),
        .pure_phone_number = try gpa.dupe(u8, json_mod.getStr(parsed.value, "purePhoneNumber") orelse ""),
        .country_code = try gpa.dupe(u8, json_mod.getStr(parsed.value, "countryCode") orelse ""),
    };
    errdefer out.deinit(gpa);
    return out;
}

// ---------------------------------------------------------------------------

fn b64(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    errdefer gpa.free(out);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

test "wxma decrypt roundtrip (self-encrypted vector)" {
    const gpa = std.testing.allocator;
    // 用同一把 key 先加密再走 decrypt,验证整条路径
    const key = [_]u8{ 0x2a, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const plain = "{\"phoneNumber\":\"+8613800000000\",\"purePhoneNumber\":\"13800000000\",\"countryCode\":\"86\"}";

    // 手工 PKCS7(16) 填充 + CBC 加密
    const pad: u8 = @intCast(16 - plain.len % 16);
    const padded = try gpa.alloc(u8, plain.len + pad);
    defer gpa.free(padded);
    @memcpy(padded[0..plain.len], plain);
    @memset(padded[plain.len..], pad);
    const cipher = try gpa.alloc(u8, padded.len);
    defer gpa.free(cipher);
    var ectx = std.crypto.core.aes.Aes128.initEnc(key);
    try aes_mode.cbcEncrypt(&ectx, cipher, padded, &iv);

    const key_b64 = try b64(gpa, &key);
    defer gpa.free(key_b64);
    const iv_b64 = try b64(gpa, &iv);
    defer gpa.free(iv_b64);
    const data_b64 = try b64(gpa, cipher);
    defer gpa.free(data_b64);

    const got = try decrypt(gpa, key_b64, data_b64, iv_b64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(plain, got);

    var info = try getUserPhoneInfo(gpa, key_b64, data_b64, iv_b64);
    defer info.deinit(gpa);
    try std.testing.expectEqualStrings("+8613800000000", info.phone_number);
}
