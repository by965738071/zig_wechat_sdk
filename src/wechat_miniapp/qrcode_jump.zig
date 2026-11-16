//! 扫码打开小程序个性化规则(二维码跳转)服务 —— 对应 Java
//! `api.WxMaQrcodeJumpService` + `api.impl.WxMaQrcodeJumpServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.QrcodeJump`(/wxaapi/wxaqrcodefast/):
//! - addRule:POST addcategoryrule(规则对象序列化,响应原样返回);
//! - getRules:POST getcategory {is_default?,prefix?}(null 省略)→ rule_list;
//! - getRuleList:POST getcategorybypage {get_type?,page_num?,page_size?}
//!   (null 省略)→ rule_list;
//! - deleteRule:POST deletecategoryrule {prefix}(响应原样返回)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const ADD_RULE_URL = "https://api.weixin.qq.com/wxaapi/wxaqrcodefast/addcategoryrule";
const GET_RULES_URL = "https://api.weixin.qq.com/wxaapi/wxaqrcodefast/getcategory";
const GET_RULE_LIST_URL = "https://api.weixin.qq.com/wxaapi/wxaqrcodefast/getcategorybypage";
const DELETE_RULE_URL = "https://api.weixin.qq.com/wxaapi/wxaqrcodefast/deletecategoryrule";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `qrcode.WxMaQrcodeJumpWxaItem`(appid/path),请求侧常量引用。
pub const QrcodeJumpWxaItem = struct {
    appid: []const u8,
    path: []const u8,
};

/// 对应 `qrcode.WxMaQrcodeJumpRule`(prefix/permit_sub_rule/open_version/path/
/// debug_wxa_info/is_expire)。null 字段省略输出,等价 Gson 默认策略。
pub const QrcodeJumpRuleRequest = struct {
    prefix: []const u8,
    permit_sub_rule: ?bool = null,
    open_version: ?i64 = null,
    path: []const u8,
    debug_wxa_info: ?[]const QrcodeJumpWxaItem = null,
    is_expire: ?bool = null,

    pub fn to_json(self: QrcodeJumpRuleRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"prefix\":");
        try js(w, self.prefix);
        if (self.permit_sub_rule) |v| try w.print(",\"permit_sub_rule\":{}", .{v});
        if (self.open_version) |v| try w.print(",\"open_version\":{d}", .{v});
        try w.writeAll(",\"path\":");
        try js(w, self.path);
        if (self.debug_wxa_info) |items| {
            try w.writeAll(",\"debug_wxa_info\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"appid\":");
                try js(w, item.appid);
                try w.writeAll(",\"path\":");
                try js(w, item.path);
                try w.writeAll("}");
            }
            try w.writeAll("]");
        }
        if (self.is_expire) |v| try w.print(",\"is_expire\":{}", .{v});
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 响应侧规则(gpa 拥有,deinit 释放全部字符串)。
pub const QrcodeJumpRule = struct {
    gpa: std.mem.Allocator,
    prefix: ?[]const u8,
    permit_sub_rule: ?bool,
    open_version: ?i64,
    path: ?[]const u8,
    debug_wxa_info: ?[]DebugWxaItem,
    is_expire: ?bool,

    pub const DebugWxaItem = struct {
        appid: ?[]const u8,
        path: ?[]const u8,
    };

    pub fn deinit(self: *QrcodeJumpRule) void {
        const g = self.gpa;
        if (self.prefix) |s| g.free(@constCast(s));
        if (self.path) |s| g.free(@constCast(s));
        if (self.debug_wxa_info) |items| {
            for (items) |item| {
                if (item.appid) |s| g.free(@constCast(s));
                if (item.path) |s| g.free(@constCast(s));
            }
            g.free(items);
        }
    }

    pub fn deinitConst(self: *const QrcodeJumpRule) void {
        const g = self.gpa;
        if (self.prefix) |s| g.free(s);
        if (self.path) |s| g.free(s);
        if (self.debug_wxa_info) |items| {
            for (items) |item| {
                if (item.appid) |s| g.free(s);
                if (item.path) |s| g.free(s);
            }
            g.free(items);
        }
    }
};

