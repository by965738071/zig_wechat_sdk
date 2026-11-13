//! 订阅通知服务 —— 逐字对齐 Java `api.WxMpSubscribeMsgService`(9 方法)
//! + `api.impl.WxMpSubscribeMsgServiceImpl`。
//!
//! 命名:全部采用 Java 的 camelCase 方法名(rule 2):
//!   subscribeMsgAuthorizationUrl / sendOnce / getPubTemplateTitleList /
//!   getPubTemplateKeyWordsById / addTemplate / getTemplateList / delTemplate /
//!   getCategory / send。
//! 与小程序订阅消息(`wechat_miniapp/subscribe_msg.zig`)是不同业务线的不同端点,不复用。
//!
//! 底座(rule 3):
//!   - 所有 URL 路径来自 `../api_url.zig:SubscribeMsg`,经 `api()`(= `Host.api + path`)
//!     拼成 API 绝对 URL;**授权 URL 是非 API host 常量**,用 `Host.mp` 拼接(见下);
//!   - 带 query 的 GET(getPubTemplateTitleList / getPubTemplateKeyWordsById)用
//!     `common.mp_helpers.buildUrl` 手工拼 query;授权 URL 的 redirect 用
//!     `mp_helpers.urlEncode` 做百分号编码;
//!   - 扁平 JSON 请求体(addTemplate / delTemplate)用 `json_util.ObjectBuilder`;
//!     复杂嵌套消息体 `SubscribeMessage.toJson` 用 `std.Io.Writer.Allocating`;
//!   - `Service.execute*` 已折叠 errcode→`.err` 并注入 access_token。
//!
//! Java↔Zig 语言差异(已按 Java 逻辑取舍,逐条说明):
//!   - `subscribeMsgAuthorizationUrl`(接口 :31 / impl :41-45)是**纯 URL 构造,不发 HTTP**
//!     (rule 1):Java `String.format(SUBSCRIBE_MESSAGE_AUTHORIZE_URL.getUrl(storage),
//!     appid, scene, templateId, encodeURIComponent(redirectUri), reserved)`。本轮:
//!       * appid 取自 `config.appid()`(与 Java `storage.getAppId()` 一致);
//!       * **`config.zig` 无 `templateId` getter(helper gap)**,故 `template_id` 改由调用方
//!         显式传入;
//!       * redirect 用 `mp_helpers.urlEncode`(对应 Java `URIUtil.encodeURIComponent`);
//!       * `reserved` 按 impl 原样透传(接口 javadoc 要求调用方自行预编码,impl 不编码);
//!       * 模板里的 `%s/%d` 用最小本地 `fillTemplate` 顺序填充(对应 `String.format`),
//!         主机用 `api_url.Host.mp`(NON-API-host,不能前缀 api host)。
//!   - `sendOnce`(接口 :43 / impl :48-55)→ POST `SEND_MESSAGE_ONCE_URL`
//!     (cgi-bin/message/template/subscribe),返回 `responseContent != null` → Zig `Done`。
//!     Java 在 `templateId==null` 时回退 `config.getTemplateId()`;同上面的 helper gap,
//!     Zig 要求调用方在 `SubscribeMessage.template_id` 显式给出。
//!   - `send`(接口 :140 / impl :106-113)是**另一个** POST(`SEND_SUBSCRIBE_MESSAGE_URL`
//!     = cgi-bin/message/subscribe/bizsend),返回 `msgid` 字符串(旧 Zig 误作 Done,本轮纠正)。
//!   - `getPubTemplateTitleList`:Java `ImmutableMap.of(ids,start,limit)` + Joiner 拼
//!     `ids=..&start=..&limit=..` → Zig `mp_helpers.buildUrl`(value 做百分号编码)。
//!   - `WxMpSubscribeMessageGsonAdapter`:`dataMap!=null` 分支 → `data:{key:{value}}`;
//!     `dataMap==null` 分支 → `data:{content:{value?,color?}}`。Zig 用 `data:[]Data`
//!     表达前者,用 `content_value`/`content_color` 表达后者(两者皆空时保留 `data:{}`)。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `[]const u8` 裸结果(msgid / priTmplId)、`[]u8` 授权 URL:`gpa.free()`;
//!   - 结果结构(PubTemplateTitleListResult 等):`deinit()`;
//!   - 结果切片([]PubTemplateKeyword / []TemplateInfo / []CategoryData):逐元素 `deinit()`
//!     + `free(slice)`(len!=0 时);
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const mp_helpers = @import("common").mp_helpers;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;
const token_mod = @import("common").token;

