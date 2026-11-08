//! 统一服务消息 —— 对应 Java `api.WxMaMsgService#sendUniformMsg`
//! (`api.impl.WxMaMsgServiceImpl`;任务书名 `WxMaUniformMessageServiceImpl`,
//! 当前 Java 工程无此类,实现实际在 `WxMaMsgServiceImpl`)。
//!
//! URL 以 Java `constant.WxMaApiUrlConstants.Msg.UNIFORM_MSG_SEND_URL` 为准:
//! https://api.weixin.qq.com/cgi-bin/message/wxopen/template/uniform_send
//! (任务书口述的 /cgi-bin/message/subscribe/uniform 与扁平 body 在本仓库 Java
//! 中不存在,以 Java 为准)。
//!
//! 线格式逐字段对齐 `json.adaptor.WxMaUniformMessageGsonAdapter`:
//! - 公众号模板消息:`{touser, mp_template_msg:{appid?,template_id,url?,
//!   miniprogram:{appid, path|pagePath|pagepath},data?:{k:{value,color?}}}}`;
//! - 小程序模板消息:`{touser, weapp_template_msg:{template_id,page?,form_id?,
//!   data:{k:{value}},emphasis_keyword?}}`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

// --- URL(对应 WxMaApiUrlConstants.Msg) ----------------------------------------

const UNIFORM_MSG_SEND_URL = "https://api.weixin.qq.com/cgi-bin/message/wxopen/template/uniform_send";

