//! 插件管理服务 —— 对应 Java `api.WxMaPluginService` + `api.impl.WxMaPluginServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Plugin`:四接口共用 POST /wxa/plugin,
//! 靠 body 里 action 字段区分(apply/list/unbind/update)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const PLUGIN_URL = "https://api.weixin.qq.com/wxa/plugin";

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaPluginListResult.PluginItem`(getPluginList 元素)。gpa 拥有。
pub const PluginItem = struct {
    gpa: std.mem.Allocator,
    appid: ?[]const u8,
    status: ?[]const u8,
    nickname: ?[]const u8,
    headimgurl: ?[]const u8,

    pub fn deinit(self: *PluginItem) void {
        const g = self.gpa;
        if (self.appid) |s| g.free(@constCast(s));
        if (self.status) |s| g.free(@constCast(s));
        if (self.nickname) |s| g.free(@constCast(s));
        if (self.headimgurl) |s| g.free(@constCast(s));
    }
};

/// 对应 `WxMaPluginListResult`。gpa 拥有。
pub const PluginListResult = struct {
    gpa: std.mem.Allocator,
    plugin_list: []PluginItem,

    pub fn deinit(self: *PluginListResult) void {
        for (self.plugin_list) |*it| it.deinit();
        self.gpa.free(self.plugin_list);
    }
};

fn parsePluginItem(gpa: std.mem.Allocator, v: json_util.Value) !PluginItem {
    return .{
        .gpa = gpa,
        .appid = if (json_util.getStr(v, "appid")) |s| try gpa.dupe(u8, s) else null,
        .status = if (json_util.getStr(v, "status")) |s| try gpa.dupe(u8, s) else null,
        .nickname = if (json_util.getStr(v, "nickname")) |s| try gpa.dupe(u8, s) else null,
        .headimgurl = if (json_util.getStr(v, "headimgurl")) |s| try gpa.dupe(u8, s) else null,
    };
}

// --- service -------------------------------------------------------------------

pub const PluginService = struct {
    svc: *mp_service.Service,

    /// 对应 `applyPlugin(pluginAppId, reason)`:
    /// POST /wxa/plugin {"action":"apply","plugin_appid":...,"reason":...}。
    pub fn applyPlugin(self: *PluginService, io: std.Io, plugin_appid: []const u8, reason: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"action\":\"apply\",\"plugin_appid\":\"{s}\",\"reason\":\"{s}\"}}", .{ plugin_appid, reason }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, PLUGIN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getPluginList()`:POST /wxa/plugin {"action":"list"}
    /// → plugin_list[]{appid,status,nickname,headimgurl}。
    pub fn getPluginList(self: *PluginService, io: std.Io) WxResult(PluginListResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, PLUGIN_URL, &.{}, "{\"action\":\"list\"}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "plugin list not json", .{}) };
        defer parsed.deinit();
        var out = std.ArrayList(PluginItem).empty;
        errdefer {
            for (out.items) |*it| it.deinit();
            out.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "plugin_list")) |arr| {
            for (arr.items) |item| {
                const it = parsePluginItem(gpa, item) catch
                    return .{ .err = WxError.transport(gpa, "plugin item parse failed", .{}) };
                out.append(gpa, it) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        const owned = out.toOwnedSlice(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .plugin_list = owned } };
    }

    /// 对应 `unbindPlugin(pluginAppId)`:
    /// POST /wxa/plugin {"action":"unbind","plugin_appid":...}。
    pub fn unbindPlugin(self: *PluginService, io: std.Io, plugin_appid: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"action\":\"unbind\",\"plugin_appid\":\"{s}\"}}", .{plugin_appid}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, PLUGIN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `updatePlugin(pluginAppId, userVersion)`:
    /// POST /wxa/plugin {"action":"update","plugin_appid":...,"user_version":...}。
    pub fn updatePlugin(self: *PluginService, io: std.Io, plugin_appid: []const u8, user_version: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"action\":\"update\",\"plugin_appid\":\"{s}\",\"user_version\":\"{s}\"}}", .{ plugin_appid, user_version }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, PLUGIN_URL, &.{}, body)) {
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

test "plugin apply/list/unbind/update: shared url + action body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        // 四接口共用 URL,URI 无法区分;统一返回带 plugin_list 的响应:
        // Done 型接口只看 errcode(基座已折叠),list 型额外解析 plugin_list。
        .{ .match = "/wxa/plugin", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"plugin_list\":[{\"appid\":\"wxplug1\",\"status\":1,\"nickname\":\"插件A\",\"headimgurl\":\"http://h/1.png\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = PluginService{ .svc = &base };

    // apply
    try std.testing.expect(!s.applyPlugin(io, "wxplug1", "want feature").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"action\":\"apply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"plugin_appid\":\"wxplug1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"reason\":\"want feature\"") != null);

    // list(同一响应中解析 plugin_list)
    const r = switch (s.getPluginList(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var list = r;
    defer list.deinit();
    try std.testing.expectEqualStrings("{\"action\":\"list\"}", m.last_body);
    try std.testing.expectEqual(@as(usize, 1), list.plugin_list.len);
    try std.testing.expectEqualStrings("wxplug1", list.plugin_list[0].appid.?);
    try std.testing.expectEqualStrings("插件A", list.plugin_list[0].nickname.?);

    // unbind
    try std.testing.expect(!s.unbindPlugin(io, "wxplug1").failed());
    try std.testing.expectEqualStrings("{\"action\":\"unbind\",\"plugin_appid\":\"wxplug1\"}", m.last_body);

    // update
    try std.testing.expect(!s.updatePlugin(io, "wxplug1", "1.0.2").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"action\":\"update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"user_version\":\"1.0.2\"") != null);
}
