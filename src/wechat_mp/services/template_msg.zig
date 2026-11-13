//! 模板消息服务 —— 逐字对齐 Java `api.WxMpTemplateMsgService`(7 方法)
//! + `api.impl.WxMpTemplateMsgServiceImpl`。
//!
//! 命名:全部采用 Java 的 camelCase 方法名(rule 2)。Java 的 `addTemplate` 两个重载
//! 用 Zig 惯用法映射为一个函数 + 可选 `keyword_name_list`(rule 1):
//!   - `addTemplate(String)`                       → `addTemplate(io, short_id, null)`
//!   - `addTemplate(String, List<String>)`         → `addTemplate(io, short_id, &.{...})`
//!
//! 底座(rule 3):
//!   - 所有 URL 路径来自 `../api_url.zig:TemplateMsg`,经 `api()`(= `api_url.url(Host.api, path)`)
//!     拼成绝对 URL;旧 `service_mod.api_host_url`/`apiUri`/本地 `Path` 全部移除;
//!   - 扁平 JSON 请求体(setIndustry / delPrivateTemplate / addTemplate)用
//!     `common.json_util.ObjectBuilder`;复杂嵌套消息体 `TemplateMessage.toJson` 仍用
//!     `std.Io.Writer.Allocating`(与 `user.zig` 的 batchGetBody 同构);
//!   - 本服务 6 个端点均无 query 参数,故无需 `mp_helpers.buildUrl`(它用于订阅服务里
//!     带 query 的端点);`Service.execute*` 已折叠 errcode→`.err` 并注入 access_token。
//!
//! Java↔Zig 语言差异(已按 Java 逻辑取舍,逐条说明):
//!   - `setIndustry`: Java 入参 `WxMpTemplateIndustry`,其 `WxMpIndustryGsonAdapter#serialize`
//!     只取 primary/second 两个枚举的 `code`(Integer)→ `{"industry_id1":N,"industry_id2":N}`。
//!     **旧 Zig 误拼成 `{"primary_industry","secondary_industry"}` 且值为名称,本轮纠正为
//!     industry_id1/industry_id2 数值**。Zig 直接以两个 `i64` code 表达(去掉枚举查表,
//!     类型系统天然保证「行业Id不能为空」这条 Java 运行时校验)。
//!   - `getIndustry`: Java `WxMpIndustryGsonAdapter#deserialize` 读 `primary_industry` /
//!     `secondary_industry` 两个对象里的 `first_class`/`second_class`,本轮原样保留原始
//!     文字(比 Java 反查枚举更贴近报文,且是「创建/获取数据结构不一样」的如实映射)。
//!   - `getAllPrivateTemplate`: Java `WxMpTemplate` 的二级行业字段名是 `deputy_industry`
//!     (`@SerializedName`),**旧 Zig 误作 `secondary_industry`,本轮纠正**。
//!   - `sendTemplateMsg` 的 `msgid`、addTemplate 的 `template_id`:Java Gson `getAsString`
//!     数字/字符串都能取,本轮兼容二者且恒定返回 gpa 拥有串(缺失时 dupe 空串),
//!     避免调用方 free 静态串。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `[]const u8` 裸结果(msgid / template_id):`gpa.free()`;
//!   - `Industry`:`deinit()`(两个 IndustryClass 的字符串);
//!   - `[]TemplateInfo`:逐元素 `deinit()` + `free(slice)`(len!=0 时);
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;
const token_mod = @import("common").token;

const api_url = @import("../api_url.zig");
const config_mod = @import("../config.zig");
const http_mod = @import("../http.zig");
const service_mod = @import("../service.zig");

/// host+path 绝对 URL,路径全部取自 `api_url.zig:TemplateMsg`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// JSON 字符串编码(手写消息体复用,与 `user.zig` 的 jw.str 同构)。
fn encStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
}

/// 取 JSON 字符串字段并 dupe 成 gpa 拥有(缺失返回 null)。对应 Java `GsonHelper.getString`。
fn dupeStr(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    const s = json_util.getStr(v, key) orelse return null;
    return try gpa.dupe(u8, s);
}

