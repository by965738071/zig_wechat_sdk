//! 小程序链接服务(URL Link + URL Scheme)—— 对应 Java `api.WxMaLinkService`
//! (`api.impl.WxMaLinkServiceImpl`)与 `api.WxMaSchemeService`
//! (`api.impl.WxMaSchemeServiceImpl`,任务书合并进本文件)。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Link/.Scheme`(以 Java 为准):
//! - GENERATE_URLLINK_URL = https://api.weixin.qq.com/wxa/generate_urllink
//! - QUERY_URLLINK_URL    = https://api.weixin.qq.com/wxa/query_urllink
//! - GENERATE_SCHEME_URL  = https://api.weixin.qq.com/wxa/generatescheme
//! - /wxa/queryscheme     —— 当前 Java 工程**没有**该接口(任务书增补),
//!   线格式按微信官方文档实现,见 `query_scheme`。
//!
//! 请求线格式对齐 `bean.urllink.GenerateUrlLinkRequest` /
//! `bean.urllink.request.QueryUrlLinkRequest` / `bean.scheme.WxMaGenerateSchemeRequest`
//! (Gson `@SerializedName` → snake_case;`cloud_base` 嵌套对象超出任务书范围未收录)。
//! 注意:scheme 生成成功读取的是 **openlink**(Java `jsonObject.get("openlink")`,
//! 任务书口述的 open_link 为转写误差)。
//! 返回值所有权:返回的字符串/结构体字段均为 gpa 分配,调用方按 doc 释放。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
const WxError = error_mod.WxError;

/// 解析类内部错误(统一折叠为 WxError 对外)。
const ParseError = error{ BadJson, BadItem, OutOfMemory };

// --- URL(对应 WxMaApiUrlConstants.Link/.Scheme) --------------------------------

const GENERATE_URLLINK_URL = "https://api.weixin.qq.com/wxa/generate_urllink";
const QUERY_URLLINK_URL = "https://api.weixin.qq.com/wxa/query_urllink";
const GENERATE_SCHEME_URL = "https://api.weixin.qq.com/wxa/generatescheme";
/// 任务书增补:当前 Java 工程无此常量(官方文档 /wxa/queryscheme)。
const QUERY_SCHEME_URL = "https://api.weixin.qq.com/wxa/queryscheme";

/// 对应 Java bean 默认 `envVersion = "release"`。
pub const DEFAULT_ENV_VERSION = "release";

/// 写一个 JSON 字符串字面量(带引号与转义;对应 Gson 的 addProperty)。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn fold(gpa: std.mem.Allocator, ctx: []const u8, e: anyerror) WxError {
    return WxError.transport(gpa, "{s}: {s}", .{ ctx, @errorName(e) });
}

// --- bean ---------------------------------------------------------------------

/// 对应 `bean.urllink.GenerateUrlLinkRequest`(包装类型 null → Gson 省略;
/// `cloud_base` 未收录)。
pub const GenerateUrlLinkRequest = struct {
    path: ?[]const u8 = null,
    query: ?[]const u8 = null,
    env_version: []const u8 = DEFAULT_ENV_VERSION,
    is_expire: ?bool = null,
    expire_type: ?i64 = null,
    expire_time: ?i64 = null,
    expire_interval: ?i64 = null,

    pub fn to_json(self: GenerateUrlLinkRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.path) |v| {
            try w.print("{s}\"path\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.query) |v| {
            try w.print("{s}\"query\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        try w.print("{s}\"env_version\":", .{sep});
        try js(w, self.env_version);
        if (self.is_expire) |v| {
            try w.print(",\"is_expire\":{s}", .{if (v) "true" else "false"});
        }
        if (self.expire_type) |v| try w.print(",\"expire_type\":{d}", .{v});
        if (self.expire_time) |v| try w.print(",\"expire_time\":{d}", .{v});
        if (self.expire_interval) |v| try w.print(",\"expire_interval\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `bean.urllink.request.QueryUrlLinkRequest`。
pub const QueryUrlLinkRequest = struct { url_link: []const u8 };

/// 对应 `QueryUrlLinkResponse.UrlLinkInfo`(字符串均 gpa 拥有)。
pub const UrlLinkInfo = struct {
    appid: []const u8,
    path: []const u8,
    query: []const u8,
    create_time: i64,
    expire_time: i64,
    env_version: []const u8,

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) ParseError!UrlLinkInfo {
        var info = UrlLinkInfo{
            .appid = try gpa.dupe(u8, json_util.getStrOr(v, "appid", "")),
            .path = try gpa.dupe(u8, json_util.getStrOr(v, "path", "")),
            .query = try gpa.dupe(u8, json_util.getStrOr(v, "query", "")),
            .create_time = json_util.getIntOr(v, "create_time", 0),
            .expire_time = json_util.getIntOr(v, "expire_time", 0),
            .env_version = "",
        };
        errdefer {
            var x = info;
            x.free(gpa);
        }
        info.env_version = try gpa.dupe(u8, json_util.getStrOr(v, "env_version", ""));
        return info;
    }

    fn free(self: *UrlLinkInfo, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.appid));
        gpa.free(@constCast(self.path));
        gpa.free(@constCast(self.query));
        gpa.free(@constCast(self.env_version));
    }
};

/// 对应 `bean.urllink.response.QueryUrlLinkResponse`
/// (父类 `WxMaBaseResponse` 的 errcode 已由服务基座折叠,不重复收录)。
pub const QueryUrlLinkResponse = struct {
    visit_openid: []const u8,
    url_link_info: ?UrlLinkInfo,

    pub fn free(self: *QueryUrlLinkResponse, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.visit_openid));
        if (self.url_link_info) |*info| info.free(gpa);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) ParseError!QueryUrlLinkResponse {
        var res = QueryUrlLinkResponse{
            .visit_openid = try gpa.dupe(u8, json_util.getStrOr(v, "visit_openid", "")),
            .url_link_info = null,
        };
        errdefer res.free(gpa);
        if (json_util.objectOf(v, "url_link_info")) |o| {
            res.url_link_info = try UrlLinkInfo.fromJson(gpa, json_util.Value{ .object = o });
        }
        return res;
    }
};

