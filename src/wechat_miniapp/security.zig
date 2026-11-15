//! 安全服务 —— 对应 Java `api.WxMaSecurityService` + `api.impl.WxMaSecurityServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.SecCheck`:
//! - checkMessage:POST /wxa/msg_sec_check(简式 {"content"} / 全量 typed 请求);
//! - mediaCheckAsync:POST /wxa/media_check_async(简式 / 全量 typed 请求);
//! - getUserRiskRank:POST /wxa/getuserriskrank;
//! - checkImage / uploadResponseImage 等 multipart 上传接口未实现
//!   (mp http 层 multipart 执行器为 TODO,见 wechat_mp/http.zig 头注)。
//! errcode≠0 已由基座折叠为 `.err`;detail 数组保留原始 JSON 字符串。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const MSG_SEC_CHECK_URL = "https://api.weixin.qq.com/wxa/msg_sec_check";
const MEDIA_CHECK_ASYNC_URL = "https://api.weixin.qq.com/wxa/media_check_async";
const GET_USER_RISK_RANK_URL = "https://api.weixin.qq.com/wxa/getuserriskrank";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn jsInt(w: *std.Io.Writer, v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try w.writeAll(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `security.WxMaMsgSecCheckCheckRequest`(version 为字符串)。
pub const MsgSecCheckRequest = struct {
    version: []const u8,
    openid: []const u8,
    scene: i64,
    content: []const u8,
    nickname: ?[]const u8 = null,
    title: ?[]const u8 = null,
    signature: ?[]const u8 = null,

    pub fn to_json(self: MsgSecCheckRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"version\":");
        try js(w, self.version);
        try w.writeAll(",\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"scene\":");
        try jsInt(w, self.scene);
        try w.writeAll(",\"content\":");
        try js(w, self.content);
        if (self.nickname) |s| {
            try w.writeAll(",\"nickname\":");
            try js(w, s);
        }
        if (self.title) |s| {
            try w.writeAll(",\"title\":");
            try js(w, s);
        }
        if (self.signature) |s| {
            try w.writeAll(",\"signature\":");
            try js(w, s);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `security.WxMaMediaSecCheckCheckRequest`(version 为数值)。
pub const MediaSecCheckRequest = struct {
    media_url: []const u8,
    media_type: i64,
    version: i64,
    openid: []const u8,
    scene: i64,

    pub fn to_json(self: MediaSecCheckRequest, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{{\"media_url\":\"{s}\",\"media_type\":{d},\"version\":{d},\"openid\":\"{s}\",\"scene\":{d}}}", .{
            self.media_url, self.media_type, self.version, self.openid, self.scene,
        });
    }
};

/// 对应 `WxMaMsgSecCheckCheckResponse` / `WxMaMediaAsyncCheckResult`
/// (两 bean 字段完全一致:result/trace_id/detail;detail 保留原始 JSON)。gpa 拥有。
pub const SecCheckResponse = struct {
    gpa: std.mem.Allocator,
    /// result.suggest:risky/pass/review。
    suggest: ?[]const u8,
    /// result.label:风险分类 id。
    label: ?[]const u8,
    trace_id: ?[]const u8,
    /// detail 数组的原始 JSON 文本(策略明细,字段多且版本不稳,交由调用方解析)。
    detail: ?[]const u8,

    pub fn deinit(self: *SecCheckResponse) void {
        const g = self.gpa;
        if (self.suggest) |s| g.free(@constCast(s));
        if (self.label) |s| g.free(@constCast(s));
        if (self.trace_id) |s| g.free(@constCast(s));
        if (self.detail) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const SecCheckResponse) void {
        const g = self.gpa;
        if (self.suggest) |s| g.free(s);
        if (self.label) |s| g.free(s);
        if (self.trace_id) |s| g.free(s);
        if (self.detail) |s| g.free(s);
    }
};

fn parseSecCheckResponse(gpa: std.mem.Allocator, v: json_util.Value) !SecCheckResponse {
    var out = SecCheckResponse{ .gpa = gpa, .suggest = null, .label = null, .trace_id = null, .detail = null };
    if (json_util.getObject(v, "result")) |res| {
        if (json_util.getStr(res, "suggest")) |s| out.suggest = try gpa.dupe(u8, s);
        if (json_util.getStr(res, "label")) |s| out.label = try gpa.dupe(u8, s);
    }
    if (json_util.getStr(v, "trace_id")) |s| out.trace_id = try gpa.dupe(u8, s);
    if (json_util.getArray(v, "detail")) |arr| {
        // 保留原始 JSON 文本(std.json.Value 重新序列化)。
        out.detail = try json_util.stringify(gpa, json_util.Value{ .array = arr });
    }
    return out;
}

/// 对应 `safety.request.WxMaUserSafetyRiskRankRequest`。
pub const UserRiskRankRequest = struct {
    appid: []const u8,
    openid: []const u8,
    scene: i64,
    mobile_no: ?[]const u8 = null,
    client_ip: ?[]const u8 = null,
    email_address: ?[]const u8 = null,
    extended_info: ?[]const u8 = null,
    is_test: ?bool = null,

    pub fn to_json(self: UserRiskRankRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"appid\":");
        try js(w, self.appid);
        try w.writeAll(",\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"scene\":");
        try jsInt(w, self.scene);
        if (self.mobile_no) |s| {
            try w.writeAll(",\"mobile_no\":");
            try js(w, s);
        }
        if (self.client_ip) |s| {
            try w.writeAll(",\"client_ip\":");
            try js(w, s);
        }
        if (self.email_address) |s| {
            try w.writeAll(",\"email_address\":");
            try js(w, s);
        }
        if (self.extended_info) |s| {
            try w.writeAll(",\"extended_info\":");
            try js(w, s);
        }
        if (self.is_test) |b| {
            try w.writeAll(",\"is_test\":");
            try w.writeAll(if (b) "true" else "false");
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `safety.response.WxMaUserSafetyRiskRankResponse`
/// (注意微信官方字段名就是 unoin_id,非 union_id)。gpa 拥有。
pub const UserRiskRank = struct {
    gpa: std.mem.Allocator,
    unoin_id: ?i64,
    risk_rank: ?i64,

    pub fn deinit(self: *UserRiskRank) void {
        _ = self;
    }

    pub fn deinitConst(self: *const UserRiskRank) void {
        _ = self;
    }
};

// --- service -------------------------------------------------------------------

pub const SecurityService = struct {
    svc: *mp_service.Service,

    /// 对应 `checkImage(File)`/`checkImage(String)`:**multipart 上传未实现**
    /// (mp http 层 multipart 执行器为 TODO)。
    /// 对应 `checkMessage(String)`:POST /wxa/msg_sec_check {"content":...},
    /// 成功即 Done(Java 返回 true)。
    pub fn checkMessage(self: *SecurityService, io: std.Io, content: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"content\":\"{s}\"}}", .{content}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, MSG_SEC_CHECK_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `checkMessage(WxMaMsgSecCheckCheckRequest)`:全量 typed 请求
    /// → result{suggest,label} + trace_id + detail。
    pub fn checkMessageFull(self: *SecurityService, io: std.Io, req: MsgSecCheckRequest) WxResult(SecCheckResponse) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, MSG_SEC_CHECK_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "msg_sec_check not json", .{}) };
        defer parsed.deinit();
        const out = parseSecCheckResponse(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "msg_sec_check parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `mediaCheckAsync(mediaUrl, mediaType)` 简式:
    /// POST /wxa/media_check_async {"media_url":...,"media_type":N}。
    pub fn mediaCheckAsync(self: *SecurityService, io: std.Io, media_url: []const u8, media_type: i64) WxResult(SecCheckResponse) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"media_url\":\"{s}\",\"media_type\":{d}}}", .{ media_url, media_type }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, MEDIA_CHECK_ASYNC_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "media_check_async not json", .{}) };
        defer parsed.deinit();
        const out = parseSecCheckResponse(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "media_check_async parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `mediaCheckAsync(WxMaMediaSecCheckCheckRequest)`:全量 typed 请求。
    pub fn mediaCheckAsyncFull(self: *SecurityService, io: std.Io, req: MediaSecCheckRequest) WxResult(SecCheckResponse) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, MEDIA_CHECK_ASYNC_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "media_check_async not json", .{}) };
        defer parsed.deinit();
        const out = parseSecCheckResponse(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "media_check_async parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getUserRiskRank(WxMaUserSafetyRiskRankRequest)`:
    /// POST /wxa/getuserriskrank → unoin_id/risk_rank。
    pub fn getUserRiskRank(self: *SecurityService, io: std.Io, req: UserRiskRankRequest) WxResult(UserRiskRank) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_USER_RISK_RANK_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getuserriskrank not json", .{}) };
        defer parsed.deinit();
        return .{
            .ok = .{
                .gpa = gpa,
                // 官方字段名 unoin_id(非 union_id),与 Java bean 对齐。
                .unoin_id = json_util.getInt(parsed.value, "unoin_id"),
                .risk_rank = json_util.getInt(parsed.value, "risk_rank"),
            },
        };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "security checkMessage: simple + full" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "msg_sec_check", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"result\":{\"suggest\":\"risky\",\"label\":\"100\"},\"trace_id\":\"tr1\",\"detail\":[{\"strategy\":\"content_model\",\"errcode\":0,\"suggest\":\"risky\",\"label\":100,\"prob\":90}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SecurityService{ .svc = &base };

    // 简式:{"content":...} → Done
    try std.testing.expect(!s.checkMessage(io, "hello world").failed());
    try std.testing.expectEqualStrings("{\"content\":\"hello world\"}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/msg_sec_check") != null);

    // 全量:typed 请求 → result/trace_id/detail
    const r = switch (s.checkMessageFull(io, .{
        .version = "2",
        .openid = "oX",
        .scene = 1,
        .content = "txt",
        .nickname = "nick",
        .title = "t",
        .signature = "sig",
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var rv = r;
    defer rv.deinit();
    try std.testing.expectEqualStrings("risky", rv.suggest.?);
    try std.testing.expectEqualStrings("100", rv.label.?);
    try std.testing.expectEqualStrings("tr1", rv.trace_id.?);
    try std.testing.expect(std.mem.indexOf(u8, rv.detail.?, "content_model") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2", json_util.getStr(parsed.value, "version").?);
    try std.testing.expectEqual(@as(?i64, 1), json_util.getInt(parsed.value, "scene"));
    try std.testing.expectEqualStrings("nick", json_util.getStr(parsed.value, "nickname").?);
}

test "security mediaCheckAsync: simple + full" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "media_check_async", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"trace_id\":\"tr2\",\"result\":{\"suggest\":\"pass\",\"label\":\"0\"},\"detail\":[]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SecurityService{ .svc = &base };

    // 简式
    const r1 = switch (s.mediaCheckAsync(io, "https://img.example.com/a.png", 2)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var r1v = r1;
    defer r1v.deinit();
    try std.testing.expectEqualStrings("tr2", r1v.trace_id.?);
    try std.testing.expectEqualStrings("pass", r1v.suggest.?);
    try std.testing.expectEqualStrings("{\"media_url\":\"https://img.example.com/a.png\",\"media_type\":2}", m.last_body);

    // 全量(version 为数值)
    const r2 = switch (s.mediaCheckAsyncFull(io, .{
        .media_url = "https://img.example.com/b.png",
        .media_type = 2,
        .version = 2,
        .openid = "oX",
        .scene = 3,
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var r2v = r2;
    defer r2v.deinit();
    try std.testing.expectEqualStrings("tr2", r2v.trace_id.?);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?i64, 2), json_util.getInt(parsed.value, "version"));
    try std.testing.expectEqual(@as(?i64, 3), json_util.getInt(parsed.value, "scene"));
}

test "security getUserRiskRank: unoin_id typo field" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getuserriskrank", .response = "{\"errcode\":0,\"unoin_id\":1,\"risk_rank\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SecurityService{ .svc = &base };

    const r = switch (s.getUserRiskRank(io, .{
        .appid = "MA",
        .openid = "oX",
        .scene = 1,
        .mobile_no = "13800000000",
        .is_test = true,
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(?i64, 1), r.unoin_id);
    try std.testing.expectEqual(@as(?i64, 0), r.risk_rank);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("MA", json_util.getStr(parsed.value, "appid").?);
    try std.testing.expectEqualStrings("13800000000", json_util.getStr(parsed.value, "mobile_no").?);
    try std.testing.expectEqual(true, json_util.getBool(parsed.value, "is_test").?);
}
