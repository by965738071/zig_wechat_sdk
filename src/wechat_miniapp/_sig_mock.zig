//! 测试专用「API 签名服务端」mock —— 模拟微信加密通道的服务端行为:
//! 验签(Wechatmp-Signature,与 api_signature.zig 共用测试密钥对)→ 校验
//! Wechatmp-Serial/Appid/TimeStamp → 用**请求头 ts** 构造 AAD 解密请求 →
//! 按路由表取**明文**业务响应 → 用响应侧时间戳重新加密返回。
//! 与 `_mock.zig` 的区别:这里是签名协议的**对端**,走完整个
//! 加密→签名→头→解密 往返,专门配合 `api_signature.zig` 的测试。
//! 仅供本模块测试文件使用,不从 root.zig 导出。
const std = @import("std");
const rsa = @import("zig-rsa");
const mp_http = @import("wechat_mp").http;
const mp_config = @import("wechat_mp").config;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const api_sig = @import("api_signature.zig");
const service_mod = @import("service.zig");
const mock_mod = @import("_mock.zig");

const WxResult = result_mod.WxResult;
const Response = result_mod.Response;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// PSS salt 长度与 api_signature.zig 保持一致(SHA-256 摘要长度)。
const PSS_SALT_LEN: isize = 32;

pub const Entry = struct { match: []const u8, response: []const u8 };

// ---- 测试固定配置(签名链路两侧共用;密钥仅测试用途,与
// wechat_pay/sign.zig 的测试 RSA 密钥对同源)----

/// 测试固定 AES-256 密钥(32 字节,base64 后即 `Args.aes_key`)。
pub const TEST_AES_KEY = "0123456789abcdef0123456789abcdef";
/// base64(TEST_AES_KEY),直接喂给 `api_signature.Args.aes_key`。
pub const TEST_AES_KEY_B64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
/// AES 密钥序号(进 AAD,不进签名串)。
pub const AES_KEY_SN = "aes-sn-test-1";
/// RSA 序列号(走请求头 Wechatmp-Serial)。
pub const RSA_KEY_SN = "rsa-sn-test-1";
/// 测试用 appid(与 fakeTokenConfig 的 "MA" 一致)。
pub const TEST_APPID = "MA";

/// 测试用 RSA 私钥(PKCS#8 PEM,2048 位;公钥由 sk.public_key 派生,验签用)。
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