/// msgid 可能是字符串也可能是数字(Java Gson `getAsString` 两种都能取),统一 dupe 成
/// gpa 拥有的字符串;缺失时 dupe 空串,保证调用方 `gpa.free` 始终合法。
fn msgIdFromJson(gpa: std.mem.Allocator, v: json_util.Value) ![]const u8 {
    if (json_util.getStr(v, "msgid")) |s| return try gpa.dupe(u8, s);
    if (json_util.getInt(v, "msgid")) |n| return try std.fmt.allocPrint(gpa, "{d}", .{n});
    return try gpa.dupe(u8, "");
}

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 行业一/二级分类 —— 对应 Java `WxMpTemplateIndustry.Industry` 反序列化形态
/// (get_industry 响应里的 {first_class, second_class},全部 gpa 拥有)。
pub const IndustryClass = struct {
    gpa: std.mem.Allocator,
    first_class: ?[]const u8 = null,
    second_class: ?[]const u8 = null,

    pub fn deinit(self: *IndustryClass) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.first_class, self.second_class }) |s| {
            if (s) |v| g.free(@constCast(v));
        }
    }

    fn fromObj(gpa: std.mem.Allocator, o: json_util.ObjectMap) !IndustryClass {
        const ov = json_util.Value{ .object = o };
        var c = IndustryClass{ .gpa = gpa };
        errdefer c.deinit();
        if (json_util.getStr(ov, "first_class")) |s| c.first_class = try gpa.dupe(u8, s);
        if (json_util.getStr(ov, "second_class")) |s| c.second_class = try gpa.dupe(u8, s);
        return c;
    }
};

/// get_industry 结果:primary/secondary 两行行业信息。
pub const Industry = struct {
    gpa: std.mem.Allocator,
    primary: ?IndustryClass = null,
    secondary: ?IndustryClass = null,

    pub fn deinit(self: *Industry) void {
        if (self.primary) |*c| c.deinit();
        if (self.secondary) |*c| c.deinit();
    }
};

/// 私有模板列表项 —— 对应 Java `bean.template.WxMpTemplate`
/// (@SerializedName: template_id/title/primary_industry/deputy_industry/content/example,
/// 全部 gpa 拥有)。
pub const TemplateInfo = struct {
    gpa: std.mem.Allocator,
    template_id: []const u8 = "",
    title: []const u8 = "",
    primary_industry: ?[]const u8 = null,
    deputy_industry: ?[]const u8 = null,
    content: ?[]const u8 = null,
    example: ?[]const u8 = null,

    pub fn deinit(self: *TemplateInfo) void {
        const g = self.gpa;
        for ([_]?[]const u8{
            self.template_id,
            self.title,
            self.primary_industry,
            self.deputy_industry,
            self.content,
            self.example,
        }) |s| if (s) |v| g.free(@constCast(v));
    }

    fn optDupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        const s = json_util.getStr(v, key) orelse return null;
        return try gpa.dupe(u8, s);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !TemplateInfo {
        var t = TemplateInfo{
            .gpa = gpa,
            .template_id = try gpa.dupe(u8, json_util.getStrOr(v, "template_id", "")),
            .title = try gpa.dupe(u8, json_util.getStrOr(v, "title", "")),
        };
        errdefer t.deinit();
        t.primary_industry = try optDupe(gpa, v, "primary_industry");
        t.deputy_industry = try optDupe(gpa, v, "deputy_industry");
        t.content = try optDupe(gpa, v, "content");
        t.example = try optDupe(gpa, v, "example");
        return t;
    }
};

/// 模板消息占位符数据项 —— 对应 Java `bean.template.WxMpTemplateData`。
pub const TemplateData = struct {
    name: []const u8,
    value: []const u8,
    color: ?[]const u8 = null,
};

/// 跳小程序数据 —— 对应 Java `WxMpTemplateMessage.MiniProgram`:
/// `use_path` 为 true 时序列化成 `path`,否则 `pagepath`(微信接口改版兼容留的开关)。
pub const MiniProgram = struct {
    appid: []const u8,
    page_path: []const u8 = "",
    use_path: bool = false,
};

