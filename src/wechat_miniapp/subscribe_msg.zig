//! 订阅消息 + 订阅消息模板库 —— 对应 Java `api.WxMaSubscribeService`
//! (`api.impl.WxMaSubscribeServiceImpl`)与 `api.WxMaMsgService#sendSubscribeMsg`
//! (`api.impl.WxMaMsgServiceImpl`)。
//!
//! URL 全部对齐 `constant.WxMaApiUrlConstants.Subscribe/.Msg`。
//! 线格式对齐 `json.adaptor.WxMaSubscribeMessageGsonAdapter`:
//! `{touser,template_id,page?,miniprogram_state?,lang?,data:{k:{value}}}`。
//! 注意(以 Java 为准,与任务书口述略有出入):
//! - `add_template` 读取的是响应里的 **priTmplId**(Java `GsonParser...get("priTmplId")`,
//!   非 template_id);
//! - `get_pub_template_titles` 的分页参数是 **ids/start/limit**(Java 实参)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

/// 解析类内部错误(统一折叠为 WxError.transport 对外)。
pub const ParseError = error{ BadJson, MissingData, BadItem, OutOfMemory };

// --- URL(对应 WxMaApiUrlConstants) ------------------------------------------

const SUBSCRIBE_MSG_SEND_URL = "https://api.weixin.qq.com/cgi-bin/message/subscribe/send";
const TEMPLATE_ADD_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/addtemplate";
const TEMPLATE_DEL_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/deltemplate";
const TEMPLATE_LIST_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/gettemplate";
const GET_PUB_TEMPLATE_TITLE_LIST_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/getpubtemplatetitles";
const GET_PUB_TEMPLATE_KEY_WORDS_BY_ID_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/getpubtemplatekeywords";
const GET_CATEGORY_URL = "https://api.weixin.qq.com/wxaapi/newtmpl/getcategory";

/// 写一个 JSON 字符串字面量(带引号与转义;对应 Gson 的 addProperty)。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaSubscribeMessage.MsgData`(模板变量:名字 → 值)。
pub const MsgData = struct { name: []const u8, value: []const u8 };

/// 对应 `bean.WxMaSubscribeMessage`(序列化见 `WxMaSubscribeMessageGsonAdapter`)。
pub const SubscribeMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    page: ?[]const u8 = null,
    /// 对应 Java 默认 `WxMaConstants.MiniProgramState.FORMAL`("formal")。
    miniprogram_state: ?[]const u8 = "formal",
    /// 对应 Java 默认 `WxMaConstants.MiniProgramLang.ZH_CN`("zh_CN")。
    lang: ?[]const u8 = "zh_CN",
    data: []const MsgData = &.{},

    /// 对应 `WxMaSubscribeMessage.toJson()`(adapter 手写序列化,逐字段对齐;
    /// data 恒出现,可为空对象 —— 与 Java 一致)。
    pub fn to_json(self: SubscribeMessage, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"touser\":");
        try js(w, self.to_user);
        try w.writeAll(",\"template_id\":");
        try js(w, self.template_id);
        if (self.page) |p| {
            try w.writeAll(",\"page\":");
            try js(w, p);
        }
        if (self.miniprogram_state) |st| {
            try w.writeAll(",\"miniprogram_state\":");
            try js(w, st);
        }
        if (self.lang) |l| {
            try w.writeAll(",\"lang\":");
            try js(w, l);
        }
        try w.writeAll(",\"data\":{");
        for (self.data, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try js(w, d.name);
            try w.writeAll(":{\"value\":");
            try js(w, d.value);
            try w.writeAll("}");
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// 对应 `common.bean.subscribemsg.TemplateInfo`(个人模板;字符串均 gpa 拥有)。
pub const TemplateInfo = struct {
    pri_tmpl_id: []const u8,
    title: []const u8,
    content: []const u8,
    example: []const u8,
    type: i64,

    pub fn free(self: *TemplateInfo, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.pri_tmpl_id));
        gpa.free(@constCast(self.title));
        gpa.free(@constCast(self.content));
        gpa.free(@constCast(self.example));
    }

    fn from_json(gpa: std.mem.Allocator, v: json_util.Value) !TemplateInfo {
        return .{
            .pri_tmpl_id = try gpa.dupe(u8, json_util.getStr(v, "priTmplId") orelse ""),
            .title = try gpa.dupe(u8, json_util.getStr(v, "title") orelse ""),
            .content = try gpa.dupe(u8, json_util.getStr(v, "content") orelse ""),
            .example = try gpa.dupe(u8, json_util.getStr(v, "example") orelse ""),
            .type = json_util.getInt(v, "type") orelse 0,
        };
    }
};