pub const SigMock = struct {
    gpa: std.mem.Allocator,
    /// AES 密钥(原始字节;测试固定 32 字节,与 State 配置的 base64 同源)。
    aes: [32]u8,
    aes_key_sn: []const u8,
    rsa_key_sn: []const u8,
    appid: []const u8,
    pub_key: rsa.PublicKey,
    /// 响应侧时间戳(故意不同于请求侧,证明解密读的是响应头而非请求 ts)。
    resp_ts: i64 = 1700000001,
    /// 路由表:uri 含 match → response(**明文**业务响应,由本 mock 负责加密)。
    entries: []const Entry,

    // ---- 观测点(测试断言用;gpa 拥有,deinit 释放)----
    /// 最近一次**解密后的请求明文**(签名路径)。
    last_plain: ?[]u8 = null,
    /// 最近一次透传(未签名路径)的原始 body。
    saw_plain_body: ?[]u8 = null,
    /// 最近一次请求的 url_path(去 query)。
    last_url_path: [256]u8 = undefined,
    last_url_len: usize = 0,
    /// 各校验结果(不匹配会直接拒绝,这些标志供成功路径断言)。
    signature_verified: bool = false,
    serial_ok: bool = false,
    appid_ok: bool = false,
    header_ts_ok: bool = false,
    calls: usize = 0,

    pub fn init(gpa: std.mem.Allocator, aes: [32]u8, aes_key_sn: []const u8, rsa_key_sn: []const u8, appid: []const u8, pub_key: rsa.PublicKey, entries: []const Entry) SigMock {
        return .{
            .gpa = gpa,
            .aes = aes,
            .aes_key_sn = aes_key_sn,
            .rsa_key_sn = rsa_key_sn,
            .appid = appid,
            .pub_key = pub_key,
            .entries = entries,
        };
    }

    pub fn deinit(self: *SigMock) void {
        if (self.last_plain) |p| self.gpa.free(p);
        if (self.saw_plain_body) |b| self.gpa.free(b);
        self.last_plain = null;
        self.saw_plain_body = null;
    }

    pub fn executor(self: *SigMock) mp_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn urlPath(self: *const SigMock) []const u8 {
        return self.last_url_path[0..self.last_url_len];
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        const r = withHeadersImpl(ctx, gpa, io, method, uri, &.{}, body);
        return switch (r) {
            .ok => |resp| .{ .ok = resp.takeBody(gpa) },
            .err => |e| .{ .err = e },
        };
    }

    fn executeExImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult(Response) {
        return withHeadersImpl(ctx, gpa, io, method, uri, &.{}, body);
    }

    fn withHeadersImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, req_headers: []const result_mod.Header, body: ?[]const u8) WxResult(Response) {
        _ = method;
        const self: *SigMock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const b = body orelse "";

        // url_path(去 scheme://host 与 query;与 api_signature.urlPathOf 同一口径)
        var path = uri;
        if (std.mem.indexOf(u8, uri, "://")) |i| {
            const rest = uri[i + 3 ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .err = error_mod.WxError.transport(gpa, "sig mock: uri 缺 path", .{}) };
            path = rest[slash..];
        }
        const url_path = path[0..(std.mem.indexOfScalar(u8, path, '?') orelse path.len)];
        self.last_url_len = @min(url_path.len, self.last_url_path.len);
        @memcpy(self.last_url_path[0..self.last_url_len], url_path[0..self.last_url_len]);

        // 签名路径的信号:带 Wechatmp-Signature 请求头
        if (result_mod.headerValue(req_headers, "Wechatmp-Signature")) |sig_b64| {
            return self.signedRound(io, gpa, uri, url_path, b, req_headers, sig_b64);
        }
        // 透传:记录原始 body,回明文
        if (self.saw_plain_body) |old| self.gpa.free(old);
        self.saw_plain_body = gpa.dupe(u8, b) catch null;
        return self.routePlain(gpa, uri);
    }

    /// 服务端:验签 → 校验头 → 解密请求 → 校验字段 → 路由 → 加密响应。
    fn signedRound(self: *SigMock, io: std.Io, gpa: std.mem.Allocator, uri: []const u8, url_path: []const u8, req_body: []const u8, req_headers: []const result_mod.Header, sig_b64: []const u8) WxResult(Response) {
        const h_appid = result_mod.headerValue(req_headers, "Wechatmp-Appid") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 缺 Wechatmp-Appid", .{}) };
        const h_ts = result_mod.headerValue(req_headers, "Wechatmp-TimeStamp") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 缺 Wechatmp-TimeStamp", .{}) };
        const h_serial = result_mod.headerValue(req_headers, "Wechatmp-Serial") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 缺 Wechatmp-Serial", .{}) };

        self.appid_ok = std.mem.eql(u8, h_appid, self.appid);
        self.serial_ok = std.mem.eql(u8, h_serial, self.rsa_key_sn);
        if (!self.appid_ok) return .{ .err = error_mod.WxError.transport(gpa, "sig mock: appid 不符", .{}) };
        if (!self.serial_ok) return .{ .err = error_mod.WxError.transport(gpa, "sig mock: serial 不符", .{}) };

        const ts = std.fmt.parseInt(i64, h_ts, 10) catch
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: ts 非数字", .{}) };

        // 验签:待签名串 = urlpath\nappid\ntimestamp\npostdata(4 字段)
        const payload = std.fmt.allocPrint(gpa, "{s}\n{s}\n{d}\n{s}", .{ url_path, h_appid, ts, req_body }) catch
            return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(payload);
        const sig_raw = decodeB64(gpa, sig_b64) catch
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 签名非 base64", .{}) };
        defer gpa.free(sig_raw);
        rsa.verifyPss(gpa, self.pub_key, Sha256, payload, sig_raw, .{ .salt_leng = PSS_SALT_LEN }) catch
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 验签失败", .{}) };
        self.signature_verified = true;

        // 解密请求(AAD 用请求头 ts —— 与真实服务端一致)
        const plain = self.decryptBody(gpa, url_path, req_body, ts) catch |e| switch (e) {
            error.OutOfMemory => return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) },
            else => return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 解密请求失败({s})", .{@errorName(e)}) },
        };
        if (self.last_plain) |old| self.gpa.free(old);
        self.last_plain = plain;

        // 明文里的 _appid/_timestamp 必须与请求头一致(Java 组包即如此)
        const p = json_util.parse(gpa, plain) catch
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 明文非 JSON", .{}) };
        defer p.deinit();
        const inner_appid = json_util.getStr(p.value, "_appid") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 明文缺 _appid", .{}) };
        if (!std.mem.eql(u8, inner_appid, self.appid))
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 明文 _appid 不符", .{}) };
        const inner_ts = json_util.getInt(p.value, "_timestamp") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 明文缺 _timestamp", .{}) };
        self.header_ts_ok = inner_ts == ts;
        if (!self.header_ts_ok)
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: _timestamp 与请求头不符", .{}) };
        const n = json_util.getStr(p.value, "_n") orelse
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 明文缺 _n", .{}) };
        if (n.len != 30)
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: _n 长度非 30", .{}) };

        // 路由(按 uri 子串)→ 明文响应 → 用响应侧 ts 加密
        const resp_plain = blk: {
            for (self.entries) |e| {
                if (std.mem.indexOf(u8, uri, e.match) != null) break :blk e.response;
            }
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock miss: {s}", .{uri}) };
        };
        return self.encryptResponse(io, gpa, url_path, resp_plain);
    }

    fn decryptBody(self: *SigMock, gpa: std.mem.Allocator, url_path: []const u8, body: []const u8, req_ts: i64) ![]u8 {
        const parsed = try json_util.parse(gpa, body);
        defer parsed.deinit();
        const iv_s = json_util.getStr(parsed.value, "iv") orelse return error.BadFormat;
        const data_s = json_util.getStr(parsed.value, "data") orelse return error.BadFormat;
        const tag_s = json_util.getStr(parsed.value, "authtag") orelse return error.BadFormat;

        const iv_raw = try decodeB64(gpa, iv_s);
        defer gpa.free(iv_raw);
        const data_raw = try decodeB64(gpa, data_s);
        defer gpa.free(data_raw);
        const tag_raw = try decodeB64(gpa, tag_s);
        defer gpa.free(tag_raw);
        if (iv_raw.len != 12 or tag_raw.len != 16) return error.BadFormat;

        const aad = try std.fmt.allocPrint(gpa, "{s}|{s}|{d}|{s}", .{ url_path, self.appid, req_ts, self.aes_key_sn });
        defer gpa.free(aad);
        const plain = try gpa.alloc(u8, data_raw.len);
        errdefer gpa.free(plain);
        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plain, data_raw, tag_raw[0..16].*, aad, iv_raw[0..12].*, self.aes) catch return error.AuthFailed;
        return plain;
    }

    fn encryptResponse(self: *SigMock, io: std.Io, gpa: std.mem.Allocator, url_path: []const u8, plain: []const u8) WxResult(Response) {
        var nonce: [12]u8 = undefined;
        std.Io.randomSecure(io, &nonce) catch
            return .{ .err = error_mod.WxError.transport(gpa, "sig mock: 获取随机数失败", .{}) };
        const aad = std.fmt.allocPrint(gpa, "{s}|{s}|{d}|{s}", .{ url_path, self.appid, self.resp_ts, self.aes_key_sn }) catch
            return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(aad);
        const ct = gpa.alloc(u8, plain.len) catch
            return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(ct);
        var tag: [16]u8 = undefined;
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct, &tag, plain, aad, nonce, self.aes);

        const iv_b64 = encodeB64(gpa, &nonce) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(iv_b64);
        const data_b64 = encodeB64(gpa, ct) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(data_b64);
        const tag_b64 = encodeB64(gpa, &tag) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(tag_b64);

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("iv", iv_b64) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        ob.putStr("data", data_b64) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        ob.putStr("authtag", tag_b64) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };

        const ts_str = std.fmt.allocPrint(gpa, "{d}", .{self.resp_ts}) catch
            return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(ts_str);
        const headers = result_mod.dupeHeaders(gpa, &.{
            .{ .name = "Wechatmp-TimeStamp", .value = ts_str },
            .{ .name = "Wechatmp-Appid", .value = self.appid },
        }) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = .{ .body = body, .headers = headers } };
    }

    fn routePlain(self: *SigMock, gpa: std.mem.Allocator, uri: []const u8) WxResult(Response) {
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, uri, e.match) != null) {
                const body = gpa.dupe(u8, e.response) catch
                    return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
                return .{ .ok = .{ .body = body } };
            }
        }
        return .{ .err = error_mod.WxError.transport(gpa, "sig mock miss: {s}", .{uri}) };
    }

    const vtable = mp_http.RequestExecutor.VTable{
        .execute = executeImpl,
        .execute_ex = executeExImpl,
        .execute_with_headers = withHeadersImpl,
    };
};

