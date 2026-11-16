//! 服务端网络相关服务 —— 对应 Java `api.WxMaInternetService` +
//! `api.impl.WxMaInternetServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Internet`:
//! - getUserEncryptKey:POST /wxa/business/getuserencryptkey
//!   ?sig_method=hmac_sha256&openid=...&signature=...(body 为空串,
//!   签名 = HMAC-SHA256(session_key, "") 的 hex 大写,与 Java sha256 实现一致);
//! - getUserEncryptKeyWithSignature(Java 中直接传入签名的重载,保留)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_USER_ENCRYPT_KEY_URL = "https://api.weixin.qq.com/wxa/business/getuserencryptkey";

// --- bean ---------------------------------------------------------------------

/// 对应 `internet.WxMaInternetUserKeyInfo`(encrypt_key/version/expire_in/iv/
/// create_time)。gpa 拥有。
pub const UserKeyInfo = struct {
    gpa: std.mem.Allocator,
    encrypt_key: ?[]const u8,
    version: ?i64,
    expire_in: ?i64,
    iv: ?[]const u8,
    create_time: ?i64,

    pub fn deinit(self: *UserKeyInfo) void {
        const g = self.gpa;
        if (self.encrypt_key) |s| g.free(@constCast(s));
        if (self.iv) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const UserKeyInfo) void {
        const g = self.gpa;
        if (self.encrypt_key) |s| g.free(s);
        if (self.iv) |s| g.free(s);
    }
};

/// 对应 `internet.WxMaInternetResponse`(key_info_list)。gpa 拥有。
pub const InternetResponse = struct {
    gpa: std.mem.Allocator,
    key_info_list: []UserKeyInfo,

    pub fn deinit(self: *InternetResponse) void {
        const g = self.gpa;
        for (self.key_info_list) |*k| k.deinit();
        g.free(self.key_info_list);
    }

    pub fn deinitConst(self: *const InternetResponse) void {
        const g = self.gpa;
        for (self.key_info_list) |*k| k.deinitConst();
        g.free(self.key_info_list);
    }
};

// --- service -------------------------------------------------------------------

pub const InternetService = struct {
    svc: *mp_service.Service,

    /// 对应 `getUserEncryptKey(openid, sessionKey)`:自动计算签名
    /// signature = hexUpper(HMAC-SHA256(session_key, "")),
    /// POST getuserencryptkey?sig_method=hmac_sha256&openid=..&signature=..。
    pub fn getUserEncryptKey(self: *InternetService, io: std.Io, openid: []const u8, session_key: []const u8) WxResult(InternetResponse) {
        const gpa = self.svc.gpa;
        const signature = hmacSha256HexUpper(gpa, "", session_key) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(signature);
        return self.getUserEncryptKeyWithSignature(io, openid, signature, "hmac_sha256");
    }

    /// 对应 Java 中直接传入签名的重载 `getUserEncryptKey(openid, signature, sigMethod)`
    /// (query 参数顺序与 Java 拼 URL 一致:openid/signature/sig_method)。
    pub fn getUserEncryptKeyWithSignature(self: *InternetService, io: std.Io, openid: []const u8, signature: []const u8, sig_method: []const u8) WxResult(InternetResponse) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_USER_ENCRYPT_KEY_URL, &.{
            .{ .key = "openid", .value = openid },
            .{ .key = "signature", .value = signature },
            .{ .key = "sig_method", .value = sig_method },
        }, "")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "internet response not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "key_info_list") orelse
            return .{ .ok = .{ .gpa = gpa, .key_info_list = &[_]UserKeyInfo{} } };
        const keys = gpa.alloc(UserKeyInfo, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (keys[0..filled]) |*k| k.deinit();
            gpa.free(keys);
        }
        for (arr.items) |item| {
            var k = UserKeyInfo{ .gpa = gpa, .encrypt_key = null, .version = null, .expire_in = null, .iv = null, .create_time = null };
            errdefer k.deinit();
            if (json_util.getStr(item, "encrypt_key")) |s| k.encrypt_key = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            k.version = json_util.getInt(item, "version");
            k.expire_in = json_util.getInt(item, "expire_in");
            if (json_util.getStr(item, "iv")) |s| k.iv = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            k.create_time = json_util.getInt(item, "create_time");
            keys[filled] = k;
            filled += 1;
        }
        return .{ .ok = .{ .gpa = gpa, .key_info_list = keys } };
    }
};

// 内部:HMAC-SHA256(data, key) → 64 位大写 hex(与 Java sha256 实现逐字节一致)。
fn hmacSha256HexUpper(gpa: std.mem.Allocator, data: []const u8, key: []const u8) ![]u8 {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, data, key);
    const out = try gpa.alloc(u8, mac.len * 2);
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "internet getUserEncryptKey: hmac signature + parse key_info_list" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getuserencryptkey", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"key_info_list\":[{\"encrypt_key\":\"VI6BpyrK9XH4i4AIGe86tg==\",\"version\":10,\"expire_in\":3597,\"iv\":\"6003f73ec441c386\",\"create_time\":1616572301}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = InternetService{ .svc = &base };

    const res = switch (s.getUserEncryptKey(io, "oOPENID", "sessionkey")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = res;
        r.deinit();
    }
    // 签名 = HMAC-SHA256(session_key, "") hex 大写:与 Java 实现一致
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, "", "sessionkey");
    var expect_buf: [HmacSha256.mac_length * 2]u8 = undefined;
    const hex = "0123456789ABCDEF";
    for (mac, 0..) |b, i| {
        expect_buf[i * 2] = hex[b >> 4];
        expect_buf[i * 2 + 1] = hex[b & 0x0f];
    }
    const sig = std.mem.concat(gpa, u8, &.{ "signature=", expect_buf[0..] }) catch return error.Unexpected;
    defer gpa.free(sig);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, sig) != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sig_method=hmac_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "openid=oOPENID") != null);

    try std.testing.expectEqual(@as(usize, 1), res.key_info_list.len);
    const k = res.key_info_list[0];
    try std.testing.expectEqualStrings("VI6BpyrK9XH4i4AIGe86tg==", k.encrypt_key.?);
    try std.testing.expectEqual(@as(i64, 10), k.version.?);
    try std.testing.expectEqual(@as(i64, 3597), k.expire_in.?);
    try std.testing.expectEqualStrings("6003f73ec441c386", k.iv.?);
    try std.testing.expectEqual(@as(i64, 1616572301), k.create_time.?);
    try std.testing.expectEqualStrings("", m.last_body);
}

test "internet getUserEncryptKeyWithSignature: raw signature passthrough" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getuserencryptkey", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"key_info_list\":[]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = InternetService{ .svc = &base };

    const res = switch (s.getUserEncryptKeyWithSignature(io, "oOPENID", "DEADBEEF", "hmac_sha256")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = res;
        r.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), res.key_info_list.len);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "signature=DEADBEEF") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sig_method=hmac_sha256") != null);
}