const api_url = @import("../api_url.zig");
const config_mod = @import("../config.zig");
const http_mod = @import("../http.zig");
const service_mod = @import("../service.zig");

/// host+path 绝对 URL(API host),路径全部取自 `api_url.zig:SubscribeMsg`。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

fn encStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
}

/// 取 JSON 字符串字段并 dupe 成 gpa 拥有(缺失返回 null)。
fn dupeStr(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    const s = json_util.getStr(v, key) orelse return null;
    return try gpa.dupe(u8, s);
}

/// msgid 可能为数字或字符串;恒定返回 gpa 拥有串(缺失时 dupe 空串),保证 free 合法。
fn msgIdFromJson(gpa: std.mem.Allocator, v: json_util.Value) ![]const u8 {
    if (json_util.getStr(v, "msgid")) |s| return try gpa.dupe(u8, s);
    if (json_util.getInt(v, "msgid")) |n| return try std.fmt.allocPrint(gpa, "{d}", .{n});
    return try gpa.dupe(u8, "");
}

/// 对应 Java `String.format(template, appid, scene, templateId, redirectUrl, reserved)`:
/// 按顺序把模板里的 `%s`/`%d` 占位符替换为 args,其余字符(含 `#wechat_redirect`
/// 片段)逐字保留。这是「填充 Java 字面模板」而非重新拼 URL —— URL 结构完全由
/// `api_url.zig` 常量提供(mp_helpers/api_url 无 Java 格式化器,此处最小实现并上报)。
fn fillTemplate(gpa: std.mem.Allocator, template: []const u8, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var i: usize = 0;
    var ai: usize = 0;
    while (i < template.len) {
        if (template[i] == '%' and i + 1 < template.len and
            (template[i + 1] == 's' or template[i + 1] == 'd') and ai < args.len)
        {
            try w.writeAll(args[ai]);
            ai += 1;
            i += 2;
        } else {
            try w.writeByte(template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

/// 逗号连接类目 id(`StringUtils.join(ids, ",")`)。
fn joinIds(gpa: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (ids, 0..) |id, i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(id);
    }
    return out.toOwnedSlice();
}

/// `data` 数组 → `[]T`(对应 Java `getAsJsonArray("data")` + Gson `fromJson`)。
/// 要求 T 具备 `fromJson(gpa, value) !T` 与 `deinit(self: *T) void`。
fn parseDataArray(comptime T: type, gpa: std.mem.Allocator, v: json_util.Value) ![]T {
    var list: std.ArrayList(T) = .empty;
    errdefer {
        for (list.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    if (json_util.getArray(v, "data")) |arr| {
        for (arr.items) |item| try list.append(gpa, try T.fromJson(gpa, item));
    }
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 结果结构(对应 common.bean.subscribemsg.*,全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// `PubTemplateTitleListResult.TemplateItem` {type,tid,categoryId,title}。
pub const PubTemplateTitleItem = struct {
    gpa: std.mem.Allocator,
    type_: ?i64 = null,
    tid: ?i64 = null,
    category_id: ?[]const u8 = null,
    title: ?[]const u8 = null,

    pub fn deinit(self: *PubTemplateTitleItem) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.category_id, self.title }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !PubTemplateTitleItem {
        var r = PubTemplateTitleItem{ .gpa = gpa };
        errdefer r.deinit();
        r.type_ = json_util.getInt(v, "type");
        r.tid = json_util.getInt(v, "tid");
        r.category_id = try dupeStr(gpa, v, "categoryId");
        r.title = try dupeStr(gpa, v, "title");
        return r;
    }
};

/// `PubTemplateTitleListResult` {count,data:[...]} —— 由根对象解析(非 data 子数组)。
pub const PubTemplateTitleListResult = struct {
    gpa: std.mem.Allocator,
    count: i64 = 0,
    data: []PubTemplateTitleItem = &.{},

    pub fn deinit(self: *PubTemplateTitleListResult) void {
        for (self.data) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.data.len != 0) self.gpa.free(self.data);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !PubTemplateTitleListResult {
        var r = PubTemplateTitleListResult{ .gpa = gpa };
        errdefer r.deinit();
        r.count = json_util.getIntOr(v, "count", 0);
        r.data = try parseDataArray(PubTemplateTitleItem, gpa, v);
        return r;
    }
};

/// `PubTemplateKeyword` {kid,name,example,rule}。
pub const PubTemplateKeyword = struct {
    gpa: std.mem.Allocator,
    kid: i64 = 0,
    name: ?[]const u8 = null,
    example: ?[]const u8 = null,
    rule: ?[]const u8 = null,

    pub fn deinit(self: *PubTemplateKeyword) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.name, self.example, self.rule }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !PubTemplateKeyword {
        var r = PubTemplateKeyword{ .gpa = gpa };
        errdefer r.deinit();
        r.kid = json_util.getIntOr(v, "kid", 0);
        r.name = try dupeStr(gpa, v, "name");
        r.example = try dupeStr(gpa, v, "example");
        r.rule = try dupeStr(gpa, v, "rule");
        return r;
    }
};

/// `TemplateInfo` {priTmplId,title,content,example,type}。
pub const TemplateInfo = struct {
    gpa: std.mem.Allocator,
    pri_tmpl_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    example: ?[]const u8 = null,
    type_: i64 = 0,

    pub fn deinit(self: *TemplateInfo) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.pri_tmpl_id, self.title, self.content, self.example }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !TemplateInfo {
        var r = TemplateInfo{ .gpa = gpa };
        errdefer r.deinit();
        r.pri_tmpl_id = try dupeStr(gpa, v, "priTmplId");
        r.title = try dupeStr(gpa, v, "title");
        r.content = try dupeStr(gpa, v, "content");
        r.example = try dupeStr(gpa, v, "example");
        r.type_ = json_util.getIntOr(v, "type", 0);
        return r;
    }
};

/// `CategoryData` {id,name}。
pub const CategoryData = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: ?[]const u8 = null,

    pub fn deinit(self: *CategoryData) void {
        if (self.name) |v| self.gpa.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !CategoryData {
        var r = CategoryData{ .gpa = gpa };
        errdefer r.deinit();
        r.id = json_util.getIntOr(v, "id", 0);
        r.name = try dupeStr(gpa, v, "name");
        return r;
    }
};

// ---------------------------------------------------------------------------
// 请求体 bean(与 template_msg.zig 的 TemplateData / MiniProgram 同构)
// ---------------------------------------------------------------------------

/// 模板变量项 —— 对应 `dataMap` 里的 `key:{value}`。
pub const Data = struct {
    name: []const u8,
    value: []const u8,
};

/// 跳小程序(可选)—— `use_path` 为 true 时序列化成 `path`,否则 `pagepath`
/// (对应 `WxMpSubscribeMessage.MiniProgram.usePath`)。
pub const MiniProgram = struct {
    appid: []const u8,
    page_path: []const u8 = "",
    use_path: bool = false,
};

/// 待发送的订阅通知 —— 对应 Java `WxMpSubscribeMessage`。
pub const SubscribeMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    /// 点击跳转的网页(与 page 二选一)
    url: ?[]const u8 = null,
    /// 点击跳转小程序的页面
    page: ?[]const u8 = null,
    miniprogram: ?MiniProgram = null,
    /// 订阅场景值
    scene: ?[]const u8 = null,
    /// 消息标题
    title: ?[]const u8 = null,
    /// Java `contentValue`/`contentColor`:dataMap 为 null 时序列化到 data.content
    content_value: ?[]const u8 = null,
    content_color: ?[]const u8 = null,
    /// Java `dataMap`(Map<String,String>):非空时按 key 展开 data:{key:{value}}
    data: []const Data = &.{},

    /// 序列化为请求体 —— 对应 `WxMpSubscribeMessageGsonAdapter#serialize`:
    /// `{touser,template_id[,url][,page][,miniprogram][,scene][,title],data:...}`,
    /// data 恒出现:data 非空 → dataMap 分支;data 空但设 content → content 分支;
    /// 否则空对象 {}。
    pub fn toJson(gpa: std.mem.Allocator, m: SubscribeMessage) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"touser\":");
        try encStr(w, m.to_user);
        try w.writeAll(",\"template_id\":");
        try encStr(w, m.template_id);
        if (m.url) |u| {
            try w.writeAll(",\"url\":");
            try encStr(w, u);
        }
        if (m.page) |p| {
            try w.writeAll(",\"page\":");
            try encStr(w, p);
        }
        if (m.miniprogram) |mp| {
            try w.writeAll(",\"miniprogram\":{\"appid\":");
            try encStr(w, mp.appid);
            try w.writeAll(if (mp.use_path) ",\"path\":" else ",\"pagepath\":");
            try encStr(w, mp.page_path);
            try w.writeByte('}');
        }
        if (m.scene) |s| {
            try w.writeAll(",\"scene\":");
            try encStr(w, s);
        }
        if (m.title) |t| {
            try w.writeAll(",\"title\":");
            try encStr(w, t);
        }
        try w.writeAll(",\"data\":{");
        if (m.data.len > 0) {
            for (m.data, 0..) |d, i| {
                if (i != 0) try w.writeByte(',');
                try encStr(w, d.name);
                try w.writeAll(":{\"value\":");
                try encStr(w, d.value);
                try w.writeByte('}');
            }
        } else if (m.content_value != null or m.content_color != null) {
            // Java dataMap==null 分支:data.content.{value,color}
            try w.writeAll("\"content\":{");
            var wrote = false;
            if (m.content_value) |v| {
                try w.writeAll("\"value\":");
                try encStr(w, v);
                wrote = true;
            }
            if (m.content_color) |c| {
                if (wrote) try w.writeByte(',');
                try w.writeAll("\"color\":");
                try encStr(w, c);
            }
            try w.writeByte('}');
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// `{"tid":"..","kidList":[n,...],"sceneDesc":".."}` —— 对应 Java
/// `service.post(TEMPLATE_ADD_URL, ImmutableMap.of("tid",id,"kidList",arr,"sceneDesc",desc))`。
fn buildAddTemplateBody(gpa: std.mem.Allocator, id: []const u8, keyword_ids: []const i64, scene_desc: []const u8) ![]u8 {
    var arr: std.ArrayList(json_util.Value) = .empty;
    defer arr.deinit(gpa);
    for (keyword_ids) |k| try arr.append(gpa, .{ .integer = k });
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("tid", id);
    try ob.putValue("kidList", .{ .array = arr });
    try ob.putStr("sceneDesc", scene_desc);
    return ob.toJson();
}

// ---------------------------------------------------------------------------
// 请求辅助(host → svc.get/post,token 附加 + errcode 折叠 + 重试都在 Service)
// ---------------------------------------------------------------------------

fn apiGet(self: *SubscribeMsgService, io: std.Io, comptime path: []const u8) WxResult([]u8) {
    return self.svc.get(io, api(path), &.{});
}

fn apiPost(self: *SubscribeMsgService, io: std.Io, comptime path: []const u8, body: []const u8) WxResult([]u8) {
    return self.svc.post(io, api(path), &.{}, body);
}

/// 带 query 的 GET:query 由 `mp_helpers.buildUrl`(内含 urlEncode)拼到绝对 URL 上。
fn getWithQuery(self: *SubscribeMsgService, io: std.Io, comptime path: []const u8, query: []const mp_helpers.Query) WxResult([]u8) {
    const gpa = self.svc.gpa;
    const uri = mp_helpers.buildUrl(gpa, api(path), query, null) catch |e|
        return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
    defer gpa.free(uri);
    return self.svc.get(io, uri, &.{});
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 `Service.executeInternal` 折叠为 .err)。
fn postVoid(self: *SubscribeMsgService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(self, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// SubscribeMsgService —— 对应 Java `WxMpSubscribeMsgService`(9 方法) + Impl
// ---------------------------------------------------------------------------

pub const SubscribeMsgService = struct {
    svc: *service_mod.Service,

    /// `subscribeMsgAuthorizationUrl(redirectURI, scene, reserved)` (接口 :31 / impl :41-45)
    /// —— **纯 URL 构造,不发 HTTP**(rule 1)。Java `String.format` 把 appid/scene/templateId/
    /// encoded-redirect/reserved 填进 MP-host 模板;`template_id` 因 config 无 getter 改由
    /// 调用方显式传入(见模块 doc)。主机用 `api_url.Host.mp`(NON-API-host)。
    /// 所有权:返回 `[]u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn subscribeMsgAuthorizationUrl(
        self: *SubscribeMsgService,
        redirect_uri: []const u8,
        scene: i64,
        template_id: []const u8,
        reserved: []const u8,
    ) ![]u8 {
        const gpa = self.svc.gpa;
        const scene_str = try std.fmt.allocPrint(gpa, "{d}", .{scene});
        defer gpa.free(scene_str);
        const enc_redirect = try mp_helpers.urlEncode(gpa, redirect_uri);
        defer gpa.free(enc_redirect);
        const appid = self.svc.config.appid();
        const args = [_][]const u8{ appid, scene_str, template_id, enc_redirect, reserved };
        return fillTemplate(
            gpa,
            api_url.url(api_url.Host.mp, api_url.SubscribeMsg.subscribe_message_authorize_url),
            &args,
        );
    }

    /// `sendOnce(message)` (接口 :43 / impl :48-55)。
    /// POST cgi-bin/message/template/subscribe,body = `message.toJson()` → Done
    /// (Java 返回 `responseContent != null`)。
    pub fn sendOnce(self: *SubscribeMsgService, io: std.Io, msg: SubscribeMessage) Done {
        const gpa = self.svc.gpa;
        const body = SubscribeMessage.toJson(gpa, msg) catch |e| return .{
            .err = WxError.internal(gpa, "build sendOnce body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        return postVoid(self, io, api_url.SubscribeMsg.send_message_once_url, body);
    }

    /// `getPubTemplateTitleList(ids, start, limit)` (接口 :59 / impl :58-64)。
    /// GET wxaapi/newtmpl/getpubtemplatetitles,query `ids=..&start=..&limit=..`
    /// (ids 逗号连接)→ `PubTemplateTitleListResult.fromJson` 解析根对象 {count,data}。
    /// 所有权:返回结果 `deinit()`(逐元素 + free 切片)。
    pub fn getPubTemplateTitleList(self: *SubscribeMsgService, io: std.Io, ids: []const []const u8, start: i64, limit: i64) WxResult(PubTemplateTitleListResult) {
        const gpa = self.svc.gpa;
        const joined = joinIds(gpa, ids) catch
            return .{ .err = WxError.internal(gpa, "join ids", .{}) };
        defer gpa.free(joined);
        const start_s = std.fmt.allocPrint(gpa, "{d}", .{start}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(start_s);
        const limit_s = std.fmt.allocPrint(gpa, "{d}", .{limit}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(limit_s);
        const q = [_]mp_helpers.Query{
            .{ .key = "ids", .value = joined },
            .{ .key = "start", .value = start_s },
            .{ .key = "limit", .value = limit_s },
        };
        const resp = switch (getWithQuery(self, io, api_url.SubscribeMsg.get_pub_template_title_list_url, &q)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getpubtemplatetitles not json", .{}),
        };
        defer parsed.deinit();
        const r = PubTemplateTitleListResult.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.internal(gpa, "parse pub template titles failed", .{}),
        };
        return .{ .ok = r };
    }

    /// `getPubTemplateKeyWordsById(id)` (接口 :73 / impl :67-73)。
    /// GET wxaapi/newtmpl/getpubtemplatekeywords,query `tid=<id>` → 解析 `data` 数组。
    /// 所有权:切片逐元素 `deinit()` + `free(slice)`(len!=0 时)。
    pub fn getPubTemplateKeyWordsById(self: *SubscribeMsgService, io: std.Io, id: []const u8) WxResult([]PubTemplateKeyword) {
        const gpa = self.svc.gpa;
        const q = [_]mp_helpers.Query{.{ .key = "tid", .value = id }};
        const resp = switch (getWithQuery(self, io, api_url.SubscribeMsg.get_pub_template_key_words_by_id_url, &q)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getpubtemplatekeywords not json", .{}),
        };
        defer parsed.deinit();
        const list = parseDataArray(PubTemplateKeyword, gpa, parsed.value) catch return .{
            .err = WxError.internal(gpa, "parse pub template keywords failed", .{}),
        };
        return .{ .ok = list };
    }

    /// `addTemplate(id, keywordIdList, sceneDesc)` (接口 :89 / impl :76-81)。
    /// POST wxaapi/newtmpl/addtemplate,body `{"tid","kidList":[...],"sceneDesc"}`
    /// → 返回 `priTmplId`。所有权:返回 `[]const u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn addTemplate(self: *SubscribeMsgService, io: std.Io, id: []const u8, keyword_id_list: []const i64, scene_desc: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = buildAddTemplateBody(gpa, id, keyword_id_list, scene_desc) catch |e| return .{
            .err = WxError.internal(gpa, "build addtemplate body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (apiPost(self, io, api_url.SubscribeMsg.template_add_url, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "addtemplate not json", .{}),
        };
        defer parsed.deinit();
        const tid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "priTmplId", "")) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = tid };
    }

    /// `getTemplateList()` (接口 :102 / impl :84-89)。
    /// GET wxaapi/newtmpl/gettemplate(无 query)→ 解析 `data` 数组 → `[]TemplateInfo`。
    /// 所有权:切片逐元素 `deinit()` + `free(slice)`。
    pub fn getTemplateList(self: *SubscribeMsgService, io: std.Io) WxResult([]TemplateInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self, io, api_url.SubscribeMsg.template_list_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "gettemplate not json", .{}),
        };
        defer parsed.deinit();
        const list = parseDataArray(TemplateInfo, gpa, parsed.value) catch return .{
            .err = WxError.internal(gpa, "parse template list failed", .{}),
        };
        return .{ .ok = list };
    }

    /// `delTemplate(templateId)` (接口 :116 / impl :92-95)。
    /// POST wxaapi/newtmpl/deltemplate,body `{"priTmplId":...}` → Done。
    pub fn delTemplate(self: *SubscribeMsgService, io: std.Io, template_id: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("priTmplId", template_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.SubscribeMsg.template_del_url, body);
    }

    /// `getCategory()` (接口 :128 / impl :98-103)。
    /// GET wxaapi/newtmpl/getcategory(无 query)→ 解析 `data` 数组 → `[]CategoryData`。
    /// 所有权:切片逐元素 `deinit()` + `free(slice)`。
    pub fn getCategory(self: *SubscribeMsgService, io: std.Io) WxResult([]CategoryData) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self, io, api_url.SubscribeMsg.get_category_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getcategory not json", .{}),
        };
        defer parsed.deinit();
        const list = parseDataArray(CategoryData, gpa, parsed.value) catch return .{
            .err = WxError.internal(gpa, "parse category failed", .{}),
        };
        return .{ .ok = list };
    }

    /// `send(subscribeMessage)` (接口 :140 / impl :106-113)。
    /// POST cgi-bin/message/subscribe/bizsend,body = `subscribeMessage.toJson()`;
    /// 解析 `msgid`(errcode!=0 已由 Service 折叠为 .err)。
    /// 所有权:返回 `[]const u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn send(self: *SubscribeMsgService, io: std.Io, msg: SubscribeMessage) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = SubscribeMessage.toJson(gpa, msg) catch |e| return .{
            .err = WxError.internal(gpa, "build bizsend body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (apiPost(self, io, api_url.SubscribeMsg.send_subscribe_message_url, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "bizsend not json", .{}),
        };
        defer parsed.deinit();
        const msgid = msgIdFromJson(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = msgid };
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试(URL / method / 请求体 / 响应字段 / 所有权)
// 记录型 executor:捕获 method/uri/body,按 uri 子串返回预置响应(取第一个命中)。
// ---------------------------------------------------------------------------

const Recorder = struct {
    const Entry = struct { match: []const u8, response: []const u8 };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    fn uri(self: *const Recorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const Recorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
    fn executor(self: *Recorder) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = @tagName(method);
        self.last_uri_len = @min(target.len, self.last_uri.len);
        @memcpy(self.last_uri[0..self.last_uri_len], target[0..self.last_uri_len]);
        const b = payload orelse "";
        self.last_body_len = @min(b.len, self.last_body.len);
        @memcpy(self.last_body[0..self.last_body_len], b[0..self.last_body_len]);
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, target, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{
                    .err = error_mod.WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = error_mod.WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }
    const vtable = http_mod.RequestExecutor.VTable{ .execute = executeImpl };
};

const FakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = c;
        _ = i;
        const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = t, .expires_in = 7200 } };
    }
};

