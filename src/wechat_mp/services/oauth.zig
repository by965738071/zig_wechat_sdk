//! OAuth2 网页授权服务 —— 对应 Java `common.service.WxOAuth2Service`
//! + `api.impl.WxMpOAuth2ServiceImpl`。
//!
//! URL 以 Java 枚举 `enums.WxMpApiUrl.OAuth2` 为准:
//! - OAUTH2_ACCESS_TOKEN_URL → /sns/oauth2/access_token?appid=%s&secret=%s&code=%s&grant_type=authorization_code
//! - OAUTH2_REFRESH_TOKEN_URL → /sns/oauth2/refresh_token?appid=%s&grant_type=refresh_token&refresh_token=%s
//! - OAUTH2_USERINFO_URL     → /sns/userinfo?access_token=%s&openid=%s&lang=%s
//! - OAUTH2_VALIDATE_TOKEN_URL → /sns/auth?access_token=%s&openid=%s
//! - CONNECT_OAUTH2_AUTHORIZE_URL → https://open.weixin.qq.com/connect/oauth2/authorize?appid=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s&connect_redirect=1#wechat_redirect
//!
//! 全部走 `Service.executeNoToken`(网页授权 token 与 API token 无关,与 Java 一致)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 对应 Java `open.weixin` 主域。
pub const open_host_url = "https://open.weixin.qq.com";