/// 对应 `bean.scheme.WxMaGenerateSchemeRequest`(is_expire/expire_time 为
/// Java 的可选包装字段;NFC scheme 变体超出任务书范围)。
pub const GenerateSchemeRequest = struct {
    pub const JumpWxa = struct {
        path: ?[]const u8 = null,
        query: ?[]const u8 = null,
        env_version: []const u8 = DEFAULT_ENV_VERSION,
    };
    jump_wxa: ?JumpWxa = null,
    is_expire: ?bool = null,
    expire_time: ?i64 = null,
    /// 对应 Java 字段 `expireType`(`@SerializedName("expire_type")`)。
    expire_type: ?i64 = null,
    expire_interval: ?i64 = null,

    pub fn to_json(self: GenerateSchemeRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.jump_wxa) |j| {
            try w.writeAll("\"jump_wxa\":{");
            var sep2: []const u8 = "";
            if (j.path) |v| {
                try w.print("{s}\"path\":", .{sep2});
                try js(w, v);
                sep2 = ",";
            }
            if (j.query) |v| {
                try w.print("{s}\"query\":", .{sep2});
                try js(w, v);
                sep2 = ",";
            }
            try w.print("{s}\"env_version\":", .{sep2});
            try js(w, j.env_version);
            try w.writeByte('}');
            sep = ",";
        }
        if (self.is_expire) |v| {
            try w.print("{s}\"is_expire\":{s}", .{ sep, if (v) "true" else "false" });
            sep = ",";
        }
        if (self.expire_time) |v| {
            try w.print("{s}\"expire_time\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.expire_type) |v| {
            try w.print("{s}\"expire_type\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.expire_interval) |v| {
            try w.print("{s}\"expire_interval\":{d}", .{ sep, v });
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `query_scheme` 响应的 `scheme_info`(任务书增补接口;字段按官方文档,
/// gpa 拥有)。
pub const SchemeInfo = struct {
    visit_url: []const u8,
    appid: []const u8,
    path: []const u8,
    query: []const u8,
    expire_time: i64,

    pub fn free(self: *SchemeInfo, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.visit_url));
        gpa.free(@constCast(self.appid));
        gpa.free(@constCast(self.path));
        gpa.free(@constCast(self.query));
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) ParseError!SchemeInfo {
        const info = SchemeInfo{
            .visit_url = try gpa.dupe(u8, json_util.getStrOr(v, "visit_url", "")),
            .appid = try gpa.dupe(u8, json_util.getStrOr(v, "appid", "")),
            .path = try gpa.dupe(u8, json_util.getStrOr(v, "path", "")),
            .query = try gpa.dupe(u8, json_util.getStrOr(v, "query", "")),
            .expire_time = json_util.getIntOr(v, "expire_time", 0),
        };
        errdefer {
            var x = info;
            x.free(gpa);
        }
        return info;
    }
};

// --- service ------------------------------------------------------------------

/// 链接服务 —— 组合在服务基座上(对应 Java 子服务持 `WxMaService` 引用的组合方式;
/// Java 的 `generateShortLink` 超出任务书范围未收录)。
pub const LinkService = struct {
    svc: *mp_service.Service,

    /// 对应 `generateUrlLink(GenerateUrlLinkRequest)`:
    /// POST /wxa/generate_urllink → `url_link` 字段。
    /// 返回串归 gpa 所有(调用方 `gpa.free`);缺字段对应 Java `WxErrorException("无url_link")`。
    pub fn generate_url_link(self: *LinkService, io: std.Io, req: GenerateUrlLinkRequest) WxResult([]const u8) {
        return self.postForString(io, GENERATE_URLLINK_URL, req, "url_link", "无url_link");
    }

    /// 对应 `queryUrlLink(QueryUrlLinkRequest)`:
    /// POST /wxa/query_urllink {url_link} → `QueryUrlLinkResponse`。
    /// 返回结构字段归 gpa 所有,用 `QueryUrlLinkResponse.free` 释放。
    pub fn query_url_link(self: *LinkService, io: std.Io, req: QueryUrlLinkRequest) WxResult(QueryUrlLinkResponse) {
        const g = self.svc.gpa;
        var body = json_util.ObjectBuilder.init(g);
        defer body.deinit();
        body.putStr("url_link", req.url_link) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        const payload = body.toJson() catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(payload);

        const resp = switch (self.svc.post(io, QUERY_URLLINK_URL, &.{}, payload)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const parsed = json_util.parse(g, resp) catch return .{
            .err = WxError.transport(g, "query url link not json", .{}),
        };
        defer parsed.deinit();
        const res = QueryUrlLinkResponse.fromJson(g, parsed.value) catch |e| return .{
            .err = fold(g, "query url link", e),
        };
        return .{ .ok = res };
    }

    /// 对应 `WxMaSchemeService.generate(WxMaGenerateSchemeRequest)`:
    /// POST /wxa/generatescheme → `openlink` 字段(Java 读 openlink,非 open_link)。
    /// 返回串归 gpa 所有(调用方 `gpa.free`)。
    pub fn generate_scheme(self: *LinkService, io: std.Io, req: GenerateSchemeRequest) WxResult([]const u8) {
        return self.postForString(io, GENERATE_SCHEME_URL, req, "openlink", "无openlink");
    }

    /// 任务书增补(当前 Java 工程无此接口):POST /wxa/queryscheme {scheme}
    /// → `scheme_info`。返回结构字段归 gpa 所有,用 `SchemeInfo.free` 释放。
    pub fn query_scheme(self: *LinkService, io: std.Io, scheme: []const u8) WxResult(SchemeInfo) {
        const g = self.svc.gpa;
        var body = json_util.ObjectBuilder.init(g);
        defer body.deinit();
        body.putStr("scheme", scheme) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        const payload = body.toJson() catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(payload);

        const resp = switch (self.svc.post(io, QUERY_SCHEME_URL, &.{}, payload)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const parsed = json_util.parse(g, resp) catch return .{
            .err = WxError.transport(g, "query scheme not json", .{}),
        };
        defer parsed.deinit();
        const o = json_util.objectOf(parsed.value, "scheme_info") orelse return .{
            .err = WxError.internal(g, "无scheme_info", .{}),
        };
        const info = SchemeInfo.fromJson(g, json_util.Value{ .object = o }) catch |e| return .{
            .err = fold(g, "query scheme", e),
        };
        return .{ .ok = info };
    }

    /// POST 请求体 → 解析响应里的字符串字段(对应 Java「GsonParser.parse →
    /// get(field).getAsString,缺字段抛 WxErrorException(String)」模式)。
    fn postForString(self: *LinkService, io: std.Io, url: []const u8, req: anytype, field: []const u8, missing_msg: []const u8) WxResult([]const u8) {
        const g = self.svc.gpa;
        const body = req.to_json(g) catch |e| return .{ .err = fold(g, "link build body", e) };
        defer g.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const parsed = json_util.parse(g, resp) catch return .{
            .err = WxError.transport(g, "link response not json", .{}),
        };
        defer parsed.deinit();
        const s = json_util.getStr(parsed.value, field) orelse return .{
            .err = WxError.internal(g, "{s}", .{missing_msg}),
        };
        return .{ .ok = g.dupe(u8, s) catch return .{ .err = WxError.transport(g, "oom", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + body + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "generate_url_link: post shape + parse url_link" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "generate_urllink", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url_link\":\"https://wxaurl.cn/abc\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    const link = switch (s.generate_url_link(io, .{
        .path = "pages/index",
        .query = "a=1",
        .is_expire = true,
        .expire_type = 1,
        .expire_interval = 7,
    })) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(link);
    try std.testing.expectEqualStrings("https://wxaurl.cn/abc", link);

    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/generate_urllink") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("pages/index", json_util.getStr(parsed.value, "path").?);
    try std.testing.expectEqualStrings("a=1", json_util.getStr(parsed.value, "query").?);
    try std.testing.expectEqualStrings("release", json_util.getStr(parsed.value, "env_version").?);
    try std.testing.expectEqual(@as(?bool, true), json_util.getBool(parsed.value, "is_expire"));
    try std.testing.expectEqual(@as(i64, 1), json_util.getInt(parsed.value, "expire_type").?);
    try std.testing.expectEqual(@as(i64, 7), json_util.getInt(parsed.value, "expire_interval").?);
}

test "generate_url_link: errcode!=0 -> WxError" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "generate_urllink", .response = "{\"errcode\":45166,\"errmsg\":\"reach max daily url link generate limit\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    switch (s.generate_url_link(io, .{})) {
        .ok => |v| {
            gpa.free(v);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 45166), err.error_code);
        },
    }
}

test "generate_url_link: missing url_link field -> internal error(对应 Java WxErrorException(\"无url_link\"))" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "generate_urllink", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    switch (s.generate_url_link(io, .{})) {
        .ok => |v| {
            gpa.free(v);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, -99), err.error_code);
            try std.testing.expectEqualStrings("无url_link", err.error_msg);
        },
    }
}

