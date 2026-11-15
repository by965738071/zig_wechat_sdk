//! 小程序用户服务 —— 对应 Java `api.WxMaUserService` + `api.impl.WxMaUserServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.User`:
//! - jsCode2Session:委托 MiniappService 既有实现(无 token 通道);
//! - getUserInfo/getPhoneNoInfo(sessionKey 版):`WxMaCryptUtils.decrypt` 后本地解析
//!   (对应 Java 走 AES 解密,不联网,故非 WxResult);
//! - getPhoneNumber(code):POST /wxa/business/getuserphonenumber(带 token);
//! - setUserStorage:`sign=HmacSHA256(kv, sessionKey)` + URL 模板
//!   /wxa/set_user_storage?appid=&signature=&openid=&sig_method=hmac_sha256(带 token);
//! - getCode2VerifyInfo:POST /wxa/sec/checkcode2verifyinfo(带 token);
//! - checkSessionKey:`sign=HmacSHA256("", sessionKey)` + GET
//!   /wxa/checksession?openid=&signature=&sig_method=hmac_sha256(带 token);
//! - checkUserInfo:本地 `SHA1(rawData+sessionKey)` 比对(不联网)。
//!
//! URL 拼接/编码对齐 Java `URLUtil.urlEncode(s, UTF-8)`(RFC3986);签名取小写 hex。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const sign_mod = @import("common").crypt.sign;
const sha1_mod = @import("common").crypt.sha1;
const crypt_mod = @import("crypt.zig");
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

// --- URL(对应 WxMaApiUrlConstants.User)-----------------------------------------
const GET_PHONE_NUMBER_URL = "https://api.weixin.qq.com/wxa/business/getuserphonenumber";
const CODE_2_VERIFY_INFO_URL = "https://api.weixin.qq.com/wxa/sec/checkcode2verifyinfo";
const SET_USER_STORAGE_PATH = "/wxa/set_user_storage";
const CHECK_SESSION_PATH = "/wxa/checksession";

/// 写一个 JSON 字符串字面量(带引号与转义)。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn fold(gpa: std.mem.Allocator, msg: []const u8, e: anyerror) WxError {
    return WxError.transport(gpa, "{s}: {s}", .{ msg, @errorName(e) });
}

/// 写 JSON 体:把可失败写入折叠为 transport 错误(非 `!` 返回型方法内不能用 `try`)。
fn writeErr(gpa: std.mem.Allocator, e: anyerror) WxError {
    return fold(gpa, "build request body", e);
}

