//! 营销服务 —— 对应 Java `api.WxMaMarketingService` + `api.impl.WxMaMarketingServiceImpl`。
//!
//! URL 对齐 impl 内私有常量:
//! - addUserActionSets:POST /marketing/user_action_sets/add?version=v1.0
//!   → data.user_action_set_id;
//! - addUserAction:POST /marketing/user_actions/add?version=v1.0
//!   (URL 自带 query,access_token 以 & 拼接;响应原样返回)。
//! 序列化对齐 `WxMaUserAction.listToJson`(user_action_set_id + actions 数组)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const USER_ACTION_SETS_ADD_URL = "https://api.weixin.qq.com/marketing/user_action_sets/add?version=v1.0";
const USER_ACTIONS_ADD_URL = "https://api.weixin.qq.com/marketing/user_actions/add?version=v1.0";

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

/// 对应 `marketing.WxMaUserAction`(url/action_time/action_type 必填;
/// click_id → trace.click_id;action_param_value+leads_type → action_param)。
pub const UserAction = struct {
    url: []const u8,
    action_time: i64,
    action_type: []const u8,
    click_id: ?[]const u8 = null,
    /// Java 字段 actionParam(Integer):设置时输出 action_param{"value":N}。
    action_param_value: ?i64 = null,
    leads_type: ?[]const u8 = null,

    fn writeJson(self: UserAction, w: *std.Io.Writer) !void {
        try w.writeAll("{\"url\":");
        try js(w, self.url);
        try w.writeAll(",\"action_time\":");
        try jsInt(w, self.action_time);
        try w.writeAll(",\"action_type\":");
        try js(w, self.action_type);
        if (self.click_id) |c| {
            try w.writeAll(",\"trace\":{\"click_id\":");
            try js(w, c);
            try w.writeAll("}");
        }
        if (self.action_param_value) |v| {
            try w.writeAll(",\"action_param\":{\"value\":");
            try jsInt(w, v);
            if (self.leads_type) |lt| {
                try w.writeAll(",\"leads_type\":");
                try js(w, lt);
            }
            try w.writeAll("}");
        }
        try w.writeAll("}");
    }
};

/// 对应 `WxMaUserAction.listToJson(actions, userActionSetId)`:整包请求体。
pub fn userActionsBody(gpa: std.mem.Allocator, actions: []const UserAction, user_action_set_id: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"user_action_set_id\":");
    try jsInt(w, user_action_set_id);
    try w.writeAll(",\"actions\":[");
    for (actions, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try a.writeJson(w);
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

// --- service -------------------------------------------------------------------

pub const MarketingService = struct {
    svc: *mp_service.Service,

    /// 对应 `addUserActionSets(type, name, description)`:
    /// POST /marketing/user_action_sets/add?version=v1.0 → data.user_action_set_id。
    pub fn addUserActionSets(self: *MarketingService, io: std.Io, type_: []const u8, name: []const u8, description: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"type\":\"{s}\",\"name\":\"{s}\",\"description\":\"{s}\"}}", .{ type_, name, description }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, USER_ACTION_SETS_ADD_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "user_action_sets/add not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "user_action_sets/add missing data", .{}) };
        return .{ .ok = json_util.getIntOr(data, "user_action_set_id", 0) };
    }

    /// 对应 `addUserAction(actions, userActionSetId)`:
    /// POST /marketing/user_actions/add?version=v1.0,响应原样返回
    /// (gpa 拥有,调用方 free;Java 也返回原始 String)。
    pub fn addUserAction(self: *MarketingService, io: std.Io, actions: []const UserAction, user_action_set_id: i64) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = userActionsBody(gpa, actions, user_action_set_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, USER_ACTIONS_ADD_URL, &.{}, body);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "marketing addUserActionSets: data.user_action_set_id" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "user_action_sets/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"user_action_set_id\":123456}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = MarketingService{ .svc = &base };

    const id = switch (s.addUserActionSets(io, "WEB", "测试数据源", "描述")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 123456), id);
    // URL 自带 ?version=v1.0 → access_token 以 & 拼接
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "user_action_sets/add?version=v1.0&access_token=TOK") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("WEB", json_util.getStr(parsed.value, "type").?);
    try std.testing.expectEqualStrings("测试数据源", json_util.getStr(parsed.value, "name").?);
}

test "marketing addUserAction: listToJson body shape" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "user_actions/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = MarketingService{ .svc = &base };

    const resp = switch (s.addUserAction(io, &.{
        .{ .url = "https://example.com/landing", .action_time = 1700000000, .action_type = "REGISTER", .click_id = "CLICK1" },
        .{ .url = "https://example.com/landing", .action_time = 1700000001, .action_type = "COMPLETE_ORDER", .action_param_value = 100, .leads_type = "CONSULT" },
    }, 123456)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(resp);

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?i64, 123456), json_util.getInt(parsed.value, "user_action_set_id"));
    const actions = json_util.getArray(parsed.value, "actions").?;
    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    // 第一条:click_id → trace
    const a0 = actions.items[0];
    const trace = json_util.getObject(a0, "trace").?;
    try std.testing.expectEqualStrings("CLICK1", json_util.getStr(trace, "click_id").?);
    try std.testing.expect(json_util.getObject(a0, "action_param") == null);
    // 第二条:action_param{value,leads_type}
    const a1 = actions.items[1];
    const ap = json_util.getObject(a1, "action_param").?;
    try std.testing.expectEqual(@as(?i64, 100), json_util.getInt(ap, "value"));
    try std.testing.expectEqualStrings("CONSULT", json_util.getStr(ap, "leads_type").?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "user_actions/add?version=v1.0&access_token=TOK") != null);
}