fn deinitRules(gpa: std.mem.Allocator, rules: []QrcodeJumpRule) void {
    for (rules) |*r| r.deinit();
    gpa.free(rules);
}

// --- service -------------------------------------------------------------------

pub const QrcodeJumpService = struct {
    svc: *mp_service.Service,

    /// 对应 `addRule(WxMaQrcodeJumpRule)`:POST addcategoryrule,
    /// 响应原样返回(gpa 拥有,调用方 free;Java 返回原始 String)。
    pub fn addRule(self: *QrcodeJumpService, io: std.Io, rule: QrcodeJumpRuleRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = rule.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, ADD_RULE_URL, &.{}, body);
    }

    /// 对应 `getRules(Boolean isDefault, String prefix)`:POST getcategory
    /// {is_default?,prefix?}(null 省略)→ 解析 rule_list。
    pub fn getRules(self: *QrcodeJumpService, io: std.Io, is_default: ?bool, prefix: ?[]const u8) WxResult([]QrcodeJumpRule) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var first = true;
        if (is_default) |v| {
            w.print("\"is_default\":{}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            first = false;
        }
        if (prefix) |p| {
            if (!first) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.writeAll("\"prefix\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, p) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_RULES_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseRules(gpa, resp);
    }

    /// 对应 `getRuleList(Integer getType, Integer pageNum, Integer pageSize)`:
    /// POST getcategorybypage {get_type?,page_num?,page_size?}(null 省略)
    /// → 解析 rule_list。
    pub fn getRuleList(self: *QrcodeJumpService, io: std.Io, get_type: ?i64, page_num: ?i64, page_size: ?i64) WxResult([]QrcodeJumpRule) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var first = true;
        if (get_type) |v| {
            w.print("\"get_type\":{d}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            first = false;
        }
        if (page_num) |v| {
            if (!first) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print("\"page_num\":{d}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            first = false;
        }
        if (page_size) |v| {
            if (!first) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print("\"page_size\":{d}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_RULE_LIST_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseRules(gpa, resp);
    }

    /// 对应 `deleteRule(String prefix)`:POST deletecategoryrule {prefix},
    /// 响应原样返回(gpa 拥有,调用方 free;Java 返回原始 String)。
    pub fn deleteRule(self: *QrcodeJumpService, io: std.Io, prefix: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"prefix\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, prefix) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, DELETE_RULE_URL, &.{}, body);
    }
};

// 内部:解析 rule_list → []QrcodeJumpRule(gpa 拥有)。
fn parseRules(gpa: std.mem.Allocator, resp: []const u8) WxResult([]QrcodeJumpRule) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "qrcode jump rules not json", .{}) };
    defer parsed.deinit();
    const arr = json_util.getArray(parsed.value, "rule_list") orelse
        return .{ .ok = &[_]QrcodeJumpRule{} };
    const rules = gpa.alloc(QrcodeJumpRule, arr.items.len) catch
        return .{ .err = WxError.internal(gpa, "oom", .{}) };
    var filled: usize = 0;
    errdefer {
        for (rules[0..filled]) |*r| r.deinit();
        gpa.free(rules);
    }
    for (arr.items) |item| {
        rules[filled] = parseRule(gpa, item) catch {
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        filled += 1;
    }
    return .{ .ok = rules };
}

// 内部:解析单个规则(gpa 拥有全部子字符串)。
fn parseRule(gpa: std.mem.Allocator, obj: std.json.Value) !QrcodeJumpRule {
    var rule = QrcodeJumpRule{
        .gpa = gpa,
        .prefix = null,
        .permit_sub_rule = null,
        .open_version = null,
        .path = null,
        .debug_wxa_info = null,
        .is_expire = null,
    };
    errdefer rule.deinit();
    if (json_util.getStr(obj, "prefix")) |s| rule.prefix = try gpa.dupe(u8, s);
    rule.permit_sub_rule = json_util.getBool(obj, "permit_sub_rule");
    rule.open_version = json_util.getInt(obj, "open_version");
    if (json_util.getStr(obj, "path")) |s| rule.path = try gpa.dupe(u8, s);
    rule.is_expire = json_util.getBool(obj, "is_expire");
    if (json_util.getArray(obj, "debug_wxa_info")) |items| {
        const arr = try gpa.alloc(QrcodeJumpRule.DebugWxaItem, items.items.len);
        var n: usize = 0;
        errdefer {
            for (arr[0..n]) |it| {
                if (it.appid) |s| gpa.free(@constCast(s));
                if (it.path) |s| gpa.free(@constCast(s));
            }
            gpa.free(arr);
        }
        for (items.items) |item| {
            var it = QrcodeJumpRule.DebugWxaItem{ .appid = null, .path = null };
            if (json_util.getStr(item, "appid")) |s| it.appid = try gpa.dupe(u8, s);
            if (json_util.getStr(item, "path")) |s| it.path = try gpa.dupe(u8, s);
            arr[n] = it;
            n += 1;
        }
        rule.debug_wxa_info = arr;
    }
    return rule;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "qrcode jump add/get/getList/delete" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "addcategoryrule", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "getcategorybypage", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"rule_list\":[{\"prefix\":\"p2\",\"permit_sub_rule\":false,\"open_version\":2,\"path\":\"/two\",\"debug_wxa_info\":[{\"appid\":\"wx2\",\"path\":\"/dbg2\"}],\"is_expire\":true}]}" },
        .{ .match = "getcategory", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"rule_list\":[{\"prefix\":\"p1\",\"permit_sub_rule\":true,\"open_version\":1,\"path\":\"/one\",\"is_expire\":false},{\"prefix\":\"p0\",\"path\":\"/zero\"}]}" },
        .{ .match = "deletecategoryrule", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeJumpService{ .svc = &base };

    // addRule:规则序列化(null 省略)
    const added = switch (s.addRule(io, .{ .prefix = "p1", .path = "/one", .open_version = 1, .permit_sub_rule = true })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(added);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxaqrcodefast/addcategoryrule") != null);
    const reparse = try std.json.parseFromSlice(std.json.Value, gpa, m.last_body, .{});
    defer reparse.deinit();
    try std.testing.expectEqualStrings("p1", reparse.value.object.get("prefix").?.string);
    try std.testing.expectEqual(@as(i64, 1), reparse.value.object.get("open_version").?.integer);

    // getRules:{is_default?,prefix?} → rule_list(2 条,含省略字段)
    const rules = switch (s.getRules(io, true, "p1")) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer deinitRules(gpa, rules);
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings("p1", rules[0].prefix.?);
    try std.testing.expectEqual(true, rules[0].permit_sub_rule.?);
    try std.testing.expectEqual(@as(i64, 1), rules[0].open_version.?);
    try std.testing.expectEqualStrings("/one", rules[0].path.?);
    try std.testing.expectEqual(false, rules[0].is_expire.?);
    try std.testing.expectEqualStrings("/zero", rules[1].path.?);
    try std.testing.expect(rules[1].permit_sub_rule == null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"is_default\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"prefix\":\"p1\"") != null);

    // getRuleList:{get_type?,page_num?,page_size?} → rule_list(含 debug_wxa_info)
    const list = switch (s.getRuleList(io, 1, 2, 20)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer deinitRules(gpa, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("p2", list[0].prefix.?);
    const dbg = list[0].debug_wxa_info.?;
    try std.testing.expectEqual(@as(usize, 1), dbg.len);
    try std.testing.expectEqualStrings("wx2", dbg[0].appid.?);
    try std.testing.expectEqualStrings("/dbg2", dbg[0].path.?);
    try std.testing.expectEqualStrings("{\"get_type\":1,\"page_num\":2,\"page_size\":20}", m.last_body);

    // deleteRule:{prefix}
    const deleted = switch (s.deleteRule(io, "p1")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(deleted);
    try std.testing.expectEqualStrings("{\"prefix\":\"p1\"}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "deletecategoryrule") != null);
}

test "qrcode jump null omission" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getcategory", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeJumpService{ .svc = &base };

    // getRules(null,null) → "{}" 全省略
    const rules = switch (s.getRules(io, null, null)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer deinitRules(gpa, rules);
    try std.testing.expectEqual(@as(usize, 0), rules.len);
    try std.testing.expectEqualStrings("{}", m.last_body);
}