fn setup(
    gpa: std.mem.Allocator,
    mock: *Recorder,
    threaded: *std.Io.Threaded,
    cfg: *config_mod.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try config_mod.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), mock.executor());
}

test "subscribeMsgAuthorizationUrl: 精确 URL 形状(MP host / scene / redirect 编码) + 纯本地无 HTTP" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{} };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    const url = try svc.subscribeMsgAuthorizationUrl("https://example.com/callback?x=1", 1000, "TPL1", "RES");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://mp.weixin.qq.com/mp/subscribemsg?action=get_confirm&appid=A&scene=1000&template_id=TPL1&redirect_url=https%3A%2F%2Fexample.com%2Fcallback%3Fx%3D1&reserved=RES#wechat_redirect",
        url,
    );
    // rule 1:纯 URL 构造,不产生任何 HTTP 调用
    try testing.expectEqual(@as(usize, 0), mock.calls);
}

test "send: 全字段请求体 + msgid 解析 + 绝对 URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/subscribe/bizsend", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":456}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    switch (svc.send(threaded.io(), .{
        .to_user = "oABC",
        .template_id = "TPL1",
        .url = "https://example.com",
        .page = "pages/index",
        .miniprogram = .{ .appid = "wxmp1", .page_path = "pages/detail" },
        .scene = "1001",
        .title = "订单通知",
        .data = &.{
            .{ .name = "thing1", .value = "你好" },
            .{ .name = "amount2", .value = "10.00" },
        },
    })) {
        .ok => |msgid| {
            defer gpa.free(msgid);
            try testing.expectEqualStrings("456", msgid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/cgi-bin/message/subscribe/bizsend") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"touser\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"template_id\":\"TPL1\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"url\":\"https://example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"page\":\"pages/index\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"miniprogram\":{\"appid\":\"wxmp1\",\"pagepath\":\"pages/detail\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"scene\":\"1001\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"title\":\"订单通知\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"thing1\":{\"value\":\"你好\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"amount2\":{\"value\":\"10.00\"}") != null);

    // use_path=true → path(Java WxMpSubscribeMessage.MiniProgram.usePath 分支)
    const body2 = SubscribeMessage.toJson(gpa, .{
        .to_user = "oX",
        .template_id = "T",
        .miniprogram = .{ .appid = "a", .page_path = "p", .use_path = true },
    }) catch return error.Unexpected;
    defer gpa.free(body2);
    try testing.expect(std.mem.indexOf(u8, body2, "\"miniprogram\":{\"appid\":\"a\",\"path\":\"p\"}") != null);

    // content 分支(Java dataMap==null -> data.content.{value,color})
    const body3 = SubscribeMessage.toJson(gpa, .{
        .to_user = "oX",
        .template_id = "T",
        .content_value = "订阅内容",
        .content_color = "#FF0000",
    }) catch return error.Unexpected;
    defer gpa.free(body3);
    try testing.expect(std.mem.indexOf(u8, body3, "\"data\":{\"content\":{\"value\":\"订阅内容\",\"color\":\"#FF0000\"}}") != null);
}

