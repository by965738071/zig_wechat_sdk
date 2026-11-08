//! 微信支付签名 —— 对应 Java `util.PaymentUtils` 的 V2/V3 签名面。
//!
//! **V2**(真实实现,纯哈希、无外部依赖):
//! - 参数字典序排序、跳过空值与 sign/key,拼 `k=v&...&key=MCH_KEY`;
//! - MD5 或 HMAC-SHA256 → hex **大写**(对应 `MD5Factory/HMacSHA256`);
//! - 验签必须基于**原始报文**的全字段(响应 XML 原文解析后的 map 重算,
//!   与 Java `BaseWxPayResult.checkSign` 同理)。
//!
//! **V3**:签名串 `method\nurl_path\ntimestamp\nnonce\nbody\n` +
//! Authorization `WECHATPAY2-SHA256-RSA2048 mchid=...,nonce_str=...,timestamp=...,serial_no=...,signature=...`。
//! RSA-PKCS1v15-SHA256 由 vendored `zig-rsa`(vendor/zig-rsa，Apache-2.0)提供：
//! `KeySigner` 从商户私钥 PEM 完成签名，`RsaSigner` 仍作为 vtable 接口
//! 保留可替换性（`stub` 表示“未配置密钥”，与 Java `Signer` 扩展点对应）。
const std = @import("std");
const rsa = @import("zig-rsa");
const sign_mod = @import("common").crypt.sign;
const config_mod = @import("config.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{ RsaNotImplemented, RsaFailed, BadRsaKey };

pub const Field = struct { key: []const u8, value: []const u8 };

fn lessThanKey(_: void, a: Field, b: Field) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// V2 待签串:字典序 + 跳空值 + 跳 sign/key + 末尾 `&key=`(对应
/// `PaymentUtils.createLinkString(sortMap, false)` + `&key=`)。
pub fn buildSignString(gpa: std.mem.Allocator, fields: []const Field, mch_key: []const u8) ![]u8 {
    const sorted = try gpa.dupe(Field, fields);
    defer gpa.free(sorted);
    std.sort.insertion(Field, sorted, {}, lessThanKey);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (sorted) |f| {
        if (f.value.len == 0) continue; // Java: 空值不参与签名
        if (std.mem.eql(u8, f.key, "sign") or std.mem.eql(u8, f.key, "key")) continue;
        if (out.items.len > 0) try out.append(gpa, '&');
        try out.appendSlice(gpa, f.key);
        try out.append(gpa, '=');
        try out.appendSlice(gpa, f.value);
    }
    try out.appendSlice(gpa, "&key=");
    try out.appendSlice(gpa, mch_key);
    return out.toOwnedSlice(gpa);
}

/// V2 签名(MD5 或 HMAC-SHA256,hex 大写)。返回 gpa 分配串。
pub fn signV2(gpa: std.mem.Allocator, fields: []const Field, mch_key: []const u8, st: config_mod.SignType) ![]u8 {
    const link = try buildSignString(gpa, fields, mch_key);
    defer gpa.free(link);
    return switch (st) {
        .md5 => sign_mod.md5HexUpper(gpa, link),
        .hmac_sha256 => sign_mod.hmacSha256HexUpper(gpa, link, mch_key),
    };
}

/// ASCII 大小写不敏感比较(验签容错,对应 equalsIgnoreCase)。
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// 验签(对已解析字段集合重算并比对 sign)。对应 `checkSign`。
pub fn checkSign(gpa: std.mem.Allocator, fields: []const Field, mch_key: []const u8, st: config_mod.SignType) !bool {
    var got_sign: []const u8 = "";
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, "sign")) got_sign = f.value;
    }
    if (got_sign.len == 0) return false;
    const expect = try signV2(gpa, fields, mch_key, st);
    defer gpa.free(expect);
    return eqlIgnoreCase(expect, got_sign);
}

// ---------------------------------------------------------------------------
// V3
// ---------------------------------------------------------------------------