/// RFC3986 URL 编码(对应 Java `URLUtil.urlEncode(s, UTF-8)`)。保留字符(字母数字
/// 及 `-_.~`)原样,其余百分号编码(小写 hex,与 Java `URLUtil` 一致)。
fn urlEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hexdig = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
    for (s) |c| {
        const is_unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (is_unreserved) {
            try out.append(gpa, c);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hexdig[c >> 4]);
            try out.append(gpa, hexdig[c & 0xF]);
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaPhoneNumberInfo`(3 个字符串字段;略 watermark)。gpa 拥有。
pub const PhoneNumberInfo = struct {
    gpa: std.mem.Allocator,
    phone_number: []const u8,
    pure_phone_number: []const u8,
    country_code: []const u8,

    pub fn deinit(self: *PhoneNumberInfo) void {
        self.gpa.free(@constCast(self.phone_number));
        self.gpa.free(@constCast(self.pure_phone_number));
        self.gpa.free(@constCast(self.country_code));
    }

    /// 允许从 `const` 借用值上释放(仅释放 gpa 拥有的字符串字段)。
    pub fn deinitConst(self: *const PhoneNumberInfo) void {
        self.gpa.free(self.phone_number);
        self.gpa.free(self.pure_phone_number);
        self.gpa.free(self.country_code);
    }
};

/// 对应 `WxMaCode2VerifyInfoResult`(session_key/openid/unionid/is_limit)。gpa 拥有。
pub const Code2VerifyInfo = struct {
    gpa: std.mem.Allocator,
    session_key: []const u8,
    openid: []const u8,
    unionid: ?[]const u8,
    is_limit: ?bool,

    pub fn deinit(self: *Code2VerifyInfo) void {
        self.gpa.free(@constCast(self.session_key));
        self.gpa.free(@constCast(self.openid));
        if (self.unionid) |u| self.gpa.free(@constCast(u));
    }
};

// --- service ------------------------------------------------------------------

/// 用户服务 —— 组合在服务基座上(对应 `WxMaUserServiceImpl` 持有 `WxMaService` 引用)。
pub const UserService = struct {
    svc: *mp_service.Service,

    /// 对应 `getSessionInfo(jsCode)`:GET /sns/jscode2session(无 token 通道,对应
    /// Java `SimpleGet`)。返回原始响应(含 session_key/openid/unionid),调用方解析。
    pub fn getSessionInfo(self: *UserService, io: std.Io, js_code: []const u8) WxResult([]const u8) {
        return self.svc.executeNoToken(io, "https://api.weixin.qq.com/sns/jscode2session", &.{
            .{ .key = "appid", .value = self.svc.config.appid() },
            .{ .key = "secret", .value = self.svc.config.secret() },
            .{ .key = "js_code", .value = js_code },
            .{ .key = "grant_type", .value = "authorization_code" },
        }, null);
    }

    /// 对应 `getUserInfo(sessionKey, encryptedData, ivStr)`(AES 解密本地 bean,不联网)。
    pub fn getUserInfo(self: *UserService, session_key: []const u8, encrypted_data: []const u8, iv: []const u8) crypt_mod.Error!crypt_mod.PhoneInfo {
        return crypt_mod.getUserPhoneInfo(self.svc.gpa, session_key, encrypted_data, iv);
    }

    /// 对应 `setUserStorage(kv, sessionKey, openid)`:POST 带 token + HMAC 签名。
    pub fn setUserStorage(self: *UserService, io: std.Io, kv: []const struct { key: []const u8, value: []const u8 }, session_key: []const u8, openid: []const u8) Done {
        const gpa = self.svc.gpa;
        var body: std.Io.Writer.Allocating = .init(gpa);
        errdefer body.deinit();
        const w = &body.writer;
        w.writeAll("{\"kv_list\":[") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        for (kv, 0..) |e, i| {
            if (i > 0) w.writeByte(',') catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            w.writeAll("{\"key\":") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            js(w, e.key) catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            w.writeAll(",\"value\":") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            js(w, e.value) catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            w.writeAll("}") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        }
        w.writeAll("]}") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        const params = body.toOwnedSlice() catch return .{ .err = writeErr(gpa, error.OutOfMemory) };
        defer gpa.free(params);

        const sig = sign_mod.hmacSha256HexLower(gpa, params, session_key) catch
            return .{ .err = fold(gpa, "setUserStorage sign", error.OutOfMemory) };
        defer gpa.free(sig);

        const url = buildTokenUrl(gpa, SET_USER_STORAGE_PATH, &.{
            .{ .key = "appid", .value = self.svc.config.appid() },
            .{ .key = "signature", .value = sig },
            .{ .key = "openid", .value = openid },
            .{ .key = "sig_method", .value = "hmac_sha256" },
        }) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(url);
        return self.postNoTokenVoid(io, url, params);
    }

    /// 对应 `getPhoneNumber(code)`(可选 openid):POST /wxa/business/getuserphonenumber。
    pub fn getPhoneNumber(self: *UserService, io: std.Io, code: []const u8, openid: ?[]const u8) WxResult(?PhoneNumberInfo) {
        const gpa = self.svc.gpa;
        var body: std.Io.Writer.Allocating = .init(gpa);
        errdefer body.deinit();
        const w = &body.writer;
        w.writeAll("{\"code\":") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        js(w, code) catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        if (openid) |o| {
            w.writeAll(",\"openid\":") catch return .{ .err = writeErr(gpa, error.WriteFailed) };
            js(w, o) catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        }
        w.writeByte('}') catch return .{ .err = writeErr(gpa, error.WriteFailed) };
        const params = body.toOwnedSlice() catch return .{ .err = writeErr(gpa, error.OutOfMemory) };
        defer gpa.free(params);

        const resp = switch (self.svc.post(io, GET_PHONE_NUMBER_URL, &.{}, params)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{ .err = WxError.transport(gpa, "phone not json", .{}) };
        defer parsed.deinit();
        const phoneobj = json_util.getObject(parsed.value, "phone_info") orelse return .{ .ok = null };
        const ph = gpa.dupe(u8, json_util.getStrOr(phoneobj, "phoneNumber", "")) catch
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        const pp = gpa.dupe(u8, json_util.getStrOr(phoneobj, "purePhoneNumber", "")) catch {
            gpa.free(ph);
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        };
        const cc = gpa.dupe(u8, json_util.getStrOr(phoneobj, "countryCode", "")) catch {
            gpa.free(ph);
            gpa.free(pp);
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        };
        return .{ .ok = .{
            .gpa = gpa,
            .phone_number = ph,
            .pure_phone_number = pp,
            .country_code = cc,
        } };
    }

    /// 对应 `checkUserInfo(sessionKey, rawData, signature)`:本地 SHA1(rawData+sessionKey)。
    pub fn checkUserInfo(self: *UserService, session_key: []const u8, raw_data: []const u8, signature: []const u8) bool {
        const gpa = self.svc.gpa;
        const combined = std.mem.concat(gpa, u8, &.{ raw_data, session_key }) catch return false;
        defer gpa.free(combined);
        const sig = sha1_mod.gen(gpa, &.{combined}) catch return false;
        defer gpa.free(sig);
        return std.mem.eql(u8, sig, signature);
    }

    /// 对应 `getCode2VerifyInfo(code, checkcode)`:POST /wxa/sec/checkcode2verifyinfo。
    pub fn getCode2VerifyInfo(self: *UserService, io: std.Io, code: []const u8, checkcode: []const u8) WxResult(Code2VerifyInfo) {
        const gpa = self.svc.gpa;
        var bw: std.Io.Writer.Allocating = .init(gpa);
        errdefer bw.deinit();
        const w = &bw.writer;
        w.writeAll("{\"code\":") catch return .{ .err = fold(gpa, "oom", error.WriteFailed) };
        js(w, code) catch return .{ .err = fold(gpa, "oom", error.WriteFailed) };
        w.writeAll(",\"checkcode\":") catch return .{ .err = fold(gpa, "oom", error.WriteFailed) };
        js(w, checkcode) catch return .{ .err = fold(gpa, "oom", error.WriteFailed) };
        w.writeByte('}') catch return .{ .err = fold(gpa, "oom", error.WriteFailed) };
        const body = bw.toOwnedSlice() catch return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, CODE_2_VERIFY_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{ .err = WxError.transport(gpa, "code2verify not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        const sk = gpa.dupe(u8, json_util.getStrOr(v, "session_key", "")) catch
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        const oid = gpa.dupe(u8, json_util.getStrOr(v, "openid", "")) catch {
            gpa.free(sk);
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        };
        const uid = if (json_util.getStr(v, "unionid")) |u| gpa.dupe(u8, u) catch {
            gpa.free(sk);
            gpa.free(oid);
            return .{ .err = fold(gpa, "oom", error.OutOfMemory) };
        } else null;
        return .{ .ok = .{
            .gpa = gpa,
            .session_key = sk,
            .openid = oid,
            .unionid = uid,
            .is_limit = json_util.getBool(v, "is_limit"),
        } };
    }

    /// 对应 `checkSessionKey(openid, sessionKey)`:GET /wxa/checksession?openid=&signature=...。
    pub fn checkSessionKey(self: *UserService, io: std.Io, openid: []const u8, session_key: []const u8) Done {
        const gpa = self.svc.gpa;
        const sig = sign_mod.hmacSha256HexLower(gpa, "", session_key) catch
            return .{ .err = fold(gpa, "checkSessionKey sign", error.OutOfMemory) };
        defer gpa.free(sig);
        const url = buildTokenUrl(gpa, CHECK_SESSION_PATH, &.{
            .{ .key = "openid", .value = openid },
            .{ .key = "signature", .value = sig },
            .{ .key = "sig_method", .value = "hmac_sha256" },
        }) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(url);
        const resp = switch (self.svc.executeNoToken(io, url, &.{}, null)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    // 内部:拼带 query 的完整 URL(不附 token;token 由调用方走 no-token/带 token 通道)。
    fn buildTokenUrl(gpa: std.mem.Allocator, path: []const u8, qs: []const mp_service.Query) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("https://api.weixin.qq.com");
        try w.writeAll(path);
        var first: bool = true;
        for (qs) |q| {
            if (first) {
                try w.writeByte('?');
                first = false;
            } else {
                try w.writeByte('&');
            }
            try w.writeAll(q.key);
            try w.writeAll("=");
            const enc = try urlEncode(gpa, q.value);
            defer gpa.free(enc);
            try w.writeAll(enc);
        }
        return out.toOwnedSlice();
    }

    fn postNoTokenVoid(self: *UserService, io: std.Io, url: []const u8, body: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + body + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "user getPhoneNumber: parse phone_info" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getuserphonenumber", .response = "{\"errcode\":0,\"phone_info\":{\"phoneNumber\":\"+86138\",\"purePhoneNumber\":\"138\",\"countryCode\":\"86\"}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UserService{ .svc = &base };

    const r = switch (s.getPhoneNumber(io, "P1", null)) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    if (r) |pi| {
        try std.testing.expectEqualStrings("+86138", pi.phone_number);
        try std.testing.expectEqualStrings("138", pi.pure_phone_number);
    } else return error.ExpectedInfo;
    if (r) |pi| pi.deinitConst();
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);
}

test "user getCode2VerifyInfo: parse session_key/openid/is_limit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "checkcode2verifyinfo", .response = "{\"errcode\":0,\"session_key\":\"SK\",\"openid\":\"O\",\"unionid\":\"U\",\"is_limit\":true}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UserService{ .svc = &base };

    const r = switch (s.getCode2VerifyInfo(io, "C", "K")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    var r2 = r;
    try std.testing.expectEqualStrings("SK", r2.session_key);
    try std.testing.expectEqualStrings("O", r2.openid);
    try std.testing.expectEqualStrings("U", r2.unionid.?);
    try std.testing.expectEqual(@as(?bool, true), r2.is_limit);
    r2.deinit();
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C", json_util.getStr(parsed.value, "code").?);
    try std.testing.expectEqualStrings("K", json_util.getStr(parsed.value, "checkcode").?);
}

test "user checkUserInfo: sha1(rawData+sessionKey) matches" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "unused" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UserService{ .svc = &base };

    const raw = "RAWDATA";
    const sk = "SESSIONKEY";
    // 用同一 SHA1 算法独立算出期望值
    const combined = std.mem.concat(gpa, u8, &.{ raw, sk }) catch unreachable;
    defer gpa.free(combined);
    const expect_sig = sha1_mod.gen(gpa, &.{combined}) catch unreachable;
    defer gpa.free(expect_sig);
    try std.testing.expect(s.checkUserInfo(sk, raw, expect_sig));
    try std.testing.expect(!s.checkUserInfo(sk, raw, "wrong"));
    _ = io;
}

test "user setUserStorage: hmac sign + url template" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "set_user_storage", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UserService{ .svc = &base };

    const r = s.setUserStorage(io, &.{.{ .key = "k1", .value = "v1" }}, "SK", "O1");
    try std.testing.expect(!r.failed());
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "set_user_storage") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sig_method=hmac_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "appid=MA") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expect(json_util.getArray(parsed.value, "kv_list") != null);
    const kv = json_util.getArray(parsed.value, "kv_list").?;
    try std.testing.expectEqualStrings("k1", json_util.getStrOr(kv.items[0], "key", ""));
}

test "user checkSessionKey: hmac sign(empty) + get url" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "checksession", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UserService{ .svc = &base };

    const r = s.checkSessionKey(io, "O1", "SK");
    try std.testing.expect(!r.failed());
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.get, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "checksession") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "openid=O1") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sig_method=hmac_sha256") != null);
}