/// 待发送模板消息 —— 对应 Java `bean.template.WxMpTemplateMessage`
/// (toUser/templateId/url/miniProgram/clientMsgId/data;Java 无 topurl 字段,本轮去除)。
pub const TemplateMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    url: ?[]const u8 = null,
    client_msg_id: ?[]const u8 = null,
    mini_program: ?MiniProgram = null,
    data: []const TemplateData = &.{},

    /// 序列化为请求体 JSON —— 对应 `WxMpTemplateMessageGsonAdapter#serialize`:
    /// `{touser, template_id, client_msg_id?(非空), url?, miniprogram{appid, pagepath|path}?,
    ///   data:{key:{value,color?}}}`。
    fn toJson(gpa: std.mem.Allocator, m: TemplateMessage) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"touser\":");
        try encStr(w, m.to_user);
        try w.writeAll(",\"template_id\":");
        try encStr(w, m.template_id);
        if (m.client_msg_id) |c| {
            if (c.len > 0) { // Java: StringUtils.isNotBlank
                try w.writeAll(",\"client_msg_id\":");
                try encStr(w, c);
            }
        }
        if (m.url) |u| {
            try w.writeAll(",\"url\":");
            try encStr(w, u);
        }
        if (m.mini_program) |mp| {
            try w.writeAll(",\"miniprogram\":{\"appid\":");
            try encStr(w, mp.appid);
            try w.writeAll(if (mp.use_path) ",\"path\":" else ",\"pagepath\":");
            try encStr(w, mp.page_path);
            try w.writeByte('}');
        }
        // data:{name:{value,color?}},对应适配器里遍历 WxMpTemplateData 的循环
        try w.writeAll(",\"data\":{");
        for (m.data, 0..) |d, i| {
            if (i != 0) try w.writeByte(',');
            try encStr(w, d.name);
            try w.writeAll(":{\"value\":");
            try encStr(w, d.value);
            if (d.color) |c| {
                try w.writeAll(",\"color\":");
                try encStr(w, c);
            }
            try w.writeByte('}');
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// `template_list` 数组 → `[]TemplateInfo`(对应 `WxMpTemplate.fromJson` 取 template_list)。
fn parseTemplateList(gpa: std.mem.Allocator, root: json_util.Value) ![]TemplateInfo {
    const arr = json_util.getArray(root, "template_list") orelse return &[_]TemplateInfo{};
    var list: std.ArrayList(TemplateInfo) = .empty;
    errdefer {
        for (list.items) |*t| {
            var tmp = t.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    for (arr.items) |item| try list.append(gpa, try TemplateInfo.fromJson(gpa, item));
    return list.toOwnedSlice(gpa);
}

/// `{"template_id_short":"..","keyword_name_list":["..",...]}` —— 对应 Java
/// `addTemplate(shortTemplateId, keywordNameList)` 里 Gson JsonObject + JsonArray 的组包。
fn buildAddTemplateBody(gpa: std.mem.Allocator, short_id: []const u8, keywords: []const []const u8) ![]u8 {
    var arr: std.ArrayList(json_util.Value) = .empty;
    defer arr.deinit(gpa);
    for (keywords) |k| try arr.append(gpa, .{ .string = k });
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("template_id_short", short_id);
    // ArrayList 按值拷进 map,底层缓冲仍由上面的 `arr` 释放一次
    try ob.putValue("keyword_name_list", .{ .array = arr });
    return ob.toJson();
}

// ---------------------------------------------------------------------------
// 请求/响应辅助(host → svc.get/post,token 附加 + errcode 折叠 + 重试都在 Service)
// ---------------------------------------------------------------------------

fn apiGet(self: *TemplateMsgService, io: std.Io, comptime path: []const u8) WxResult([]u8) {
    return self.svc.get(io, api(path), &.{});
}

fn apiPost(self: *TemplateMsgService, io: std.Io, comptime path: []const u8, body: []const u8) WxResult([]u8) {
    return self.svc.post(io, api(path), &.{}, body);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 `Service.executeInternal` 折叠为 .err)。
fn postVoid(self: *TemplateMsgService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(self, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// TemplateMsgService —— 对应 Java `WxMpTemplateMsgService`(7 方法) + Impl
// ---------------------------------------------------------------------------

pub const TemplateMsgService = struct {
    svc: *service_mod.Service,

    /// `WxMpTemplateMsgService.setIndustry(WxMpTemplateIndustry)` (接口 :46 / impl :44-52)。
    /// POST cgi-bin/template/api_set_industry,body = `WxMpIndustryGsonAdapter#serialize`
    /// 产出的 `{"industry_id1":N,"industry_id2":N}`(两个行业 code);返回 Done。
    /// Java 对 null code 抛 IllegalArgumentException,Zig 以 `i64` 参数在类型层规避。
    pub fn setIndustry(self: *TemplateMsgService, io: std.Io, industry_id1: i64, industry_id2: i64) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("industry_id1", industry_id1) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("industry_id2", industry_id2) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.TemplateMsg.template_api_set_industry, body);
    }

    /// `WxMpTemplateMsgService.getIndustry()` (接口 :67 / impl :55-58)。
    /// GET cgi-bin/template/get_industry → `WxMpTemplateIndustry.fromJson` → Industry。
    pub fn getIndustry(self: *TemplateMsgService, io: std.Io) WxResult(Industry) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self, io, api_url.TemplateMsg.template_get_industry)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "get_industry not json", .{}),
        };
        defer parsed.deinit();

        var ind = Industry{ .gpa = gpa };
        errdefer ind.deinit();
        if (json_util.objectOf(parsed.value, "primary_industry")) |o| {
            ind.primary = IndustryClass.fromObj(gpa, o) catch return .{
                .err = WxError.internal(gpa, "oom", .{}),
            };
        }
        if (json_util.objectOf(parsed.value, "secondary_industry")) |o| {
            ind.secondary = IndustryClass.fromObj(gpa, o) catch return .{
                .err = WxError.internal(gpa, "oom", .{}),
            };
        }
        return .{ .ok = ind };
    }

    /// `WxMpTemplateMsgService.getAllPrivateTemplate()` (接口 :161 / impl :85-87)。
    /// GET cgi-bin/template/get_all_private_template → 解析 `template_list` 数组。
    /// 所有权:切片逐元素 `TemplateInfo.deinit()`;`len != 0` 时再 `free(slice)` 本身。
    pub fn getAllPrivateTemplate(self: *TemplateMsgService, io: std.Io) WxResult([]TemplateInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self, io, api_url.TemplateMsg.template_get_all_private_template)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "get_all_private_template not json", .{}),
        };
        defer parsed.deinit();
        const list = parseTemplateList(gpa, parsed.value) catch return .{
            .err = WxError.internal(gpa, "parse template list failed", .{}),
        };
        return .{ .ok = list };
    }

    /// `WxMpTemplateMsgService.delPrivateTemplate(templateId)` (接口 :184 / impl :90-100)。
    /// POST cgi-bin/template/del_private_template {"template_id"} → Done。
    pub fn delPrivateTemplate(self: *TemplateMsgService, io: std.Io, template_id: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("template_id", template_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.TemplateMsg.template_del_private_template, body);
    }

    /// `WxMpTemplateMsgService.addTemplate(String)` (接口 :114,deprecated) /
    /// `addTemplate(String, List<String>)` (接口 :139,impl :66-82) —— 合并为一个函数 + 可选
    /// keyword_name_list(rule 1)。`null` 等价于 Java 的 `Collections.emptyList()`。
    /// POST cgi-bin/template/api_add_template
    /// `{"template_id_short":"..","keyword_name_list":[...]}` → 返回 template_id。
    /// 所有权:返回 `[]const u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn addTemplate(self: *TemplateMsgService, io: std.Io, short_template_id: []const u8, keyword_name_list: ?[]const []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = buildAddTemplateBody(gpa, short_template_id, keyword_name_list orelse &.{}) catch |e| return .{
            .err = WxError.internal(gpa, "build add_template body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (apiPost(self, io, api_url.TemplateMsg.template_api_add_template, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "add_template not json", .{}),
        };
        defer parsed.deinit();
        const tid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "template_id", "")) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = tid };
    }

    /// `WxMpTemplateMsgService.sendTemplateMsg(templateMessage)` (接口 :89 / impl :34-41)。
    /// POST cgi-bin/message/template/send,body = `templateMessage.toJson()`;解析 `msgid`
    /// (Java `get("msgid").getAsString()`,数字/字符串均可)。所有权:调用方 `gpa.free()`。
    pub fn sendTemplateMsg(self: *TemplateMsgService, io: std.Io, msg: TemplateMessage) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = TemplateMessage.toJson(gpa, msg) catch |e| return .{
            .err = WxError.internal(gpa, "build template send body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (apiPost(self, io, api_url.TemplateMsg.message_template_send, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "template send not json", .{}),
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

/// 统一搭建测试环境(out 参数写回,避免 `Service` 里保存的 config 指针悬垂)。
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

test "sendTemplateMsg: 请求体结构 + msgid 解析 + errcode!=0 + api_url 绝对 URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/template/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":123}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = TemplateMsgService{ .svc = &base };

    const r = svc.sendTemplateMsg(threaded.io(), .{
        .to_user = "oABC",
        .template_id = "TPL1",
        .url = "https://example.com",
        .client_msg_id = "cid1",
        .mini_program = .{ .appid = "wxmp1", .page_path = "pages/index" },
        .data = &.{
            .{ .name = "first", .value = "hello", .color = "#FF0000" },
            .{ .name = "remark", .value = "bye" },
        },
    });
    switch (r) {
        .ok => |msgid| {
            defer gpa.free(msgid);
            try testing.expectEqualStrings("123", msgid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    // URL 来自 api_url.zig:Host.api + TemplateMsg.message_template_send
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/cgi-bin/message/template/send") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"touser\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"template_id\":\"TPL1\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"url\":\"https://example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"client_msg_id\":\"cid1\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"first\":{\"value\":\"hello\",\"color\":\"#FF0000\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"remark\":{\"value\":\"bye\"}") != null);
    // mini_program:默认 use_path=false → pagepath(对应 Java MiniProgram 序列化)
    try testing.expect(std.mem.indexOf(u8, b, "\"miniprogram\":{\"appid\":\"wxmp1\",\"pagepath\":\"pages/index\"}") != null);

    // use_path=true → path(WxMpTemplateMessage.MiniProgram.usePath 分支)
    const body2 = TemplateMessage.toJson(gpa, .{
        .to_user = "oX",
        .template_id = "t",
        .mini_program = .{ .appid = "a", .page_path = "p", .use_path = true },
    }) catch return error.Unexpected;
    defer gpa.free(body2);
    try testing.expect(std.mem.indexOf(u8, body2, "\"miniprogram\":{\"appid\":\"a\",\"path\":\"p\"}") != null);

    // 失败路径:errcode=45009(非 token 类错误,不触发自动刷新重试)
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/template/send", .response = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = TemplateMsgService{ .svc = &base2 };
    const r2 = svc2.sendTemplateMsg(th2.io(), .{ .to_user = "o", .template_id = "t" });
    switch (r2) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45009), err.error_code);
        },
    }
}

