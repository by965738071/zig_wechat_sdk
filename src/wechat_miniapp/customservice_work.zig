//! 微信客服(企业绑定)服务 —— 对应 Java `api.WxMaCustomserviceWorkService` +
//! `api.impl.WxMaCustomserviceWorkServiceImpl`。
//!
//! URL 对齐(常量声明在 Java 接口 `WxMaCustomserviceWorkService` 上):
//! - getCustomservice:GET /customservice/work/get(Java 用 get,非 post);
//! - bindCustomservice:POST /customservice/work/bind {corpid};
//! - unbindCustomservice:POST /customservice/work/unbind {corpid}。
//!
//! 绑定的企业ID需和小程序主体一致;目前仅支持绑定非个人小程序。
//! errcode≠0 已由基座折叠为 `.err`;Java 的 errcode 载荷字段不再保留。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_CUSTOMSERVICE_URL = "https://api.weixin.qq.com/customservice/work/get";
const BIND_CUSTOMSERVICE_URL = "https://api.weixin.qq.com/customservice/work/bind";
const UNBIND_CUSTOMSERVICE_URL = "https://api.weixin.qq.com/customservice/work/unbind";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean -----------------------------------------------------------------------

/// 对应 `customservice.WxMaCustomserviceResult`。
/// 注意:JSON 键与 Java 一致 —— `entityName`/`corpid`/`bindTime` 为微信原样
/// 大小写(bindTime 为驼峰,非下划线)。gpa 拥有。
pub const CustomserviceResult = struct {
    gpa: std.mem.Allocator,
    /// 小程序主体名称,未绑定时不返回。
    entity_name: ?[]const u8,
    /// 企业ID,未绑定时不返回。
    corpid: ?[]const u8,
    /// 接受绑定时间戳(ms)。
    bind_time: ?i64,

    pub fn deinit(self: *CustomserviceResult) void {
        const g = self.gpa;
        if (self.entity_name) |v| g.free(@constCast(v));
        if (self.corpid) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    /// 解析响应体(errcode≠0 已由基座折叠,这里只解业务字段)。
    fn parse(gpa: std.mem.Allocator, resp: []const u8) WxResult(CustomserviceResult) {
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "customservice result not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;

        var out = CustomserviceResult{ .gpa = gpa, .entity_name = null, .corpid = null, .bind_time = null };
        if (json_util.getStr(v, "entityName")) |name| {
            out.entity_name = gpa.dupe(u8, name) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (json_util.getStr(v, "corpid")) |corpid| {
            out.corpid = gpa.dupe(u8, corpid) catch {
                out.deinit();
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        out.bind_time = json_util.getInt(v, "bindTime");
        return .{ .ok = out };
    }
};

// --- service ----------------------------------------------------------------------

pub const CustomserviceWorkService = struct {
    svc: *mp_service.Service,

    /// 对应 `getCustomservice()`:GET /customservice/work/get。
    pub fn getCustomservice(self: *CustomserviceWorkService, io: std.Io) WxResult(CustomserviceResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_CUSTOMSERVICE_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return CustomserviceResult.parse(gpa, resp);
    }

    /// 对应 `bindCustomservice(String corpid)`:POST /customservice/work/bind {corpid}。
    pub fn bindCustomservice(self: *CustomserviceWorkService, io: std.Io, corpid: []const u8) WxResult(CustomserviceResult) {
        return self.corpidPost(io, BIND_CUSTOMSERVICE_URL, corpid);
    }

    /// 对应 `unbindCustomservice(String corpid)`:POST /customservice/work/unbind {corpid}。
    pub fn unbindCustomservice(self: *CustomserviceWorkService, io: std.Io, corpid: []const u8) WxResult(CustomserviceResult) {
        return self.corpidPost(io, UNBIND_CUSTOMSERVICE_URL, corpid);
    }

    // 内部:bind/unbind 共用(POST {corpid})。
    fn corpidPost(self: *CustomserviceWorkService, io: std.Io, url: []const u8, corpid: []const u8) WxResult(CustomserviceResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"corpid\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, corpid) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return CustomserviceResult.parse(gpa, resp);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "customservice work get/bind/unbind" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "customservice/work/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"entityName\":\"主体A\",\"corpid\":\"ww1234567890\",\"bindTime\":1737000000000}" },
        .{ .match = "customservice/work/bind", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"entityName\":\"主体A\",\"corpid\":\"ww1234567890\",\"bindTime\":1737000000000}" },
        .{ .match = "customservice/work/unbind", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"entityName\":\"主体A\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CustomserviceWorkService{ .svc = &base };

    // get:GET → entityName/corpid/bindTime(注意 bindTime 为驼峰键)
    var got = switch (s.getCustomservice(io)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "customservice/work/get") != null);
    try std.testing.expectEqualStrings("主体A", got.entity_name.?);
    try std.testing.expectEqualStrings("ww1234567890", got.corpid.?);
    try std.testing.expectEqual(@as(i64, 1737000000000), got.bind_time.?);

    // bind:POST {corpid}
    var bound = switch (s.bindCustomservice(io, "ww1234567890")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer bound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "customservice/work/bind") != null);
    try std.testing.expectEqualStrings("{\"corpid\":\"ww1234567890\"}", m.last_body);
    try std.testing.expectEqualStrings("ww1234567890", bound.corpid.?);

    // unbind:POST {corpid},响应未绑定字段不返回(null)
    var unbound = switch (s.unbindCustomservice(io, "ww1234567890")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer unbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "customservice/work/unbind") != null);
    try std.testing.expectEqualStrings("{\"corpid\":\"ww1234567890\"}", m.last_body);
    try std.testing.expect(unbound.corpid == null);
    try std.testing.expect(unbound.bind_time == null);
}
