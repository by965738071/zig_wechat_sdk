//! 开放接口(限额/rid)服务 —— 对应 Java `api.WxMaOpenApiService` +
//! `api.impl.WxMaOpenApiServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.OpenApi`:
//! - clearQuota:POST /cgi-bin/clear_quota(带 token,body {appid});
//! - getApiQuota:POST /cgi-bin/openapi/quota/get,body {cgi_path};
//! - getRidInfo:POST /cgi-bin/openapi/rid/get,body {rid}(响应取 request 子对象);
//! - clearQuotaByAppSecret:POST /cgi-bin/clear_quota/v2?appid=&appsecret=(无 token)。
//! errcode≠0 已由基座折叠为 `.err`;clearQuota/clearQuotaByAppSecret 成功返回 Done。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const CLEAR_QUOTA = "https://api.weixin.qq.com/cgi-bin/clear_quota";
const GET_API_QUOTA = "https://api.weixin.qq.com/cgi-bin/openapi/quota/get";
const GET_RID_INFO = "https://api.weixin.qq.com/cgi-bin/openapi/rid/get";
const CLEAR_QUOTA_BY_APP_SECRET = "https://api.weixin.qq.com/cgi-bin/clear_quota/v2";

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMiniGetApiQuotaResult`(quota/rateLimit/componentRateLimit 的 dailyLimit
/// 等关键数值;骨架取 dailyLimit/used/remain)。gpa 拥有。
pub const ApiQuota = struct {
    daily_limit: ?i64,
    used: ?i64,
    remain: ?i64,
};

/// 对应 `WxMiniGetRidInfoResult`(request 子对象的 6 个字段)。gpa 拥有。
pub const RidInfo = struct {
    gpa: std.mem.Allocator,
    invoke_time: ?i64,
    cost_in_ms: ?i64,
    request_url: ?[]const u8,
    request_body: ?[]const u8,
    response_body: ?[]const u8,
    client_ip: ?[]const u8,

    pub fn deinit(self: *RidInfo) void {
        const g = self.gpa;
        if (self.request_url) |s| g.free(@constCast(s));
        if (self.request_body) |s| g.free(@constCast(s));
        if (self.response_body) |s| g.free(@constCast(s));
        if (self.client_ip) |s| g.free(@constCast(s));
    }

    /// 允许从 `const` 借用值上释放(仅释放 gpa 拥有的字符串字段)。
    pub fn deinitConst(self: *const RidInfo) void {
        const g = self.gpa;
        if (self.request_url) |s| g.free(s);
        if (self.request_body) |s| g.free(s);
        if (self.response_body) |s| g.free(s);
        if (self.client_ip) |s| g.free(s);
    }
};

pub const OpenApiService = struct {
    svc: *mp_service.Service,

    /// 对应 `clearQuota()`:POST /cgi-bin/clear_quota。
    pub fn clearQuota(self: *OpenApiService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"appid\":\"{s}\"}}", .{self.svc.config.appid()}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, CLEAR_QUOTA, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getApiQuota(cgiPath)`:POST /cgi-bin/openapi/quota/get。
    pub fn getApiQuota(self: *OpenApiService, io: std.Io, cgi_path: []const u8) WxResult(ApiQuota) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"cgi_path\":\"{s}\"}}", .{cgi_path}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_API_QUOTA, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{ .err = WxError.transport(gpa, "quota not json", .{}) };
        defer parsed.deinit();
        const quota = json_util.getObject(parsed.value, "quota");
        const v = quota orelse parsed.value;
        return .{ .ok = .{
            .daily_limit = json_util.getInt(v, "dailyLimit"),
            .used = json_util.getInt(v, "used"),
            .remain = json_util.getInt(v, "remain"),
        } };
    }

    /// 对应 `getRidInfo(rid)`:POST /cgi-bin/openapi/rid/get;响应取 request 子对象。
    pub fn getRidInfo(self: *OpenApiService, io: std.Io, rid: []const u8) WxResult(?RidInfo) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"rid\":\"{s}\"}}", .{rid}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_RID_INFO, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{ .err = WxError.transport(gpa, "rid not json", .{}) };
        defer parsed.deinit();
        const reqobj = json_util.getObject(parsed.value, "request") orelse return .{ .ok = null };
        const ru = if (json_util.getStr(reqobj, "requestUrl")) |s| gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } else null;
        const rb = if (json_util.getStr(reqobj, "requestBody")) |s| gpa.dupe(u8, s) catch {
            if (ru) |r| gpa.free(@constCast(r));
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        } else null;
        const rrb = if (json_util.getStr(reqobj, "responseBody")) |s| gpa.dupe(u8, s) catch {
            if (ru) |r| gpa.free(@constCast(r));
            if (rb) |r| gpa.free(@constCast(r));
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        } else null;
        const ci = if (json_util.getStr(reqobj, "clientIp")) |s| gpa.dupe(u8, s) catch {
            if (ru) |r| gpa.free(@constCast(r));
            if (rb) |r| gpa.free(@constCast(r));
            if (rrb) |r| gpa.free(@constCast(r));
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        } else null;
        return .{ .ok = .{
            .gpa = gpa,
            .invoke_time = json_util.getInt(reqobj, "invokeTime"),
            .cost_in_ms = json_util.getInt(reqobj, "costInMs"),
            .request_url = ru,
            .request_body = rb,
            .response_body = rrb,
            .client_ip = ci,
        } };
    }

    /// 对应 `clearQuotaByAppSecret()`:POST /cgi-bin/clear_quota/v2?appid=&appsecret=(无 token)。
    pub fn clearQuotaByAppSecret(self: *OpenApiService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const url = std.fmt.allocPrint(gpa, "{s}?appid={s}&appsecret={s}", .{
            CLEAR_QUOTA_BY_APP_SECRET,
            self.svc.config.appid(),
            self.svc.config.secret(),
        }) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(url);
        // 无 token 通道:POST 空 body(Java `service.post(url, "")` 的等价;null 会被当 GET,
        // 故显式空串体保持 POST 语义)。
        const resp = switch (self.svc.executeNoToken(io, url, &.{}, "")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "openapi clearQuota: post {appid} + Done" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "clear_quota", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OpenApiService{ .svc = &base };

    const r = s.clearQuota(io);
    try std.testing.expect(!r.failed());
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("MA", json_util.getStr(parsed.value, "appid").?);
}

test "openapi getApiQuota: parse quota.dailyLimit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "openapi/quota/get", .response = "{\"errcode\":0,\"quota\":{\"dailyLimit\":100,\"used\":3,\"remain\":97}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OpenApiService{ .svc = &base };

    const q = switch (s.getApiQuota(io, "wxa/getwxacodeunlimit")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    try std.testing.expectEqual(@as(?i64, 100), q.daily_limit);
    try std.testing.expectEqual(@as(?i64, 97), q.remain);
}

test "openapi getRidInfo: parse request sub-object" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "openapi/rid/get", .response = "{\"errcode\":0,\"request\":{\"invokeTime\":5,\"costInMs\":12,\"clientIp\":\"1.2.3.4\"}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OpenApiService{ .svc = &base };

    const r = switch (s.getRidInfo(io, "RID1")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    if (r) |ri| {
        try std.testing.expectEqual(@as(?i64, 5), ri.invoke_time);
        try std.testing.expectEqualStrings("1.2.3.4", ri.client_ip.?);
    } else return error.ExpectedRid;
    if (r) |ri| ri.deinitConst();
}

test "openapi clearQuotaByAppSecret: no-token URL with appid+secret" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "clear_quota/v2", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OpenApiService{ .svc = &base };

    const r = s.clearQuotaByAppSecret(io);
    try std.testing.expect(!r.failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "clear_quota/v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "appid=MA") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "appsecret=MS") != null);
    // 无 token 通道:不带 access_token
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=") == null);
}