test "send: 最小请求(data 空对象) + errcode!=0 折叠为 .err" {
    const gpa = testing.allocator;
    {
        var mock = Recorder{ .gpa = gpa, .entries = &.{
            .{ .match = "bizsend", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"MSG1\"}" },
        } };
        var threaded: std.Io.Threaded = undefined;
        var cfg: config_mod.InMemoryConfigStorage = undefined;
        var base: service_mod.Service = undefined;
        try setup(gpa, &mock, &threaded, &cfg, &base);
        defer threaded.deinit();
        defer cfg.deinit();
        var svc = SubscribeMsgService{ .svc = &base };

        switch (svc.send(threaded.io(), .{ .to_user = "oX", .template_id = "T" })) {
            .ok => |msgid| {
                defer gpa.free(msgid);
                try testing.expectEqualStrings("MSG1", msgid);
            },
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        const b = mock.body();
        try testing.expect(std.mem.indexOf(u8, b, "\"data\":{}") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"url\"") == null);
        try testing.expect(std.mem.indexOf(u8, b, "\"page\"") == null);
        try testing.expect(std.mem.indexOf(u8, b, "miniprogram") == null);
        try testing.expect(std.mem.indexOf(u8, b, "\"scene\"") == null);
        try testing.expect(std.mem.indexOf(u8, b, "\"title\"") == null);
    }
    {
        var mock = Recorder{ .gpa = gpa, .entries = &.{
            .{ .match = "bizsend", .response = "{\"errcode\":43101,\"errmsg\":\"user refuse to accept the msg\"}" },
        } };
        var threaded: std.Io.Threaded = undefined;
        var cfg: config_mod.InMemoryConfigStorage = undefined;
        var base: service_mod.Service = undefined;
        try setup(gpa, &mock, &threaded, &cfg, &base);
        defer threaded.deinit();
        defer cfg.deinit();
        var svc = SubscribeMsgService{ .svc = &base };
        switch (svc.send(threaded.io(), .{ .to_user = "oU", .template_id = "T" })) {
            .ok => |msgid| {
                gpa.free(msgid);
                return error.Unexpected;
            },
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                try testing.expectEqual(@as(i64, 43101), err.error_code);
            },
        }
    }
}

