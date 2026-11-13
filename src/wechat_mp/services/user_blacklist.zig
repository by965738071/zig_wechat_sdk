//! 用户黑名单服务 —— 逐字对齐 Java `api.WxMpUserBlacklistService`(3 方法)+
//! `api.impl.WxMpUserBlacklistServiceImpl`。方法名沿用 Java 的 camelCase(rule 2)。
//!
//! 底座(rule 3):所有 URL 路径来自 `../api_url.zig:UserBlacklist`,经 `api()`(=
//! `api_url.url(Host.api, path)`)拼绝对 URL;移除旧 `service.zig:ApiUrl.*` 用法。
//! 三方法均为「无 query 的 POST」,不涉及手工 query 组包;Service.execute* 统一注入
//! access_token 并折叠 errcode(Java `execute(SimplePostRequestExecutor,..)` 亦经
//! `executeInternal` 注入 token,见 BaseWxMpServiceImpl:432)。
//!
//! 逐字对照 Java impl:
//!   getBlacklist:      POST cgi-bin/tags/members/getblacklist {"begin_openid":..}
//!                      → WxMpUserBlacklistGetResult{total,count,data.openid[],next_openid};
//!   pushToBlacklist:   POST cgi-bin/tags/members/batchblacklist   {"openid_list":[..]} → void;
//!   pullFromBlacklist: POST cgi-bin/tags/members/batchunblacklist {"openid_list":[..]} → void。
//!
//! 内存所有权(全部 gpa 拥有):`Blacklist` 用 `deinit()`;`.err` 用 `WxError.deinit()`。
//! `h.strArrayBody` 仅复用 sub_util 的纯 JSON 组包助手(无 URL 逻辑)。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;

const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

// 复用 strArrayBody + 离线测试脚手架(Recorder/Fixture)

/// host+path 绝对 URL,路径取自 `api_url.zig:UserBlacklist`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 Service 折叠为 .err)。
fn postVoid(self: *UserBlacklistService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (self.svc.post(io, api(path), &.{}, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

/// 黑名单列表结果 —— 微信官方响应 {total,count,data:{openid:[...]},next_openid},
/// 对应 Java `WxMpUserBlacklistGetResult`(total/count/openidList/nextOpenid 由
/// WxMpGsonBuilder 映射自同一份响应)。全部 gpa 拥有,用毕 deinit。
pub const Blacklist = struct {
    gpa: std.mem.Allocator,
    total: i64 = 0,
    count: i64 = 0,
    openids: [][]u8 = &.{},
    next_openid: []const u8 = "",

    pub fn deinit(self: *Blacklist) void {
        const g = self.gpa;
        for (self.openids) |o| g.free(o);
        if (self.openids.len > 0) g.free(self.openids);
        g.free(@constCast(self.next_openid));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !Blacklist {
        var r = Blacklist{ .gpa = gpa };
        errdefer r.deinit();
        r.total = json_util.getIntOr(v, "total", 0);
        r.count = json_util.getIntOr(v, "count", 0);
        r.next_openid = try gpa.dupe(u8, json_util.getStrOr(v, "next_openid", ""));

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |o| gpa.free(o);
            list.deinit(gpa);
        }
        if (json_util.objectOf(v, "data")) |d| {
            if (d.get("openid")) |oi| {
                if (oi == .array) for (oi.array.items) |s| {
                    if (s == .string) try list.append(gpa, try gpa.dupe(u8, s.string));
                };
            }
        }
        r.openids = try list.toOwnedSlice(gpa);
        return r;
    }
};

pub const UserBlacklistService = struct {
    svc: *service_mod.Service,

    /// `WxMpUserBlacklistServiceImpl#getBlacklist(nextOpenid)` (接口 :24 / impl :26-32)。
    /// Java `jsonObject.addProperty("begin_openid", nextOpenid)` —— 字段名逐字一致。
    /// POST getblacklist → 解析 WxMpUserBlacklistGetResult.fromJson。
    pub fn getBlacklist(self: *UserBlacklistService, io: std.Io, next_openid: []const u8) WxResult(Blacklist) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("begin_openid", next_openid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, api(api_url.UserBlacklist.getblacklist), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getblacklist not json", .{}),
        };
        defer parsed.deinit();
        const r = Blacklist.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.transport(gpa, "getblacklist parse failed", .{}),
        };
        return .{ .ok = r };
    }

    /// `pushToBlacklist(openidList)` (接口 :35 / impl :35-40):Java `map.put("openid_list", list)`。
    /// POST batchblacklist {"openid_list":[..]} → void(Done)。
    pub fn pushToBlacklist(self: *UserBlacklistService, io: std.Io, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = h.strArrayBody(gpa, "openid_list", openids) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserBlacklist.batchblacklist, body);
    }

    /// `pullFromBlacklist(openidList)` (接口 :46 / impl :43-48):同样 {"openid_list":[..]}。
    /// POST batchunblacklist → void(Done)。
    pub fn pullFromBlacklist(self: *UserBlacklistService, io: std.Io, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = h.strArrayBody(gpa, "openid_list", openids) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserBlacklist.batchunblacklist, body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:URL / HTTP 方法 / 请求体 / 响应字段,逐字对照
// WxMpApiUrl.UserBlacklist 常量 + WxMpUserBlacklistServiceImpl + 微信响应字段
// ---------------------------------------------------------------------------

test "UserBlacklist 契约: 3 端点 URL/method/请求体/响应字段 (WxMpApiUrl.UserBlacklist)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getblacklist", .response = "{\"total\":3,\"count\":2,\"data\":{\"openid\":[\"o1\",\"o2\"]},\"next_openid\":\"o2\"}" },
        .{ .match = "batchblacklist", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "batchunblacklist", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = UserBlacklistService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // GETBLACKLIST: POST /cgi-bin/tags/members/getblacklist {"begin_openid":..}
    // 响应 total/count/data.openid[]/next_openid(Java bean 的 total/count 明确)。
    switch (svc.getBlacklist(io, "NEXT")) {
        .ok => |*r| {
            var b = r.*;
            defer b.deinit();
            try testing.expectEqual(@as(i64, 3), b.total);
            try testing.expectEqual(@as(i64, 2), b.count);
            try testing.expectEqual(@as(usize, 2), b.openids.len);
            try testing.expectEqualStrings("o1", b.openids[0]);
            try testing.expectEqualStrings("o2", b.openids[1]);
            try testing.expectEqualStrings("o2", b.next_openid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedBlacklistGet;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/tags/members/getblacklist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"begin_openid\":\"NEXT\"") != null);

    // BATCHBLACKLIST: POST /cgi-bin/tags/members/batchblacklist {"openid_list":[..]}
    const ids = [_][]const u8{ "o1", "o2" };
    switch (svc.pushToBlacklist(io, &ids)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedBatchBlacklist;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/tags/members/batchblacklist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"o1\",\"o2\"]") != null);

    // BATCHUNBLACKLIST: POST /cgi-bin/tags/members/batchunblacklist {"openid_list":[..]}
    const ids2 = [_][]const u8{"o9"};
    switch (svc.pullFromBlacklist(io, &ids2)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedBatchUnblacklist;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/tags/members/batchunblacklist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"o9\"]") != null);
}

// 追加:空 openid 列表 + errcode!=0 折叠为 .err(Java 抛 WxErrorException)。
test "UserBlacklist: 空列表请求体 + errcode 折叠" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "batchblacklist", .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = UserBlacklistService{ .svc = &fx.svc };

    switch (svc.pushToBlacklist(fx.threaded.io(), &.{})) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40003), err.error_code);
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[]") != null);
}
