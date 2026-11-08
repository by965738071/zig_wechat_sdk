//! 模板消息服务 —— 对应 Java `api.WxMpTemplateMsgService` + `api.impl.WxMpTemplateMsgServiceImpl`。
//!
//! 子服务样板(参照 `user.zig`):结构体持有 parent `Service` 引用(组合而非继承),
//! 方法 = 拼 uri → service.get/post → json_util 解析成结果结构。
//! URL 以 Java 枚举 `enums.WxMpApiUrl.TemplateMsg` 为准:
//! - MESSAGE_TEMPLATE_SEND             → cgi-bin/message/template/send
//! - TEMPLATE_API_SET_INDUSTRY         → cgi-bin/template/api_set_industry
//! - TEMPLATE_GET_INDUSTRY             → cgi-bin/template/get_industry
//! - TEMPLATE_API_ADD_TEMPLATE         → cgi-bin/template/api_add_template
//! - TEMPLATE_GET_ALL_PRIVATE_TEMPLATE → cgi-bin/template/get_all_private_template
//! - TEMPLATE_DEL_PRIVATE_TEMPLATE     → cgi-bin/template/del_private_template
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 行业一/二级分类 —— 对应 Java `bean.template.WxMpTemplateIndustry.Industry`
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

/// 私有模板列表项 —— 对应 Java `bean.template.WxMpTemplate`(全部 gpa 拥有)。
pub const TemplateInfo = struct {
    gpa: std.mem.Allocator,
    template_id: []const u8 = "",
    title: []const u8 = "",
    primary_industry: ?[]const u8 = null,
    secondary_industry: ?[]const u8 = null,
    content: ?[]const u8 = null,
    example: ?[]const u8 = null,

    pub fn deinit(self: *TemplateInfo) void {
        const g = self.gpa;
        for ([_]?[]const u8{
            self.template_id,
            self.title,
            self.primary_industry,
            self.secondary_industry,
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
        t.secondary_industry = try optDupe(gpa, v, "secondary_industry");
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

/// 待发送模板消息 —— 对应 Java `bean.template.WxMpTemplateMessage`。
pub const TemplateMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    url: ?[]const u8 = null,
    top_url: ?[]const u8 = null,
    client_msg_id: ?[]const u8 = null,
    mini_program: ?MiniProgram = null,
    data: []const TemplateData = &.{},

    /// 序列化为请求体 JSON —— 对应 Java `WxMpTemplateMessageGsonAdapter#serialize`:
    /// `{touser, template_id, url?, topurl?, client_msg_id?,
    ///   miniprogram{appid, pagepath|path}?, data:{key:{value,color?}}}`。
    fn toJson(gpa: std.mem.Allocator, m: TemplateMessage) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        const opts = std.json.Stringify.Options{ .escape_unicode = false };

        try w.writeAll("{\"touser\":");
        try std.json.Stringify.encodeJsonString(m.to_user, opts, w);
        try w.writeAll(",\"template_id\":");
        try std.json.Stringify.encodeJsonString(m.template_id, opts, w);
        if (m.url) |u| {
            try w.writeAll(",\"url\":");
            try std.json.Stringify.encodeJsonString(u, opts, w);
        }
        if (m.top_url) |u| {
            try w.writeAll(",\"topurl\":");
            try std.json.Stringify.encodeJsonString(u, opts, w);
        }
        if (m.client_msg_id) |c| {
            try w.writeAll(",\"client_msg_id\":");
            try std.json.Stringify.encodeJsonString(c, opts, w);
        }
        if (m.mini_program) |mp| {
            try w.writeAll(",\"miniprogram\":{\"appid\":");
            try std.json.Stringify.encodeJsonString(mp.appid, opts, w);
            try w.writeAll(if (mp.use_path) ",\"path\":" else ",\"pagepath\":");
            try std.json.Stringify.encodeJsonString(mp.page_path, opts, w);
            try w.writeByte('}');
        }
        // data:{name:{value,color?}},对应适配器里遍历 WxMpTemplateData 的循环
        try w.writeAll(",\"data\":{");
        for (m.data, 0..) |d, i| {
            if (i != 0) try w.writeByte(',');
            try std.json.Stringify.encodeJsonString(d.name, opts, w);
            try w.writeAll(":{\"value\":");
            try std.json.Stringify.encodeJsonString(d.value, opts, w);
            if (d.color) |c| {
                try w.writeAll(",\"color\":");
                try std.json.Stringify.encodeJsonString(c, opts, w);
            }
            try w.writeByte('}');
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// msgid 可能是字符串也可能是数字(Java Gson `getAsString` 两种都能取),统一转字符串。
fn numOrStrDupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    if (json_util.getStr(v, key)) |s| return try gpa.dupe(u8, s);
    if (json_util.getInt(v, key)) |n| return try std.fmt.allocPrint(gpa, "{d}", .{n});
    return null;
}

/// 拼 api.weixin.qq.com 前缀(uri 交给调用方 free)。
fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiGet(svc: *service_mod.Service, io: std.Io, path: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.get(io, uri, &.{});
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 `Service.executeInternal` 折叠为 .err)。
fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

pub const TemplateMsgService = struct {
    svc: *service_mod.Service,

    /// 对应 `WxMpTemplateMsgServiceImpl#setIndustry`:
    /// POST cgi-bin/template/api_set_industry {primary_industry, secondary_industry}。
    pub fn setIndustry(self: *TemplateMsgService, io: std.Io, primary: []const u8, secondary: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putStr("primary_industry", primary) catch break :build null;
            ob.putStr("secondary_industry", secondary) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build set_industry body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, "cgi-bin/template/api_set_industry", body);
    }

    /// 对应 `WxMpTemplateMsgServiceImpl#getIndustry`:
    /// GET cgi-bin/template/get_industry → 解析 primary/secondary_industry。
    pub fn getIndustry(self: *TemplateMsgService, io: std.Io) WxResult(Industry) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, "cgi-bin/template/get_industry")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "get_industry not json", .{}),
        };
        defer parsed.deinit();

        var ind = Industry{ .gpa = gpa };
        errdefer ind.deinit();
        if (json_util.objectOf(parsed.value, "primary_industry")) |o| {
            ind.primary = IndustryClass.fromObj(gpa, o) catch return .{
                .err = result_mod.WxError.internal(gpa, "oom", .{}),
            };
        }
        if (json_util.objectOf(parsed.value, "secondary_industry")) |o| {
            ind.secondary = IndustryClass.fromObj(gpa, o) catch return .{
                .err = result_mod.WxError.internal(gpa, "oom", .{}),
            };
        }
        return .{ .ok = ind };
    }

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

    /// 对应 `WxMpTemplateMsgServiceImpl#getAllPrivateTemplate`:
    /// GET cgi-bin/template/get_all_private_template → 解析 template_list 数组。
    /// 所有权:切片逐元素 deinit;`len != 0` 时由调用方 `free` 切片本身。
    pub fn getPrivateTemplates(self: *TemplateMsgService, io: std.Io) WxResult([]TemplateInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, "cgi-bin/template/get_all_private_template")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "get_all_private_template not json", .{}),
        };
        defer parsed.deinit();

        const list = parseTemplateList(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.internal(gpa, "parse template list failed", .{}),
        };
        return .{ .ok = list };
    }

    /// 对应 `WxMpTemplateMsgServiceImpl#delPrivateTemplate`:
    /// POST cgi-bin/template/del_private_template {template_id}。
    pub fn delPrivateTemplate(self: *TemplateMsgService, io: std.Io, template_id: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putStr("template_id", template_id) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build del_private_template body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, "cgi-bin/template/del_private_template", body);
    }

    fn buildAddTemplateBody(gpa: std.mem.Allocator, short_id: []const u8, keywords: []const []const u8) ![]u8 {
        var arr: std.ArrayList(json_util.Value) = .empty;
        defer arr.deinit(gpa);
        for (keywords) |k| try arr.append(gpa, .{ .string = k });
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        try ob.putStr("template_id_short", short_id);
        // 注意:ArrayList 按值拷进 map,底层缓冲仍由上面的 `arr` 释放一次
        try ob.putValue("keyword_name_list", .{ .array = arr });
        return ob.toJson();
    }

    /// 对应 `WxMpTemplateMsgServiceImpl#addTemplate(shortTemplateId, keywordNameList)`:
    /// POST cgi-bin/template/api_add_template {template_id_short, keyword_name_list}
    /// → 返回 template_id(allocator 复制,所有权归调用方,用毕 free)。
    pub fn addTemplate(self: *TemplateMsgService, io: std.Io, short_template_id: []const u8, keyword_name_list: []const []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = buildAddTemplateBody(gpa, short_template_id, keyword_name_list) catch |e| return .{
            .err = result_mod.WxError.internal(gpa, "build add_template body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, "cgi-bin/template/api_add_template", body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "add_template not json", .{}),
        };
        defer parsed.deinit();
        const tid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "template_id", "")) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = tid };
    }

    /// 对应 `WxMpTemplateMsgServiceImpl#sendTemplateMsg`:
    /// POST cgi-bin/message/template/send,成功返回 msgid
    /// (Java 用 `jsonObject.get("msgid").getAsString()`,数字/字符串均可)。
    /// 所有权:msgid 由 allocator 复制,调用方用毕 free。
    pub fn send(self: *TemplateMsgService, io: std.Io, msg: TemplateMessage) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = TemplateMessage.toJson(gpa, msg) catch |e| return .{
            .err = result_mod.WxError.internal(gpa, "build template send body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, "cgi-bin/message/template/send", body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "template send not json", .{}),
        };
        defer parsed.deinit();
        const msgid = numOrStrDupe(gpa, parsed.value, "msgid") catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = msgid orelse "" };
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 `user.zig` 的 vtable 方式),
// 额外记录最后一次请求的 method/uri/body 以便断言(固定缓冲,零堆分配)。
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

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