test "sendOnce: 不同端点(template/subscribe) + Done" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/template/subscribe", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    switch (svc.sendOnce(threaded.io(), .{
        .to_user = "oABC",
        .template_id = "TPL1",
        .scene = "1000",
        .content_value = "Send subscribe message test",
        .content_color = "#FF0000",
    })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/cgi-bin/message/template/subscribe") != null);
    // 与 send 的端点区分:不含 bizsend
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "bizsend") == null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"data\":{\"content\":{\"value\":\"Send subscribe message test\",\"color\":\"#FF0000\"}}") != null);
}

test "getPubTemplateTitleList: ids/start/limit query + count/data 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getpubtemplatetitles", .response = "{\"errcode\":0,\"count\":2,\"data\":[{\"tid\":10,\"type\":2,\"categoryId\":\"1\",\"title\":\"标题A\"},{\"tid\":11,\"title\":\"标题B\"}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    const ids = [_][]const u8{ "1", "2", "3" };
    switch (svc.getPubTemplateTitleList(threaded.io(), &ids, 0, 30)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit(); // 逐元素 deinit + free 切片(无泄漏)
            try testing.expectEqual(@as(i64, 2), res.count);
            try testing.expectEqual(@as(usize, 2), res.data.len);
            try testing.expectEqual(@as(i64, 10), res.data[0].tid.?);
            try testing.expectEqualStrings("标题A", res.data[0].title.?);
            try testing.expectEqualStrings("1", res.data[0].category_id.?);
            try testing.expectEqualStrings("标题B", res.data[1].title.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/wxaapi/newtmpl/getpubtemplatetitles") != null);
    // mp_helpers.buildUrl:urlEncode 把逗号编成 %2C,顺序 ids/start/limit
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "ids=1%2C2%2C3") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "start=0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "limit=30") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}

test "getPubTemplateKeyWordsById: tid query + data 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getpubtemplatekeywords", .response = "{\"errcode\":0,\"data\":[{\"kid\":1,\"name\":\"姓名\",\"example\":\"张三\",\"rule\":\"\"},{\"kid\":2,\"name\":\"时间\"}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    switch (svc.getPubTemplateKeyWordsById(threaded.io(), "TID9")) {
        .ok => |list| {
            defer {
                for (list) |*it| {
                    var tmp = it.*;
                    tmp.deinit();
                }
                if (list.len != 0) gpa.free(list);
            }
            try testing.expectEqual(@as(usize, 2), list.len);
            try testing.expectEqual(@as(i64, 1), list[0].kid);
            try testing.expectEqualStrings("姓名", list[0].name.?);
            try testing.expectEqualStrings("张三", list[0].example.?);
            try testing.expectEqualStrings("时间", list[1].name.?);
            try testing.expect(list[1].example == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "tid=TID9") != null);
}