/// OAuth2 access token —— 对应 Java `common.bean.oauth2.WxOAuth2AccessToken`
/// (全部 gpa 拥有;expires_in 以 -1 表示接口未返回)。
pub const OauthAccessToken = struct {
    gpa: std.mem.Allocator,
    access_token: []const u8 = "",
    expires_in: i64 = -1,
    refresh_token: []const u8 = "",
    openid: []const u8 = "",
    scope: []const u8 = "",
    unionid: []const u8 = "",

    pub fn deinit(self: *OauthAccessToken) void {
        const g = self.gpa;
        g.free(@constCast(self.access_token));
        g.free(@constCast(self.refresh_token));
        g.free(@constCast(self.openid));
        g.free(@constCast(self.scope));
        g.free(@constCast(self.unionid));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !OauthAccessToken {
        var t = OauthAccessToken{
            .gpa = gpa,
            .access_token = try gpa.dupe(u8, json_util.getStrOr(v, "access_token", "")),
            .refresh_token = try gpa.dupe(u8, json_util.getStrOr(v, "refresh_token", "")),
            .openid = try gpa.dupe(u8, json_util.getStrOr(v, "openid", "")),
            .scope = try gpa.dupe(u8, json_util.getStrOr(v, "scope", "")),
            .unionid = try gpa.dupe(u8, json_util.getStrOr(v, "unionid", "")),
        };
        t.expires_in = json_util.getInt(v, "expires_in") orelse -1;
        return t;
    }
};

/// 网页授权用户信息 —— 对应 Java `common.bean.WxOAuth2UserInfo`
/// (全部 gpa 拥有;privileges 为字符串数组)。
pub const OauthUserInfo = struct {
    gpa: std.mem.Allocator,
    openid: []const u8 = "",
    nickname: []const u8 = "",
    /// Java 侧 Integer sex 可 null,Zig 用 0 表示未知
    sex: i64 = 0,
    city: []const u8 = "",
    province: []const u8 = "",
    country: []const u8 = "",
    headimgurl: []const u8 = "",
    unionid: []const u8 = "",
    privileges: [][]u8 = &.{},

    pub fn deinit(self: *OauthUserInfo) void {
        const g = self.gpa;
        inline for (.{ self.openid, self.nickname, self.city, self.province, self.country, self.headimgurl, self.unionid }) |s| {
            g.free(@constCast(s));
        }
        for (self.privileges) |p| g.free(p);
        if (self.privileges.len > 0) g.free(self.privileges);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !OauthUserInfo {
        var r = OauthUserInfo{
            .gpa = gpa,
            .openid = try gpa.dupe(u8, json_util.getStrOr(v, "openid", "")),
            .nickname = try gpa.dupe(u8, json_util.getStrOr(v, "nickname", "")),
            .city = try gpa.dupe(u8, json_util.getStrOr(v, "city", "")),
            .province = try gpa.dupe(u8, json_util.getStrOr(v, "province", "")),
            .country = try gpa.dupe(u8, json_util.getStrOr(v, "country", "")),
            .headimgurl = try gpa.dupe(u8, json_util.getStrOr(v, "headimgurl", "")),
            .unionid = try gpa.dupe(u8, json_util.getStrOr(v, "unionid", "")),
        };
        errdefer r.deinit();
        r.sex = json_util.getInt(v, "sex") orelse 0;
        var list: std.ArrayList([]u8) = .empty;
        errdefer for (list.items) |p| gpa.free(p);
        if (json_util.getArray(v, "privilege")) |arr| {
            for (arr.items) |item| {
                if (item == .string) try list.append(gpa, try gpa.dupe(u8, item.string));
            }
        }
        r.privileges = try list.toOwnedSlice(gpa);
        return r;
    }
};

fn urlOf(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, fmt, args) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn pctEncode(gpa: std.mem.Allocator, s: []const u8) WxResult([]u8) {
    return .{ .ok = service_mod.urlEncode(gpa, s) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

/// GET 且把响应解析为 OauthAccessToken(sns 端点无错误码时按业务结构解析;
/// 错误码平台仍由 Service 折叠)。
fn tokenFromResp(svc: *service_mod.Service, io: std.Io, uri: []u8) WxResult(OauthAccessToken) {
    const gpa = svc.gpa;
    defer gpa.free(uri);
    const resp = switch (svc.executeNoToken(io, uri, &.{}, null)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    defer gpa.free(resp);
    const parsed = json_util.parse(gpa, resp) catch return .{
        .err = result_mod.WxError.transport(gpa, "oauth2 not json", .{}),
    };
    defer parsed.deinit();
    const t = OauthAccessToken.fromJson(gpa, parsed.value) catch
        return .{ .err = result_mod.WxError.transport(gpa, "oauth2 token parse failed", .{}) };
    return .{ .ok = t };
}

pub const OauthService = struct {
    svc: *service_mod.Service,

    /// 对应 `buildAuthorizationUrl(redirectUri, scope, state)`:
    /// redirect_uri 做 encodeURIComponent;state 用 trimToEmpty(空串)。
    /// 返回串 gpa 分配,调用方 free。
    pub fn buildAuthorizationUrl(self: *OauthService, redirect_uri: []const u8, scope: []const u8, state: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const enc = switch (pctEncode(gpa, redirect_uri)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(enc);
        // Java 无 state trim 差异:空串也照常拼接(线上参数),trimToEmpty 只把 null 变 ""。
        return switch (urlOf(gpa, open_host_url ++ "/connect/oauth2/authorize?appid={s}&redirect_uri={s}&response_type=code&scope={s}&state={s}&connect_redirect=1#wechat_redirect", .{ self.svc.config.appid(), enc, scope, state })) {
            .ok => |u| .{ .ok = u },
            .err => |e| .{ .err = e },
        };
    }

    /// 对应 `getAccessToken(code)`:用配置里的 appid/secret 换 code。
    pub fn getAccessToken(self: *OauthService, io: std.Io, code: []const u8) WxResult(OauthAccessToken) {
        const gpa = self.svc.gpa;
        const uri = switch (urlOf(gpa, service_mod.api_host_url ++ "sns/oauth2/access_token?appid={s}&secret={s}&code={s}&grant_type=authorization_code", .{ self.svc.config.appid(), self.svc.config.secret(), code })) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        // Java 直接sprintf(未 encode);code 通常为字母数字,保持一致。
        return tokenFromResp(self.svc, io, uri);
    }

    /// 对应 `refreshAccessToken(refreshToken)`。
    pub fn refreshAccessToken(self: *OauthService, io: std.Io, refresh_token: []const u8) WxResult(OauthAccessToken) {
        const gpa = self.svc.gpa;
        const uri = switch (urlOf(gpa, service_mod.api_host_url ++ "sns/oauth2/refresh_token?appid={s}&grant_type=refresh_token&refresh_token={s}", .{ self.svc.config.appid(), refresh_token })) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        return tokenFromResp(self.svc, io, uri);
    }

    /// 对应 `getUserInfo(token, lang)`:lang null → zh_CN。
    pub fn getUserInfo(self: *OauthService, io: std.Io, token: OauthAccessToken, lang: ?[]const u8) WxResult(OauthUserInfo) {
        const gpa = self.svc.gpa;
        const lg = lang orelse "zh_CN";
        const uri = switch (urlOf(gpa, service_mod.api_host_url ++ "sns/userinfo?access_token={s}&openid={s}&lang={s}", .{ token.access_token, token.openid, lg })) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(uri);
        const resp = switch (self.svc.executeNoToken(io, uri, &.{}, null)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "sns/userinfo not json", .{}),
        };
        defer parsed.deinit();
        const u = OauthUserInfo.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.transport(gpa, "oauth2 userinfo parse failed", .{}) };
        return .{ .ok = u };
    }

    /// 对应 `validateAccessToken(token)`:/sns/auth 请求成功(无 errcode)即 true。
    pub fn validateAccessToken(self: *OauthService, io: std.Io, token: OauthAccessToken) bool {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}sns/auth?access_token={s}&openid={s}", .{ service_mod.api_host_url, token.access_token, token.openid }) catch
            return false;
        defer gpa.free(uri);
        switch (self.svc.executeNoToken(io, uri, &.{}, null)) {
            .ok => |b| {
                gpa.free(b);
                return true;
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return false;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// 测试(沿用 user_tag/qrcode 的 stub 样板)
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

test "oauth: authorize url + access token + userinfo" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "sns/oauth2/access_token", .response = "{\"access_token\":\"AT\",\"refresh_token\":\"RT\",\"openid\":\"oX\",\"scope\":\"snsapi_userinfo\",\"expires_in\":7200,\"unionid\":\"u1\"}" },
        .{ .match = "sns/userinfo", .response = "{\"openid\":\"oX\",\"nickname\":\"昵称\",\"sex\":1,\"city\":\"C\",\"province\":\"P\",\"country\":\"CN\",\"headimgurl\":\"h\",\"privilege\":[\"p1\",\"p2\"]}" },
        .{ .match = "sns/oauth2/refresh_token", .response = "{\"access_token\":\"AT2\",\"openid\":\"oX\",\"expires_in\":7200}" },
        .{ .match = "sns/auth", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "wxAPP", .secret = "SEC" });
    defer cfg.deinit();

    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var oauth = OauthService{ .svc = &svc };

    // 授权跳转 url:appid / encode(redirect_uri) / scope / state
    {
        const r = oauth.buildAuthorizationUrl("https://a.b/cb?x=1", "snsapi_userinfo", "s1");
        switch (r) {
            .ok => |u| {
                defer gpa.free(@constCast(u));
                try testing.expect(std.mem.indexOf(u8, u, "https://open.weixin.qq.com/connect/oauth2/authorize?appid=wxAPP&") != null);
                try testing.expect(std.mem.indexOf(u8, u, "redirect_uri=https%3A%2F%2Fa.b%2Fcb%3Fx%3D1&response_type=code") != null);
                try testing.expect(std.mem.indexOf(u8, u, "scope=snsapi_userinfo&state=s1&connect_redirect=1#wechat_redirect") != null);
            },
            .err => return error.Unexpected,
        }
    }

    // getAccessToken(code)
    var tok: OauthAccessToken = undefined;
    switch (oauth.getAccessToken(io, "CODE")) {
        .ok => |*t| tok = t.*,
        .err => return error.Unexpected,
    }
    defer tok.deinit();
    try testing.expectEqualStrings("AT", tok.access_token);
    try testing.expectEqual(@as(i64, 7200), tok.expires_in);
    try testing.expectEqualStrings("oX", tok.openid);
    try testing.expectEqualStrings("u1", tok.unionid);

    // getUserInfo:默认 lang=zh_CN;privileges 解析
    switch (oauth.getUserInfo(io, tok, null)) {
        .ok => |*up| {
            var u = up.*;
            defer u.deinit();
            try testing.expectEqualStrings("昵称", u.nickname);
            try testing.expectEqual(@as(usize, 2), u.privileges.len);
            try testing.expectEqualStrings("p2", u.privileges[1]);
        },
        .err => return error.Unexpected,
    }

    // refreshAccessToken
    {
        const r = oauth.refreshAccessToken(io, "RT");
        switch (r) {
            .ok => |*t| {
                var t2 = t.*;
                defer t2.deinit();
                try testing.expectEqualStrings("AT2", t2.access_token);
            },
            .err => return error.Unexpected,
        }
    }

    // validateAccessToken:errcode 0 → true
    try testing.expect(oauth.validateAccessToken(io, tok) == true);
}