test "template send: 请求体结构 + msgid 解析 + errcode!=0" {
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

    const r = svc.send(threaded.io(), .{
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
            defer gpa.free(@constCast(msgid));
            try testing.expectEqualStrings("123", msgid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/template/send") != null);
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
    const r2 = svc2.send(th2.io(), .{ .to_user = "o", .template_id = "t" });
    switch (r2) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45009), err.error_code);
        },
    }
}

test "template industry / 模板列表 / 删除 / 添加" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "api_set_industry", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "get_industry", .response = "{\"errcode\":0,\"primary_industry\":{\"first_class\":\"IT科技\",\"second_class\":\"IT科技|运营商\"},\"secondary_industry\":{\"first_class\":\"教育\",\"second_class\":\"教育|培训\"}}" },
        .{ .match = "get_all_private_template", .response = "{\"errcode\":0,\"template_list\":[{\"template_id\":\"T1\",\"title\":\"订阅成功通知\",\"primary_industry\":\"IT科技\",\"content\":\"c1\"},{\"template_id\":\"T2\",\"title\":\"t2\"}]}" },
        .{ .match = "del_private_template", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
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

    // set_industry
    switch (svc.setIndustry(io, "IT科技", "教育")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/template/api_set_industry") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"primary_industry\":\"IT科技\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"secondary_industry\":\"教育\"") != null);

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

    // get_all_private_template
    switch (svc.getPrivateTemplates(io)) {
        .ok => |list| {
            defer if (list.len != 0) gpa.free(list);
            try testing.expectEqual(@as(usize, 2), list.len);
            var t0 = list[0];
            defer t0.deinit();
            try testing.expectEqualStrings("T1", t0.template_id);
            try testing.expectEqualStrings("订阅成功通知", t0.title);
            try testing.expectEqualStrings("c1", t0.content.?);
            var t1 = list[1];
            defer t1.deinit();
            try testing.expect(t1.content == null);
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

    // add_template
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
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/template/api_add_template") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"template_id_short\":\"TPL_SHORT\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"keyword_name_list\":[\"a\",\"b\"]") != null);
}