/// RSA 签名器 vtable 接口（对应 Java `Signer`/`WechatPay2Credential` 扩展点）。
/// `stub` 表示“未配置商户私钥”；真实实现见 `KeySigner`。
pub const RsaSigner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sign: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, message: []const u8) Error![]u8,
    };

    /// 默认桩:直接报未实现(调用它即提醒接入依赖)。
    pub fn unimplemented(self: RsaSigner) RsaSigner {
        return self;
    }
    pub fn sign(self: RsaSigner, gpa: std.mem.Allocator, message: []const u8) Error![]u8 {
        return self.vtable.sign(self.ptr, gpa, message);
    }

    pub const stub = RsaSigner{
        .ptr = undefined,
        .vtable = &.{ .sign = struct {
            fn f(c: *anyopaque, g: std.mem.Allocator, m: []const u8) Error![]u8 {
                _ = c;
                _ = g;
                _ = m;
                return error.RsaNotImplemented;
            }
        }.f },
    };
};

/// 从 PEM 提取 base64 正文并解码为 DER
/// （兼容 PKCS#1 `RSA PRIVATE KEY` 与 PKCS#8 `PRIVATE KEY`）。
fn pemBodyToDer(gpa: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return error.BadRsaKey;
    const nl = std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return error.BadRsaKey;
    const end = std.mem.indexOfPos(u8, pem, nl, "-----END") orelse return error.BadRsaKey;

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(gpa);
    for (pem[nl + 1 .. end]) |ch| {
        if (!std.ascii.isWhitespace(ch)) try list.append(gpa, ch);
    }
    const b64 = try list.toOwnedSlice(gpa);
    defer gpa.free(b64);

    const cap = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.BadRsaKey;
    const der = try gpa.alloc(u8, cap);
    errdefer gpa.free(der);
    std.base64.standard.Decoder.decode(der, b64) catch return error.BadRsaKey;
    return der;
}

/// 商户私钥签名器：PEM → DER → `SecretKey.fromDerAuto`（自动识别 PKCS#1/#8）。
/// `signBase64` = base64(RSA-PKCS1v15-SHA256(message))，对应 Java
/// `Signature.getInstance("SHA256withRSA")` + Base64（V3 请求签名）。
pub const KeySigner = struct {
    gpa: std.mem.Allocator,
    sk: rsa.SecretKey,

    pub fn fromPem(gpa: std.mem.Allocator, pem: []const u8) !KeySigner {
        const der = try pemBodyToDer(gpa, pem);
        defer gpa.free(der);
        const sk = rsa.SecretKey.fromDerAuto(gpa, der) catch |e| {
            if (e == error.OutOfMemory) return e;
            return error.BadRsaKey;
        };
        return .{ .gpa = gpa, .sk = sk };
    }

    pub fn deinit(self: *KeySigner) void {
        self.sk.deinit(self.gpa);
    }

    pub fn signBase64(self: *KeySigner, gpa: std.mem.Allocator, message: []const u8) Error![]u8 {
        const sig = rsa.signPkcs1v15(gpa, self.sk, Sha256, message) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return error.RsaFailed;
        };
        defer gpa.free(sig);
        const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(sig.len));
        errdefer gpa.free(out);
        _ = std.base64.standard.Encoder.encode(out, sig);
        return out;
    }

    /// 适配为 `RsaSigner` vtable，供 `PayService` 注入。
    pub fn signer(self: *KeySigner) RsaSigner {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{ .sign = struct {
                fn f(ctx: *anyopaque, g: std.mem.Allocator, m: []const u8) Error![]u8 {
                    const ks: *KeySigner = @ptrCast(@alignCast(ctx));
                    return ks.signBase64(g, m);
                }
            }.f },
        };
    }
};

/// 验签（对应 Java `Signature.verify`，用于 V3 回调/平台证书应答）。
/// 签名不匹配是正常业务结果，返回 false；PEM/base64 格式错误报 `BadRsaKey`。
pub fn verifyWithPublicKeyPem(
    gpa: std.mem.Allocator,
    pub_pem: []const u8,
    message: []const u8,
    signature_b64: []const u8,
) Error!bool {
    const der = try pemBodyToDer(gpa, pub_pem);
    defer gpa.free(der);

    const cap = std.base64.standard.Decoder.calcSizeForSlice(signature_b64) catch return error.BadRsaKey;
    const sig = try gpa.alloc(u8, cap);
    defer gpa.free(sig);
    std.base64.standard.Decoder.decode(sig, signature_b64) catch return error.BadRsaKey;

    const pk = rsa.PublicKey.fromDerAuto(der) catch return error.BadRsaKey;
    rsa.verifyPkcs1v15(gpa, pk, Sha256, message, sig) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return false; // RsaVerifyFail 等验证类错误统一视为验签不通过
    };
    return true;
}