/// 释放 `get_user_templates` 的返回(每元素字符串 + 切片本身)。
pub fn free_template_list(gpa: std.mem.Allocator, items: []TemplateInfo) void {
    for (items) |*it| it.free(gpa);
    gpa.free(items);
}

/// 对应 `PubTemplateTitleListResult.TemplateItem`(公共模板标题)。
pub const TemplateItem = struct {
    type: i64,
    tid: i64,
    category_id: []const u8,
    title: []const u8,

    pub fn free(self: *TemplateItem, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.category_id));
        gpa.free(@constCast(self.title));
    }

    fn from_json(gpa: std.mem.Allocator, v: json_util.Value) !TemplateItem {
        return .{
            .type = json_util.getInt(v, "type") orelse 0,
            .tid = json_util.getInt(v, "tid") orelse 0,
            .category_id = try gpa.dupe(u8, json_util.getStr(v, "categoryId") orelse ""),
            .title = try gpa.dupe(u8, json_util.getStr(v, "title") orelse ""),
        };
    }
};

/// 对应 `PubTemplateTitleListResult`。
pub const PubTemplateTitleListResult = struct {
    count: i64,
    data: []TemplateItem,

    pub fn free(self: *PubTemplateTitleListResult, gpa: std.mem.Allocator) void {
        for (self.data) |*it| it.free(gpa);
        gpa.free(self.data);
    }
};

/// 对应 `PubTemplateKeyword`。
pub const PubTemplateKeyword = struct {
    kid: i64,
    name: []const u8,
    example: []const u8,
    rule: []const u8,

    pub fn free(self: *PubTemplateKeyword, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.name));
        gpa.free(@constCast(self.example));
        gpa.free(@constCast(self.rule));
    }

    fn from_json(gpa: std.mem.Allocator, v: json_util.Value) !PubTemplateKeyword {
        return .{
            .kid = json_util.getInt(v, "kid") orelse 0,
            .name = try gpa.dupe(u8, json_util.getStr(v, "name") orelse ""),
            .example = try gpa.dupe(u8, json_util.getStr(v, "example") orelse ""),
            .rule = try gpa.dupe(u8, json_util.getStr(v, "rule") orelse ""),
        };
    }
};

pub fn free_keyword_list(gpa: std.mem.Allocator, items: []PubTemplateKeyword) void {
    for (items) |*it| it.free(gpa);
    gpa.free(items);
}

/// 对应 `CategoryData`。
pub const CategoryData = struct {
    id: i64,
    name: []const u8,

    pub fn free(self: *CategoryData, gpa: std.mem.Allocator) void {
        gpa.free(@constCast(self.name));
    }

    fn from_json(gpa: std.mem.Allocator, v: json_util.Value) !CategoryData {
        return .{
            .id = json_util.getInt(v, "id") orelse 0,
            .name = try gpa.dupe(u8, json_util.getStr(v, "name") orelse ""),
        };
    }
};

pub fn free_category_list(gpa: std.mem.Allocator, items: []CategoryData) void {
    for (items) |*it| it.free(gpa);
    gpa.free(items);
}

/// 通用:`{"data":[...]}` 列表解析(对应各方法里的 `getAsJsonArray("data")` +
/// Gson 反序列化)。用内部错误集,`errdefer` 才能真正生效;调用方折叠为 WxError。
fn parse_data_list(gpa: std.mem.Allocator, bytes: []const u8, comptime T: type, comptime from_json: anytype) (ParseError)![]T {
    const parsed = json_util.parse(gpa, bytes) catch return error.BadJson;
    defer parsed.deinit();
    const arr = json_util.getArray(parsed.value, "data") orelse return error.MissingData;
    var list: std.ArrayList(T) = .empty;
    errdefer {
        for (list.items) |*it| {
            var x = it.*;
            x.free(gpa);
        }
        list.deinit(gpa);
    }
    for (arr.items) |item| {
        var v = from_json(gpa, item) catch return error.BadItem;
        errdefer v.free(gpa);
        try list.append(gpa, v);
    }
    return list.toOwnedSlice(gpa);
}

fn fold(gpa: std.mem.Allocator, ctx: []const u8, e: anyerror) WxError {
    return WxError.transport(gpa, "{s}: {s}", .{ ctx, @errorName(e) });
}