test "query_url_link: body + parse response" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "wxa/query_urllink", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"visit_openid\":\"oV\",\"url_link_info\":{\"appid\":\"APP\",\"path\":\"pages/i\",\"query\":\"q=2\",\"create_time\":1600000000,\"expire_time\":1600086400,\"env_version\":\"release\"}}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    var res = switch (s.query_url_link(io, .{ .url_link = "https://wxaurl.cn/abc" })) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer res.free(gpa);
    try std.testing.expectEqualStrings("oV", res.visit_openid);
    const info = res.url_link_info.?;
    try std.testing.expectEqualStrings("APP", info.appid);
    try std.testing.expectEqualStrings("pages/i", info.path);
    try std.testing.expectEqual(@as(i64, 1600000000), info.create_time);
    try std.testing.expectEqual(@as(i64, 1600086400), info.expire_time);

    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/query_urllink") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://wxaurl.cn/abc", json_util.getStr(parsed.value, "url_link").?);
}

test "generate_scheme: jump_wxa body + openlink; errcode!=0" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "wxa/generatescheme", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openlink\":\"weixin://dl/business/?t=XYZ\"}" },
        .{ .match = "wxa/queryscheme", .response = "{\"errcode\":47001,\"errmsg\":\"json format error\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    const link = switch (s.generate_scheme(io, .{
        .jump_wxa = .{ .path = "pages/index", .query = "a=1", .env_version = "trial" },
        .expire_type = 0,
        .expire_interval = 1,
    })) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(link);
    try std.testing.expectEqualStrings("weixin://dl/business/?t=XYZ", link);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/generatescheme") != null);

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    const jw = json_util.objectOf(parsed.value, "jump_wxa").?;
    try std.testing.expectEqualStrings("pages/index", json_util.getStr(.{ .object = jw }, "path").?);
    try std.testing.expectEqualStrings("a=1", json_util.getStr(.{ .object = jw }, "query").?);
    try std.testing.expectEqualStrings("trial", json_util.getStr(.{ .object = jw }, "env_version").?);
    try std.testing.expectEqual(@as(i64, 0), json_util.getInt(parsed.value, "expire_type").?);
    try std.testing.expectEqual(@as(i64, 1), json_util.getInt(parsed.value, "expire_interval").?);

    // query_scheme errcode!=0 → WxError(每服务 errcode!=0 用例)
    switch (s.query_scheme(io, "weixin://dl/business/?t=XYZ")) {
        .ok => |v| {
            var info = v;
            info.free(gpa);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 47001), err.error_code);
        },
    }
}

test "query_scheme: body + parse scheme_info" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "wxa/queryscheme", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"scheme_info\":{\"visit_url\":\"weixin://dl/business/?t=XYZ\",\"appid\":\"APP\",\"path\":\"pages/i\",\"query\":\"q=1\",\"expire_time\":1600086400}}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LinkService{ .svc = &base };

    var info = switch (s.query_scheme(io, "weixin://dl/business/?t=XYZ")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer info.free(gpa);
    try std.testing.expectEqualStrings("weixin://dl/business/?t=XYZ", info.visit_url);
    try std.testing.expectEqualStrings("APP", info.appid);
    try std.testing.expectEqual(@as(i64, 1600086400), info.expire_time);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/queryscheme") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("weixin://dl/business/?t=XYZ", json_util.getStr(parsed.value, "scheme").?);
}