/// V3 签名串:`METHOD\nurl_path\ntimestamp\nnonce\nbody\n`
/// (对应 `WechatPay2Credential.buildMessage`)。
pub fn buildV3SignString(w: *std.Io.Writer, method: []const u8, url_path: []const u8, timestamp: []const u8, nonce: []const u8, body: []const u8) !void {
    try w.print("{s}\n{s}\n{s}\n{s}\n{s}\n", .{ method, url_path, timestamp, nonce, body });
}

/// 组装 Authorization 头值(signature 已由 RsaSigner 产出并 base64)。
/// 对应 `WECHATPAY2-SHA256-RSA2048 mchid="...",nonce_str="...",timestamp="...",serial_no="...",signature="..."`。
pub fn buildAuthorizationHeader(gpa: std.mem.Allocator, cfg: *config_mod.PayConfig, timestamp: []const u8, nonce: []const u8, signature_b64: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "WECHATPAY2-SHA256-RSA2048 mchid=\"{s}\",nonce_str=\"{s}\",timestamp=\"{s}\",serial_no=\"{s}\",signature=\"{s}\"",
        .{ cfg.mch_id, nonce, timestamp, cfg.cert_serial_no, signature_b64 },
    );
}

/// 一次 V3 请求签名的完整流程(除 RSA 本体):
/// sign_str → signer.sign → base64 → Authorization。
pub fn authorizationFor(
    gpa: std.mem.Allocator,
    cfg: *config_mod.PayConfig,
    signer: RsaSigner,
    method: []const u8,
    url_path: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    body: []const u8,
) Error![]u8 {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try buildV3SignString(&w, method, url_path, timestamp, nonce, body);
    const signed = try signer.sign(gpa, w.buffered());
    defer gpa.free(signed);
    return buildAuthorizationHeader(gpa, cfg, timestamp, nonce, signed);
}

// ---------------------------------------------------------------------------

test "v2 sign: order, skip empties/sign, uppercase hex, verify roundtrip" {
    const gpa = std.testing.allocator;
    const fields = [_]Field{
        .{ .key = "appid", .value = "wxpay1" },
        .{ .key = "mch_id", .value = "1900009" },
        .{ .key = "nonce_str", .value = "abc" },
        .{ .key = "empty_field", .value = "" }, // 跳过
        .{ .key = "sign", .value = "DEADBEEF" }, // 跳过
        .{ .key = "body", .value = "test" },
    };
    const s = try signV2(gpa, &fields, "KEY123", .md5);
    defer gpa.free(s);
    // 手算期望:body=test&appid... 按字典序 body<appid? b<w 是的;
    // 排序:appid, body, mch_id, nonce_str → "appid=wxpay1&body=test&mch_id=1900009&nonce_str=abc&key=KEY123"
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("appid=wxpay1&body=test&mch_id=1900009&nonce_str=abc&key=KEY123", &digest, .{});
    const hx = std.fmt.bytesToHex(digest, .upper);
    try std.testing.expectEqualStrings(&hx, s);

    // 验签:把合法签名塞回字段集合重算比对
    const clean = [_]Field{
        .{ .key = "appid", .value = "wxpay1" },
        .{ .key = "mch_id", .value = "1900009" },
        .{ .key = "nonce_str", .value = "abc" },
        .{ .key = "body", .value = "test" },
        .{ .key = "sign", .value = s },
    };
    try std.testing.expect(try checkSign(gpa, &clean, "KEY123", .md5));
    try std.testing.expect(!(try checkSign(gpa, &clean, "WRONG-KEY", .md5)));
}