// --- service ------------------------------------------------------------------

/// 订阅消息服务 —— 组合在服务基座上(对应 `WxMaSubscribeServiceImpl` 持有
/// `WxMaService` 引用的组合方式)。
pub const SubscribeService = struct {
    svc: *mp_service.Service,

    fn gpa(self: *SubscribeService) std.mem.Allocator {
        return self.svc.gpa;
    }

    /// 对应 `WxMaMsgService#sendSubscribeMsg`:POST /cgi-bin/message/subscribe/send。
    /// errcode≠0 已由服务基座折叠为 `.err`(对应 Java 的 WxErrorException)。
    pub fn send(self: *SubscribeService, io: std.Io, msg: SubscribeMessage) Done {
        const g = self.gpa();
        const body = msg.to_json(g) catch |e| return .{ .err = fold(g, "subscribe send build body", e) };
        defer g.free(body);
        return switch (self.svc.post(io, SUBSCRIBE_MSG_SEND_URL, &.{}, body)) {
            .ok => |b| {
                g.free(b);
                return .{ .ok = {} };
            },
            .err => |e| return .{ .err = e },
        };
    }

    /// 对应 `getPubTemplateTitleList(String[] ids, start, limit)`:
    /// GET /wxaapi/newtmpl/getpubtemplatetitles?ids=a,b&start=&limit=。
    /// 返回值归 gpa 所有,用 `PubTemplateTitleListResult.free` 释放。
    pub fn get_pub_template_titles(self: *SubscribeService, io: std.Io, ids: []const []const u8, start: i64, limit: i64) WxResult(PubTemplateTitleListResult) {
        const g = self.gpa();
        var ids_buf: std.ArrayList(u8) = .empty;
        defer ids_buf.deinit(g);
        for (ids, 0..) |id, i| {
            if (i > 0) ids_buf.append(g, ',') catch return .{ .err = WxError.transport(g, "oom", .{}) };
            ids_buf.appendSlice(g, id) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        }
        const start_s = std.fmt.allocPrint(g, "{d}", .{start}) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(start_s);
        const limit_s = std.fmt.allocPrint(g, "{d}", .{limit}) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(limit_s);
        const qs = [_]mp_service.Query{
            .{ .key = "ids", .value = ids_buf.items },
            .{ .key = "start", .value = start_s },
            .{ .key = "limit", .value = limit_s },
        };
        const resp = switch (self.svc.get(io, GET_PUB_TEMPLATE_TITLE_LIST_URL, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);

        const res = parse_titles(g, resp) catch |e| return .{ .err = fold(g, "pub template titles", e) };
        return .{ .ok = res };
    }

    fn parse_titles(g: std.mem.Allocator, bytes: []const u8) (ParseError)!PubTemplateTitleListResult {
        const items = try parse_data_list(g, bytes, TemplateItem, TemplateItem.from_json);
        errdefer {
            for (items) |*it| {
                var x = it.*;
                x.free(g);
            }
            g.free(items);
        }
        // items 已被 parse_data_list 解析;count 需要重新解析整包,合并返回。
        const parsed = json_util.parse(g, bytes) catch return error.BadJson;
        defer parsed.deinit();
        return .{
            .count = json_util.getInt(parsed.value, "count") orelse 0,
            .data = items,
        };
    }

    /// 对应 `getPubTemplateKeyWordsById(id)`:
    /// GET /wxaapi/newtmpl/getpubtemplatekeywords?tid=id。
    /// 返回串归 gpa 所有,用 `free_keyword_list` 释放。
    pub fn get_pub_template_keywords(self: *SubscribeService, io: std.Io, tid: []const u8) WxResult([]PubTemplateKeyword) {
        const g = self.gpa();
        const qs = [_]mp_service.Query{.{ .key = "tid", .value = tid }};
        const resp = switch (self.svc.get(io, GET_PUB_TEMPLATE_KEY_WORDS_BY_ID_URL, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const items = parse_data_list(g, resp, PubTemplateKeyword, PubTemplateKeyword.from_json) catch |e|
            return .{ .err = fold(g, "pub template keywords", e) };
        return .{ .ok = items };
    }

    /// 对应 `addTemplate(id, kidList, sceneDesc)`:
    /// POST /wxaapi/newtmpl/addtemplate {tid,kidList,sceneDesc} → priTmplId。
    /// 返回串归 gpa 所有(调用方 `gpa.free`)。
    pub fn add_template(self: *SubscribeService, io: std.Io, id: []const u8, kid_list: []const i64, scene_desc: []const u8) WxResult([]const u8) {
        const g = self.gpa();
        var out: std.Io.Writer.Allocating = .init(g);
        errdefer out.deinit();
        const w = &out.writer;
        w.print("{{\"tid\":", .{}) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        js(w, id) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        w.writeAll(",\"kidList\":[") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        for (kid_list, 0..) |kid, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.transport(g, "oom", .{}) };
            w.print("{d}", .{kid}) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        }
        w.writeAll("],\"sceneDesc\":") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        js(w, scene_desc) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(body);

        const resp = switch (self.svc.post(io, TEMPLATE_ADD_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const parsed = json_util.parse(g, resp) catch return .{
            .err = WxError.transport(g, "add template not json", .{}),
        };
        defer parsed.deinit();
        const tmpl_id = json_util.getStr(parsed.value, "priTmplId") orelse return .{
            .err = WxError.internal(g, "add template response missing priTmplId", .{}),
        };
        return .{ .ok = g.dupe(u8, tmpl_id) catch return .{ .err = WxError.transport(g, "oom", .{}) } };
    }

    /// 对应 `getTemplateList()`:GET /wxaapi/newtmpl/gettemplate。
    /// 返回串归 gpa 所有,用 `free_template_list` 释放。
    pub fn get_user_templates(self: *SubscribeService, io: std.Io) WxResult([]TemplateInfo) {
        const g = self.gpa();
        const resp = switch (self.svc.get(io, TEMPLATE_LIST_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const items = parse_data_list(g, resp, TemplateInfo, TemplateInfo.from_json) catch |e|
            return .{ .err = fold(g, "template list", e) };
        return .{ .ok = items };
    }

    /// 对应 `delTemplate(templateId)`:POST /wxaapi/newtmpl/deltemplate {priTmplId}。
    pub fn delete_template(self: *SubscribeService, io: std.Io, pri_tmpl_id: []const u8) Done {
        const g = self.gpa();
        var out: std.Io.Writer.Allocating = .init(g);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"priTmplId\":") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        js(w, pri_tmpl_id) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.transport(g, "oom", .{}) };
        defer g.free(body);
        return switch (self.svc.post(io, TEMPLATE_DEL_URL, &.{}, body)) {
            .ok => |b| {
                g.free(b);
                return .{ .ok = {} };
            },
            .err => |e| return .{ .err = e },
        };
    }

    /// 对应 `getCategory()`:GET /wxaapi/newtmpl/getcategory。
    /// 返回串归 gpa 所有,用 `free_category_list` 释放。
    pub fn get_category(self: *SubscribeService, io: std.Io) WxResult([]CategoryData) {
        const g = self.gpa();
        const resp = switch (self.svc.get(io, GET_CATEGORY_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer g.free(resp);
        const items = parse_data_list(g, resp, CategoryData, CategoryData.from_json) catch |e|
            return .{ .err = fold(g, "category list", e) };
        return .{ .ok = items };
    }
};

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + body + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

fn new_setup(gpa: std.mem.Allocator, m: *mock_mod.MockExecutor) !struct { cfg: mock_mod.mp_config.InMemoryConfigStorage, base: mp_service.Service, s: SubscribeService } {
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    errdefer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    _ = &base;
    return .{ .cfg = cfg, .base = base, .s = .{ .svc = &base } };
}

test "subscribe send: post shape + parse" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "message/subscribe/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SubscribeService{ .svc = &base };

    const msg = SubscribeMessage{
        .to_user = "oUser",
        .template_id = "TPL1",
        .page = "pages/index",
        .data = &.{ .{ .name = "thing1", .value = "你好" }, .{ .name = "amount2", .value = "10.00" } },
    };
    const r = s.send(io, msg);
    try std.testing.expect(!r.failed());

    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/cgi-bin/message/subscribe/send") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);
    try std.testing.expect(m.last_body_is_null == false);

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oUser", json_util.getStr(parsed.value, "touser").?);
    try std.testing.expectEqualStrings("TPL1", json_util.getStr(parsed.value, "template_id").?);
    try std.testing.expectEqualStrings("pages/index", json_util.getStr(parsed.value, "page").?);
    try std.testing.expectEqualStrings("formal", json_util.getStr(parsed.value, "miniprogram_state").?);
    try std.testing.expectEqualStrings("zh_CN", json_util.getStr(parsed.value, "lang").?);
    const data = json_util.objectOf(parsed.value, "data").?;
    const thing1 = data.get("thing1").?;
    try std.testing.expectEqualStrings("你好", json_util.getStr(thing1, "value").?);
    const amount2 = data.get("amount2").?;
    try std.testing.expectEqualStrings("10.00", json_util.getStr(amount2, "value").?);
}

test "subscribe send: errcode -> WxError" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "message/subscribe/send", .response = "{\"errcode\":43101,\"errmsg\":\"user refuse to accept the msg\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SubscribeService{ .svc = &base };

    const r = s.send(io, .{ .to_user = "oU", .template_id = "T" });
    switch (r) {
        .ok => return error.ExpectedErr,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 43101), err.error_code);
            try std.testing.expectEqualStrings("user refuse to accept the msg", err.error_msg_en);
        },
    }
}

