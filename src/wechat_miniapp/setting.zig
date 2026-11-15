//! 设置服务 —— 对应 Java `api.WxMaSettingService` + `api.impl.WxMaSettingServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Setting`:
//! - modifyDomain/setWebViewDomain:POST 域名操作 JSON,响应解析回
//!   `DomainActionResult`(action=get 时响应带五类域名列表);
//! - bindTester/unbindTester:POST {"wechatid":...}。
//! 请求侧 `DomainAction` 为借用切片(有 to_json),响应侧
//! `DomainActionResult` 为 gpa 拥有(有 deinit)—— Java 同一 bean 往返,
//! Zig 按所有权方向拆成两个类型,语义不变。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const MODIFY_DOMAIN_URL = "https://api.weixin.qq.com/wxa/modify_domain";
const SET_WEB_VIEW_DOMAIN_URL = "https://api.weixin.qq.com/wxa/setwebviewdomain";
const BIND_TESTER_URL = "https://api.weixin.qq.com/wxa/bind_tester";
const UNBIND_TESTER_URL = "https://api.weixin.qq.com/wxa/unbind_tester";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaDomainAction`(请求侧;action:add/delete/set/get,
/// get 时无需填域名字段。字段为借用切片,不持有内存)。
pub const DomainAction = struct {
    action: []const u8,
    requestdomain: ?[]const []const u8 = null,
    wsrequestdomain: ?[]const []const u8 = null,
    uploaddomain: ?[]const []const u8 = null,
    downloaddomain: ?[]const []const u8 = null,
    webviewdomain: ?[]const []const u8 = null,

    /// 对应 `WxMaDomainAction.toJson()`(Gson 序列化,null 字段省略)。
    pub fn to_json(self: DomainAction, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"action\":");
        try js(w, self.action);
        if (self.requestdomain) |list| {
            try w.writeAll(",\"requestdomain\":");
            try writeStrArray(w, list);
        }
        if (self.wsrequestdomain) |list| {
            try w.writeAll(",\"wsrequestdomain\":");
            try writeStrArray(w, list);
        }
        if (self.uploaddomain) |list| {
            try w.writeAll(",\"uploaddomain\":");
            try writeStrArray(w, list);
        }
        if (self.downloaddomain) |list| {
            try w.writeAll(",\"downloaddomain\":");
            try writeStrArray(w, list);
        }
        if (self.webviewdomain) |list| {
            try w.writeAll(",\"webviewdomain\":");
            try writeStrArray(w, list);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

fn writeStrArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try js(w, item);
    }
    try w.writeAll("]");
}

/// 对应 `WxMaDomainAction` 的响应形态(gpa 拥有;modifyDomain/setWebViewDomain 返回)。
pub const DomainActionResult = struct {
    gpa: std.mem.Allocator,
    action: ?[]const u8,
    requestdomain: ?[]const []const u8,
    wsrequestdomain: ?[]const []const u8,
    uploaddomain: ?[]const []const u8,
    downloaddomain: ?[]const []const u8,
    webviewdomain: ?[]const []const u8,

    pub fn deinit(self: *DomainActionResult) void {
        const g = self.gpa;
        if (self.action) |s| g.free(@constCast(s));
        if (self.requestdomain) |l| freeStrList(g, l);
        if (self.wsrequestdomain) |l| freeStrList(g, l);
        if (self.uploaddomain) |l| freeStrList(g, l);
        if (self.downloaddomain) |l| freeStrList(g, l);
        if (self.webviewdomain) |l| freeStrList(g, l);
    }

    pub fn deinitConst(self: *const DomainActionResult) void {
        const g = self.gpa;
        if (self.action) |s| g.free(s);
        if (self.requestdomain) |l| freeStrList(g, l);
        if (self.wsrequestdomain) |l| freeStrList(g, l);
        if (self.uploaddomain) |l| freeStrList(g, l);
        if (self.downloaddomain) |l| freeStrList(g, l);
        if (self.webviewdomain) |l| freeStrList(g, l);
    }
};

fn freeStrList(gpa: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(@constCast(s));
    gpa.free(@constCast(list));
}

fn dupeStrList(gpa: std.mem.Allocator, arr: std.ArrayList(json_util.Value)) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| gpa.free(@constCast(s));
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const s: []const u8 = switch (item) {
            .string => |str| str,
            .number_string => |str| str,
            else => "",
        };
        const d = try gpa.dupe(u8, s);
        errdefer gpa.free(@constCast(d));
        try out.append(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

fn parseDomainActionResult(gpa: std.mem.Allocator, v: json_util.Value) !DomainActionResult {
    var out = DomainActionResult{
        .gpa = gpa,
        .action = null,
        .requestdomain = null,
        .wsrequestdomain = null,
        .uploaddomain = null,
        .downloaddomain = null,
        .webviewdomain = null,
    };
    if (json_util.getStr(v, "action")) |s| {
        out.action = try gpa.dupe(u8, s);
    }
    inline for (.{ "requestdomain", "wsrequestdomain", "uploaddomain", "downloaddomain", "webviewdomain" }) |f| {
        if (json_util.getArray(v, f)) |arr| {
            @field(out, f) = try dupeStrList(gpa, arr);
        }
    }
    return out;
}

// --- service -------------------------------------------------------------------

pub const SettingService = struct {
    svc: *mp_service.Service,

    /// 对应 `modifyDomain(WxMaDomainAction)`:POST /wxa/modify_domain,
    /// 响应解析回 DomainActionResult(action=get 时带域名列表)。
    pub fn modifyDomain(self: *SettingService, io: std.Io, action: DomainAction) WxResult(DomainActionResult) {
        const gpa = self.svc.gpa;
        const body = action.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, MODIFY_DOMAIN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "modify_domain not json", .{}) };
        defer parsed.deinit();
        const out = parseDomainActionResult(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "modify_domain parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `setWebViewDomain(WxMaDomainAction)`:POST /wxa/setwebviewdomain。
    pub fn setWebViewDomain(self: *SettingService, io: std.Io, action: DomainAction) WxResult(DomainActionResult) {
        const gpa = self.svc.gpa;
        const body = action.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SET_WEB_VIEW_DOMAIN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "setwebviewdomain not json", .{}) };
        defer parsed.deinit();
        const out = parseDomainActionResult(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "setwebviewdomain parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `bindTester(wechatId)`:POST /wxa/bind_tester {"wechatid":...}。
    pub fn bindTester(self: *SettingService, io: std.Io, wechat_id: []const u8) Done {
        return self.postWechatId(io, BIND_TESTER_URL, wechat_id);
    }

    /// 对应 `unbindTester(wechatId)`:POST /wxa/unbind_tester {"wechatid":...}。
    pub fn unbindTester(self: *SettingService, io: std.Io, wechat_id: []const u8) Done {
        return self.postWechatId(io, UNBIND_TESTER_URL, wechat_id);
    }

    fn postWechatId(self: *SettingService, io: std.Io, url: []const u8, wechat_id: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"wechatid\":\"{s}\"}}", .{wechat_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
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

test "setting modifyDomain + setWebViewDomain: body shape + response parse" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "modify_domain", .response = "{\"errcode\":0,\"action\":\"get\",\"requestdomain\":[\"https://a.com\",\"https://b.com\"],\"downloaddomain\":[\"https://c.com\"]}" },
        .{ .match = "setwebviewdomain", .response = "{\"errcode\":0,\"action\":\"set\",\"webviewdomain\":[\"https://w.com\"]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SettingService{ .svc = &base };

    // modifyDomain:action=get(此时不填域名字段,对应 Java 注释)
    const r1 = switch (s.modifyDomain(io, .{ .action = "get" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var d1 = r1;
    defer d1.deinit();
    try std.testing.expectEqualStrings("{\"action\":\"get\"}", m.last_body);
    try std.testing.expectEqualStrings("get", d1.action.?);
    try std.testing.expectEqual(@as(usize, 2), d1.requestdomain.?.len);
    try std.testing.expectEqualStrings("https://a.com", d1.requestdomain.?[0]);
    try std.testing.expectEqualStrings("https://c.com", d1.downloaddomain.?[0]);

    // setWebViewDomain:带 webviewdomain 列表
    const r2 = switch (s.setWebViewDomain(io, .{ .action = "set", .webviewdomain = &.{"https://w.com"} })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var d2 = r2;
    defer d2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"webviewdomain\":[\"https://w.com\"]") != null);
    try std.testing.expectEqual(@as(usize, 1), d2.webviewdomain.?.len);
}

test "setting bindTester + unbindTester" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "bind_tester", .response = "{\"errcode\":0}" },
        .{ .match = "unbind_tester", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SettingService{ .svc = &base };

    try std.testing.expect(!s.bindTester(io, "wxid_abc").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/bind_tester") != null);
    try std.testing.expectEqualStrings("{\"wechatid\":\"wxid_abc\"}", m.last_body);

    try std.testing.expect(!s.unbindTester(io, "wxid_abc").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/unbind_tester") != null);
    try std.testing.expectEqualStrings("{\"wechatid\":\"wxid_abc\"}", m.last_body);
}