test "v3 authorization assembly with stub signer" {
    const gpa = std.testing.allocator;
    var cfg = try config_mod.PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .cert_serial_no = "SERIAL1",
    });
    defer cfg.deinit();

    // RSA 桩必须报未实现
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try buildV3SignString(&w, "POST", "/v3/pay/transactions/jsapi", "1700000000", "NONCE", "{\"a\":1}");
    try std.testing.expectEqualStrings(
        "POST\n/v3/pay/transactions/jsapi\n1700000000\nNONCE\n{\"a\":1}\n",
        w.buffered(),
    );
    try std.testing.expectError(error.RsaNotImplemented, RsaSigner.stub.sign(gpa, w.buffered()));

    const auth = try buildAuthorizationHeader(gpa, &cfg, "1700000000", "NONCE", "SIGB64");
    defer gpa.free(auth);
    try std.testing.expectEqualStrings(
        "WECHATPAY2-SHA256-RSA2048 mchid=\"1900010\",nonce_str=\"NONCE\",timestamp=\"1700000000\",serial_no=\"SERIAL1\",signature=\"SIGB64\"",
        auth,
    );
}

// ---- 真实 RSA（vendored zig-rsa）测试用密钥对（仅测试用途的 2048 位随机密钥）----
// 导出供本模块其他文件的测试(验签/Authorization 断言)复用。

pub const TEST_PRIV_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCdhQ+ah6DN4Yhx
    \\+bhKPw/U1LpJccigGmw3uLuzJuoVXHHW9SK+lo14UAgiil0TYqP0ByVFXYRSD06/
    \\DPXLmEaqfFzY/ilL+H4JdLCsxpBa7t8vWV101/LoD0pfQAhVCBsA8XFVFJ2EGplB
    \\J/pu3rMZG4SrbZCj5MM6m3+V6h1L+X/MFnkjLdoI9LXgc/qeP+YAPRlbGYctQPx2
    \\eH+QJfgy29GFby/OnxeN1DSAyRhNXHLdUMSYO0kAd8ihFkmKo64GK57ul6GPQWHb
    \\pDKtIIRAi42gawaKhkBYsHXzvV9awvmszkbpcsngMH4Wsh32sQFF+ItPJCCL8W/U
    \\qt3hMISfAgMBAAECggEANIlGlQGbTk9kVK83GfxCaXex0gETKuLlKQiCAdR+yjUU
    \\+t6zgeFwuannrK19MZP6ns8rTSFNmpjkaLAH4qmdGAt2ZCEQ4Pe2Aa1bp6RqTQnS
    \\glZJ50iHCYLgCTiwDrwvVXcxl3DSwFamuqZ8zjGUhlE5RHu8fA02V/u45+U3dDjy
    \\uJrd7a7nNWZRJfZuCUI75g0UoJVaKttdoj7ZyybPx1O4Dje6lT6ZrOrbP/LxGfpv
    \\sv8KR8ZHsG98XBaPfc0QvpR1A+rKd2PbeYEIv9HGG7gBPN/5mlz2XCXD3hlmMgT3
    \\TwFE9kIs2l8VFV2GYJdugZg58wqTUxutaBIVYMc3AQKBgQDOT2nelnus2C5GRhFB
    \\ttgefHhZrEdwimPxYqibnixZeCc3m8p5vZwq1L0Hi5CoSk3yNVbl6AQpjWWpzrQe
    \\IUiqEc9V3uUgJkMKsTSqxR4jMz1EP6BEdSte4hGrVJZcLc+bNnKUE8q8hiwK4OwH
    \\OiO+pivWv1/tQJIwYG2+Us7u3wKBgQDDdVjtXsCAY4RTxa2PzHD4rZ2ZdYCoeJa4
    \\C02zJzXm/ZAvK62OWfyK6Q51v//DRe/2KDyc84dzIoCOCyb7dWOPDMcObUcyMDXM
    \\VvVlRpbFPfS5zXb9FZUmpQWHU4xvPKeNu222QpB5hFJdR6+a2JeryRxgGoAIULNz
    \\aUhHjdviQQKBgFJiD8qcmMJKiR/yts1g8CgsV/qm+tgLyyEG3oFVxivr+O0Rvuai
    \\Oow360vqBVfOZBXGCu8/mPnmxqPqMK6fZ97RwdNucFxIKxlH7doLYJ95xItORPdR
    \\OoJnD9s0qd4hRPeb5GERDjH9+fRWIKo6Iy/sNzFHtkyNLlM3DlujwZJNAoGAMJMW
    \\MY+NqZqRxTvoQUdef/6tnvibq8KkOkLc4XwKIki7r21caXclkuQOaub3SfE0jGk9
    \\fwfqjotxhVtyKaXnwyI6yfQQcIGYrRqjS7L6PzSBgDd2rbjSY1M5h4MU8IQTY97D
    \\ijsKqphe2723/3R6ZP/K5HtRfD+KCVGN2/J+RcECgYANfA84Yv9RT/JeZswxgFAp
    \\rnjGhh1Vttxvy8AvAGbmVWBezOJyo0zpNNkej79ig9FigBE0mVxRt/l9Vb824N3E
    \\dg6hAYc9djskXzeuzAttJ8bNek/U0XQj7L00Fl6fUb30IHYhcvLmEWQ2lTpk4DhF
    \\XUveMbT/KVCbYaZK7iLL5Q==
    \\-----END PRIVATE KEY-----