test "addTemplate: tid/kidList/sceneDesc 请求体 + priTmplId 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "addtemplate", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"priTmplId\":\"PRI_TPL_1\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    const kids = [_]i64{ 1, 2, 3 };
    switch (svc.addTemplate(threaded.io(), "TID1", &kids, "订单场景")) {
        .ok => |tid| {
            defer gpa.free(tid);
            try testing.expectEqualStrings("PRI_TPL_1", tid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/wxaapi/newtmpl/addtemplate") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"tid\":\"TID1\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"kidList\":[1,2,3]") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"sceneDesc\":\"订单场景\"") != null);
}

test "getTemplateList / getCategory / delTemplate: GET/POST + 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "newtmpl/gettemplate", .response = "{\"errcode\":0,\"data\":[{\"priTmplId\":\"P1\",\"title\":\"t1\",\"content\":\"c1\",\"example\":\"e1\",\"type\":2}]}" },
        .{ .match = "newtmpl/getcategory", .response = "{\"errcode\":0,\"data\":[{\"id\":1,\"name\":\"类目A\"},{\"id\":2,\"name\":\"类目B\"}]}" },
        .{ .match = "newtmpl/deltemplate", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };
    const io = threaded.io();

    // getTemplateList:GET 无 query,解析 data 数组
    switch (svc.getTemplateList(io)) {
        .ok => |list| {
            defer {
                for (list) |*it| {
                    var tmp = it.*;
                    tmp.deinit();
                }
                if (list.len != 0) gpa.free(list);
            }
            try testing.expectEqual(@as(usize, 1), list.len);
            try testing.expectEqualStrings("P1", list[0].pri_tmpl_id.?);
            try testing.expectEqualStrings("c1", list[0].content.?);
            try testing.expectEqual(@as(i64, 2), list[0].type_);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "wxaapi/newtmpl/gettemplate") != null);

    // getCategory:GET 无 query,解析 data 数组
    switch (svc.getCategory(io)) {
        .ok => |list| {
            defer {
                for (list) |*it| {
                    var tmp = it.*;
                    tmp.deinit();
                }
                if (list.len != 0) gpa.free(list);
            }
            try testing.expectEqual(@as(usize, 2), list.len);
            try testing.expectEqual(@as(i64, 1), list[0].id);
            try testing.expectEqualStrings("类目A", list[0].name.?);
            try testing.expectEqualStrings("类目B", list[1].name.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "wxaapi/newtmpl/getcategory") != null);

    // delTemplate:POST {"priTmplId"}
    switch (svc.delTemplate(io, "P1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "wxaapi/newtmpl/deltemplate") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"priTmplId\":\"P1\"") != null);
}