test "setIndustry / getIndustry / getAllPrivateTemplate / delPrivateTemplate" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "api_set_industry", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "get_industry", .response = "{\"errcode\":0,\"primary_industry\":{\"first_class\":\"IT科技\",\"second_class\":\"IT科技|运营商\"},\"secondary_industry\":{\"first_class\":\"教育\",\"second_class\":\"教育|培训\"}}" },
        .{ .match = "get_all_private_template", .response = "{\"errcode\":0,\"template_list\":[{\"template_id\":\"T1\",\"title\":\"订阅成功通知\",\"primary_industry\":\"IT科技\",\"deputy_industry\":\"互联网|电子商务\",\"content\":\"c1\"},{\"template_id\":\"T2\",\"title\":\"t2\"}]}" },
        .{ .match = "del_private_template", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = TemplateMsgService{ .svc = &base };
    const io = threaded.io();

    // set_industry:WxMpIndustryGsonAdapter 产出 {"industry_id1":N,"industry_id2":N}
    switch (svc.setIndustry(io, 1, 4)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/cgi-bin/template/api_set_industry") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"industry_id1\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"industry_id2\":4") != null);
    // 旧版误拼的字段不应再出现
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"primary_industry\"") == null);

    // get_industry
    switch (svc.getIndustry(io)) {
        .ok => |*v| {
            var ind = v.*;
            defer ind.deinit();
            try testing.expectEqualStrings("IT科技", ind.primary.?.first_class.?);
            try testing.expectEqualStrings("教育|培训", ind.secondary.?.second_class.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/template/get_industry") != null);

    // get_all_private_template:字段名 deputy_industry(纠正旧版 secondary_industry)
    switch (svc.getAllPrivateTemplate(io)) {
        .ok => |list| {
            defer {
                for (list) |*t| {
                    var tmp = t.*;
                    tmp.deinit();
                }
                if (list.len != 0) gpa.free(list);
            }
            try testing.expectEqual(@as(usize, 2), list.len);
            try testing.expectEqualStrings("T1", list[0].template_id);
            try testing.expectEqualStrings("订阅成功通知", list[0].title);
            try testing.expectEqualStrings("互联网|电子商务", list[0].deputy_industry.?);
            try testing.expectEqualStrings("c1", list[0].content.?);
            try testing.expect(list[1].content == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // del_private_template
    switch (svc.delPrivateTemplate(io, "T1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"template_id\":\"T1\"") != null);
}

test "addTemplate 两个 Java 重载(1 参数 / 2 参数)+ template_id 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "api_add_template", .response = "{\"errcode\":0,\"template_id\":\"NEW_TPL\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = TemplateMsgService{ .svc = &base };
    const io = threaded.io();

    // 重载 1:addTemplate(String) —— Java 委托 Collections.emptyList() → 空 keyword_name_list
    switch (svc.addTemplate(io, "TPL_SHORT", null)) {
        .ok => |tid| {
            defer gpa.free(tid);
            try testing.expectEqualStrings("NEW_TPL", tid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://api.weixin.qq.com/cgi-bin/template/api_add_template") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"template_id_short\":\"TPL_SHORT\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"keyword_name_list\":[]") != null);

    // 重载 2:addTemplate(String, List<String>) —— 关键词按序写入 keyword_name_list
    switch (svc.addTemplate(io, "TPL_SHORT", &.{ "a", "b" })) {
        .ok => |tid| {
            defer gpa.free(tid);
            try testing.expectEqualStrings("NEW_TPL", tid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"keyword_name_list\":[\"a\",\"b\"]") != null);
}