;

pub const TEST_PUB_PEM =
    \\-----BEGIN PUBLIC KEY-----
    \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnYUPmoegzeGIcfm4Sj8P
    \\1NS6SXHIoBpsN7i7sybqFVxx1vUivpaNeFAIIopdE2Kj9AclRV2EUg9Ovwz1y5hG
    \\qnxc2P4pS/h+CXSwrMaQWu7fL1lddNfy6A9KX0AIVQgbAPFxVRSdhBqZQSf6bt6z
    \\GRuEq22Qo+TDOpt/leodS/l/zBZ5Iy3aCPS14HP6nj/mAD0ZWxmHLUD8dnh/kCX4
    \\MtvRhW8vzp8XjdQ0gMkYTVxy3VDEmDtJAHfIoRZJiqOuBiue7pehj0Fh26QyrSCE
    \\QIuNoGsGioZAWLB1871fWsL5rM5G6XLJ4DB+FrId9rEBRfiLTyQgi/Fv1Krd4TCE
    \\nwIDAQAB
    \\-----END PUBLIC KEY-----
;

test "v3 real rsa: pem load, pkcs1v15-sha256 sign -> base64 -> verify" {
    const gpa = std.testing.allocator;
    var ks = try KeySigner.fromPem(gpa, TEST_PRIV_PEM);
    defer ks.deinit();

    const msg = "POST\n/v3/pay/transactions/jsapi\n1700000000\nNONCE\n{\"a\":1}\n";
    const sig_b64 = try ks.signBase64(gpa, msg);
    defer gpa.free(sig_b64);

    // 2048 位密钥的 PKCS1v15 签名 = 256 字节 -> base64 长度 344
    try std.testing.expectEqual(@as(usize, 344), sig_b64.len);
    try std.testing.expect(try verifyWithPublicKeyPem(gpa, TEST_PUB_PEM, msg, sig_b64));
    // 篡改报文后必须验不过
    try std.testing.expect(!(try verifyWithPublicKeyPem(gpa, TEST_PUB_PEM, "tampered", sig_b64)));
}

test "v3 authorizationFor end-to-end with real signer" {
    const gpa = std.testing.allocator;
    var cfg = try config_mod.PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .cert_serial_no = "SERIAL1",
    });
    defer cfg.deinit();
    var ks = try KeySigner.fromPem(gpa, TEST_PRIV_PEM);
    defer ks.deinit();

    const sign_str = "POST\n/v3/pay/transactions/jsapi\n1700000000\nNONCE\n{\"a\":1}\n";
    const auth = try authorizationFor(gpa, &cfg, ks.signer(), "POST", "/v3/pay/transactions/jsapi", "1700000000", "NONCE", "{\"a\":1}");
    defer gpa.free(auth);

    try std.testing.expect(std.mem.startsWith(u8, auth, "WECHATPAY2-SHA256-RSA2048 mchid=\"1900010\",nonce_str=\"NONCE\",timestamp=\"1700000000\",serial_no=\"SERIAL1\",signature=\""));

    // 从 Authorization 头里抽出 base64 签名，用公钥对原签名串验证闭环
    const marker = "signature=\"";
    const s = std.mem.indexOf(u8, auth, marker).? + marker.len;
    const e = std.mem.indexOfScalarPos(u8, auth, s, '"').?;
    try std.testing.expect(try verifyWithPublicKeyPem(gpa, TEST_PUB_PEM, sign_str, auth[s..e]));
}