fn encodeB64(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

fn decodeB64(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return error.BadFormat;
    const out = try gpa.alloc(u8, n);
    dec.decode(out, s) catch return error.BadFormat;
    return out;
}

/// 测试组合器:固定配置的 MiniappService + 本 mock(已启用 API 签名, token 返回
/// "TOK",appid="MA")。各测试文件共用,避免重复样板。
/// **就地初始化** —— MiniappService 持内部指针,不能按值返回后移动。
pub const Harness = struct {
    gpa: std.mem.Allocator,
    cfg: mp_config.InMemoryConfigStorage,
    mock: SigMock,
    sk: rsa.SecretKey,
    ma: service_mod.MiniappService,

    pub fn init(self: *Harness, gpa: std.mem.Allocator, entries: []const Entry) !void {
        const cfg = try mock_mod.fakeTokenConfig(gpa);
        self.* = .{ .gpa = gpa, .cfg = cfg, .mock = undefined, .sk = undefined, .ma = undefined };
        errdefer self.cfg.deinit();
        self.sk = try api_sig.parseRsaSecretKey(gpa, TEST_PRIV_PEM);
        errdefer self.sk.deinit(gpa);
        self.mock = SigMock.init(gpa, TEST_AES_KEY[0..32].*, AES_KEY_SN, RSA_KEY_SN, TEST_APPID, self.sk.public_key, entries);
        self.ma.init(gpa, self.cfg.config(), self.mock.executor());
        try self.ma.enableApiSignature(.{
            .aes_key = TEST_AES_KEY_B64,
            .aes_key_sn = AES_KEY_SN,
            .rsa_private_key = TEST_PRIV_PEM,
            .rsa_key_sn = RSA_KEY_SN,
        });
    }

    pub fn deinit(self: *Harness) void {
        self.ma.disableApiSignature();
        self.cfg.deinit();
        self.mock.deinit();
        self.sk.deinit(self.gpa);
    }
};
