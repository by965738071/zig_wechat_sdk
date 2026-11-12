//! 用户黑名单服务 —— 对应 Java `api.WxMpUserBlacklistService` +
//! `api.impl.WxMpUserBlacklistServiceImpl`,端点常量取自 `enums.WxMpApiUrl.UserBlacklist`。
//!
//! 样板见 `services/user.zig`(组合 parent Service、拼 uri → svc.post → 解析 JSON → WxResult)。
//! 逐字对照 Java impl:
//! - getBlacklist:     POST /cgi-bin/tags/members/getblacklist      {"begin_openid":..}
//!   → WxMpUserBlacklistGetResult{total,count,data.openid[],next_openid}
//! - pushToBlacklist:  POST /cgi-bin/tags/members/batchblacklist    {"openid_list":[..]} → void
//! - pullFromBlacklist:POST /cgi-bin/tags/members/batchunblacklist  {"openid_list":[..]} → void
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 黑名单列表结果 —— 微信官方响应 {total,count,data:{openid:[...]},next_openid}
/// (口径同 `user.zig#Followers`;Java `WxMpUserBlacklistGetResult` 的 total/count/
/// openidList/nextOpenid 由 WxMpGsonBuilder 映射自同一份响应)。全部 gpa 拥有,用毕 deinit。
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

    /// 对应 `WxMpUserBlacklistServiceImpl#getBlacklist(nextOpenid)`。
    /// Java impl: `jsonObject.addProperty("begin_openid", nextOpenid)` —— 字段名逐字一致。
    pub fn getBlacklist(self: *UserBlacklistService, io: std.Io, next_openid: []const u8) WxResult(Blacklist) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("begin_openid", next_openid) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.blacklist_get.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "getblacklist not json", .{}),
        };
        defer parsed.deinit();
        const r = Blacklist.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.transport(gpa, "getblacklist parse failed", .{}),
        };
        return .{ .ok = r };
    }

    /// 对应 `pushToBlacklist(openidList)`:Java impl `map.put("openid_list", openidList)`。
    pub fn pushToBlacklist(self: *UserBlacklistService, io: std.Io, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = h.strArrayBody(gpa, "openid_list", openids) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.blacklist_batch.asUri(), body);
    }

    /// 对应 `pullFromBlacklist(openidList)`:Java impl 同样 `{"openid_list":[...]}`。
    pub fn pullFromBlacklist(self: *UserBlacklistService, io: std.Io, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = h.strArrayBody(gpa, "openid_list", openids) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.blacklist_unbatch.asUri(), body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:URL / HTTP 方法 / 请求体 / 响应字段,逐字对照
// WxMpApiUrl.UserBlacklist 常量 + WxMpUserBlacklistServiceImpl + 微信响应字段
// (test resources 无同名 JSON fixture,故用 Java 源码里明确的字段名/常量断言)
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