test "add_template + delete_template" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "newtmpl/addtemplate", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"priTmplId\":\"P1\"}" },
        .{ .match = "newtmpl/deltemplate", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SubscribeService{ .svc = &base };

    const id = switch (s.add_template(io, "959", &.{ 1, 2, 20 }, "订单发货提醒")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(id);
    try std.testing.expectEqualStrings("P1", id);
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxaapi/newtmpl/addtemplate") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("959", json_util.getStr(parsed.value, "tid").?);
    try std.testing.expectEqualStrings("订单发货提醒", json_util.getStr(parsed.value, "sceneDesc").?);
    const kids = json_util.getArray(parsed.value, "kidList").?;
    try std.testing.expectEqual(@as(usize, 3), kids.items.len);
    try std.testing.expectEqual(@as(i64, 20), kids.items[2].integer);

    const d = s.delete_template(io, "P1");
    try std.testing.expect(!d.failed());
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxaapi/newtmpl/deltemplate") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"priTmplId\":\"P1\"") != null);
}

test "get_user_templates + get_category" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "newtmpl/gettemplate", .response = "{\"errcode\":0,\"data\":[{\"priTmplId\":\"P1\",\"title\":\"t1\",\"content\":\"c\",\"example\":\"e\",\"type\":1},{\"priTmplId\":\"P2\",\"title\":\"t2\",\"content\":\"c2\",\"example\":\"e2\",\"type\":2}]}" },
        .{ .match = "newtmpl/getcategory", .response = "{\"errcode\":0,\"data\":[{\"id\":616,\"name\":\"IT科技\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SubscribeService{ .svc = &base };

    const list = switch (s.get_user_templates(io)) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer free_template_list(gpa, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("P1", list[0].pri_tmpl_id);
    try std.testing.expectEqual(@as(i64, 2), list[1].type);
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.get, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxaapi/newtmpl/gettemplate") != null);
    try std.testing.expect(m.last_body_is_null);

    const cats = switch (s.get_category(io)) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer free_category_list(gpa, cats);
    try std.testing.expectEqual(@as(usize, 1), cats.len);
    try std.testing.expectEqual(@as(i64, 616), cats[0].id);
    try std.testing.expectEqualStrings("IT科技", cats[0].name);
}

test "get_pub_template_titles + keywords" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getpubtemplatetitles", .response = "{\"errcode\":0,\"count\":2,\"data\":[{\"tid\":537,\"type\":2,\"categoryId\":\"1\",\"title\":\"发货提醒\"}]}" },
        .{ .match = "getpubtemplatekeywords", .response = "{\"errcode\":0,\"data\":[{\"kid\":1,\"name\":\"订单编号\",\"example\":\"1234\",\"rule\":\"订单编号\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SubscribeService{ .svc = &base };

    var res = switch (s.get_pub_template_titles(io, &.{ "439", "61" }, 0, 10)) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer res.free(gpa);
    try std.testing.expectEqual(@as(i64, 2), res.count);
    try std.testing.expectEqual(@as(usize, 1), res.data.len);
    try std.testing.expectEqual(@as(i64, 537), res.data[0].tid);
    try std.testing.expectEqualStrings("1", res.data[0].category_id);
    try std.testing.expectEqualStrings("发货提醒", res.data[0].title);
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.get, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ids=439%2C61") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "start=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "limit=10") != null);

    const kws = switch (s.get_pub_template_keywords(io, "537")) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer free_keyword_list(gpa, kws);
    try std.testing.expectEqual(@as(usize, 1), kws.len);
    try std.testing.expectEqual(@as(i64, 1), kws[0].kid);
    try std.testing.expectEqualStrings("订单编号", kws[0].name);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "tid=537") != null);
}