/// 写一个 JSON 字符串字面量(带引号与转义;对应 Gson 的 addProperty)。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn fold(gpa: std.mem.Allocator, ctx: []const u8, e: anyerror) WxError {
    return WxError.transport(gpa, "{s}: {s}", .{ ctx, @errorName(e) });
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaTemplateData`(公众号分支的 data 项可带 color;小程序分支忽略 color,
/// 与 adapter 一致)。
pub const TemplateData = struct { name: []const u8, value: []const u8, color: ?[]const u8 = null };

/// 对应 `WxMaUniformMessage.MiniProgram`。Java 用 `use_path`/`use_page_path`
/// 两个开关决定最终输出 path/pagePath/pagepath(默认 pagepath),保留同样的开关。
pub const MiniProgram = struct {
    appid: []const u8,
    page_path: ?[]const u8 = null,
    use_path: bool = false,
    use_page_path: bool = false,
};

/// 对应 `bean.WxMaUniformMessage`(序列化见 `WxMaUniformMessageGsonAdapter`)。
pub const UniformMessage = struct {
    /// 对应 `isMpTemplateMsg`:true 走 mp_template_msg 分支,否则 weapp_template_msg。
    is_mp_template_msg: bool = false,
    to_user: []const u8,
    appid: ?[]const u8 = null,
    template_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    page: ?[]const u8 = null,
    form_id: ?[]const u8 = null,
    mini_program: ?MiniProgram = null,
    data: []const TemplateData = &.{},
    emphasis_keyword: ?[]const u8 = null,

    /// 对应 `WxMaUniformMessage.toJson()`(adapter 手写序列化,逐字段对齐)。
    pub fn to_json(self: UniformMessage, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"touser\":");
        try js(w, self.to_user);
        if (self.is_mp_template_msg) {
            try w.writeAll(",\"mp_template_msg\":{\"template_id\":");
            try js(w, self.template_id orelse "");
            if (self.appid) |a| {
                try w.writeAll(",\"appid\":");
                try js(w, a);
            }
            if (self.url) |u| {
                try w.writeAll(",\"url\":");
                try js(w, u);
            }
            if (self.mini_program) |mp| {
                try w.writeAll(",\"miniprogram\":{\"appid\":");
                try js(w, mp.appid);
                const key = if (mp.use_path)
                    "path"
                else if (mp.use_page_path) "pagePath" else "pagepath";
                try w.writeAll(",\"");
                try w.writeAll(key);
                try w.writeAll("\":");
                try js(w, mp.page_path orelse "");
                try w.writeByte('}');
            }
            // mp 分支:data==null 时省略(对齐 adapter);Zig 切片无法区分 null 与
            // 空列表,故空列表也按 null 处理(省略)。value 可带 color。
            if (self.data.len > 0) {
                try w.writeAll(",\"data\":{");
                for (self.data, 0..) |d, i| {
                    if (i > 0) try w.writeByte(',');
                    try js(w, d.name);
                    try w.writeAll(":{\"value\":");
                    try js(w, d.value);
                    if (d.color) |c| {
                        try w.writeAll(",\"color\":");
                        try js(w, c);
                    }
                    try w.writeByte('}');
                }
                try w.writeByte('}');
            }
            try w.writeAll("}}"); // 闭合 mp_template_msg 与根对象
            return out.toOwnedSlice();
        }

        // 小程序模板消息分支:data 恒出现(可为空对象),value 不带 color。
        try w.writeAll(",\"weapp_template_msg\":{\"template_id\":");
        try js(w, self.template_id orelse "");
        if (self.page) |p| {
            try w.writeAll(",\"page\":");
            try js(w, p);
        }
        if (self.form_id) |f| {
            try w.writeAll(",\"form_id\":");
            try js(w, f);
        }
        try w.writeAll(",\"data\":{");
        for (self.data, 0..) |d, i| {
            if (i > 0) try w.writeByte(',');
            try js(w, d.name);
            try w.writeAll(":{\"value\":");
            try js(w, d.value);
            try w.writeByte('}');
        }
        try w.writeByte('}');
        if (self.emphasis_keyword) |k| {
            try w.writeAll(",\"emphasis_keyword\":");
            try js(w, k);
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

// --- service ------------------------------------------------------------------

/// 统一消息服务 —— 组合在服务基座上(对应 `WxMaMsgServiceImpl` 持有 `WxMaService`
/// 引用的组合方式)。
pub const UniformMsgService = struct {
    svc: *mp_service.Service,

    /// 对应 `sendUniformMsg(WxMaUniformMessage)`:
    /// POST /cgi-bin/message/wxopen/template/uniform_send。
    /// errcode≠0 已由服务基座折叠为 `.err`(对应 Java 的 WxErrorException)。
    pub fn send(self: *UniformMsgService, io: std.Io, msg: UniformMessage) Done {
        const g = self.svc.gpa;
        const body = msg.to_json(g) catch |e| return .{ .err = fold(g, "uniform send build body", e) };
        defer g.free(body);
        return switch (self.svc.post(io, UNIFORM_MSG_SEND_URL, &.{}, body)) {
            .ok => |b| {
                g.free(b);
                return .{ .ok = {} };
            },
            .err => |e| return .{ .err = e },
        };
    }
};

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + body + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "uniform send weapp branch: post shape + body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "template/uniform_send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UniformMsgService{ .svc = &base };

    const msg = UniformMessage{
        .to_user = "oUser",
        .template_id = "TPL1",
        .page = "pages/index",
        .form_id = "F1",
        .data = &.{.{ .name = "keyword1", .value = "待发货", .color = "#FF0000" }},
        .emphasis_keyword = "keyword1",
    };
    const r = s.send(io, msg);
    try std.testing.expect(!r.failed());

    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/cgi-bin/message/wxopen/template/uniform_send") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oUser", json_util.getStr(parsed.value, "touser").?);
    const weapp = json_util.objectOf(parsed.value, "weapp_template_msg").?;
    try std.testing.expectEqualStrings("TPL1", json_util.getStr(.{ .object = weapp }, "template_id").?);
    try std.testing.expectEqualStrings("pages/index", json_util.getStr(.{ .object = weapp }, "page").?);
    try std.testing.expectEqualStrings("F1", json_util.getStr(.{ .object = weapp }, "form_id").?);
    try std.testing.expectEqualStrings("keyword1", json_util.getStr(.{ .object = weapp }, "emphasis_keyword").?);
    // 小程序分支的 data 项不输出 color(对齐 adapter)
    const data = json_util.objectOf(.{ .object = weapp }, "data").?;
    const kw1 = data.get("keyword1").?;
    try std.testing.expectEqualStrings("待发货", json_util.getStr(kw1, "value").?);
    try std.testing.expect(json_util.getStr(kw1, "color") == null);
}

test "uniform send mp branch: miniprogram + data color" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "template/uniform_send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UniformMsgService{ .svc = &base };

    const msg = UniformMessage{
        .is_mp_template_msg = true,
        .to_user = "oMp",
        .appid = "WXAPP",
        .template_id = "MPTPL",
        .url = "https://example.com",
        .mini_program = .{ .appid = "MPAPP", .page_path = "pages/p", .use_path = true },
        .data = &.{.{ .name = "first", .value = "您好", .color = "#173177" }},
    };
    const r = s.send(io, msg);
    try std.testing.expect(!r.failed());

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    const mp = json_util.objectOf(parsed.value, "mp_template_msg").?;
    try std.testing.expectEqualStrings("WXAPP", json_util.getStr(.{ .object = mp }, "appid").?);
    try std.testing.expectEqualStrings("MPTPL", json_util.getStr(.{ .object = mp }, "template_id").?);
    try std.testing.expectEqualStrings("https://example.com", json_util.getStr(.{ .object = mp }, "url").?);
    const mini = json_util.objectOf(.{ .object = mp }, "miniprogram").?;
    try std.testing.expectEqualStrings("MPAPP", json_util.getStr(.{ .object = mini }, "appid").?);
    // use_path=true → 输出 path(而非 pagepath)
    try std.testing.expectEqualStrings("pages/p", json_util.getStr(.{ .object = mini }, "path").?);
    const data = json_util.objectOf(.{ .object = mp }, "data").?;
    const first = data.get("first").?;
    try std.testing.expectEqualStrings("#173177", json_util.getStr(first, "color").?);
}

test "uniform send: errcode!=0 -> WxError" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "template/uniform_send", .response = "{\"errcode\":40037,\"errmsg\":\"invalid template_id\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = UniformMsgService{ .svc = &base };

    switch (s.send(io, .{ .to_user = "oU", .template_id = "BAD" })) {
        .ok => return error.ExpectedErr,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 40037), err.error_code);
        },
    }
}
