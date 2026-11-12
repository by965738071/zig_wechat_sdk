//! 订阅通知服务 —— 公众号「一次性 / 长期订阅通知」下发接口。
//!
//! URL 来源:微信公众平台开发文档「订阅通知 - 发送订阅通知」:
//! `POST https://api.weixin.qq.com/cgi-bin/message/subscribe/bizsend`
//! (access_token 由 `Service` 层附加,此处不得硬编码)。
//!
//! 结构刻意对齐 `template_msg.zig`(同为「消息下发」子服务):结构体持 parent
//! `Service` 引用,方法 = 拼 uri → service.post → 解析/折叠 errcode。
//! 与小程序订阅消息(`wechat_miniapp/subscribe_msg.zig`,端点 subscribe/send)
//! 是**不同业务线的不同端点**,本文件不复用、不重复。
//!
//! 请求体字段(官方文档):touser / template_id / page 或 url / miniprogram
//! (可选)/ data{key:{value}} / scene / title(视模板而定)。
const std = @import("std");
const testing = std.testing;

const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const token_mod = @import("common").token;

const config_mod = @import("../config.zig");
const http_mod = @import("../http.zig");
const service_mod = @import("../service.zig");

pub const Path = struct {
    /// 公众号订阅通知下发(与小程序 subscribe/send 区分)。
    pub const bizsend = "cgi-bin/message/subscribe/bizsend";
};

// ---------------------------------------------------------------------------
// 请求体 bean(与 template_msg.zig 的 TemplateData / MiniProgram / TemplateMessage 同构)
// ---------------------------------------------------------------------------

/// 模板变量项 —— 对应 data 里的 `key:{value}`。
pub const Data = struct {
    name: []const u8,
    value: []const u8,
};

/// 跳小程序(可选)—— 对应官方 `miniprogram:{appid,pagepath}`。
pub const MiniProgram = struct {
    appid: []const u8,
    pagepath: []const u8 = "",
};

/// 待发送的订阅通知 —— 对应一条 bizsend 请求。
pub const SubscribeMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    /// 点击跳转的网页(与 page 二选一,按模板要求)
    url: ?[]const u8 = null,
    /// 点击跳转小程序的页面(与 url 二选一)
    page: ?[]const u8 = null,
    miniprogram: ?MiniProgram = null,
    /// 订阅场景值(部分模板要求)
    scene: ?[]const u8 = null,
    /// 消息标题(部分模板要求)
    title: ?[]const u8 = null,
    data: []const Data = &.{},

    /// 序列化为 bizsend 请求体:
    /// `{touser,template_id[,url][,page][,miniprogram][,scene][,title],
    ///   data:{key:{value}}}`,data 恒出现(可为空对象)。
    pub fn toJson(gpa: std.mem.Allocator, m: SubscribeMessage) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"touser\":");
        try jw.str(w, m.to_user);
        try w.writeAll(",\"template_id\":");
        try jw.str(w, m.template_id);
        if (m.url) |u| {
            try w.writeAll(",\"url\":");
            try jw.str(w, u);
        }
        if (m.page) |p| {
            try w.writeAll(",\"page\":");
            try jw.str(w, p);
        }
        if (m.miniprogram) |mp| {
            try w.writeAll(",\"miniprogram\":{\"appid\":");
            try jw.str(w, mp.appid);
            try w.writeAll(",\"pagepath\":");
            try jw.str(w, mp.pagepath);
            try w.writeByte('}');
        }
        if (m.scene) |s| {
            try w.writeAll(",\"scene\":");
            try jw.str(w, s);
        }
        if (m.title) |t| {
            try w.writeAll(",\"title\":");
            try jw.str(w, t);
        }
        // data:{name:{value}},与 template_msg.zig 的适配器遍历循环同构。
        try w.writeAll(",\"data\":{");
        for (m.data, 0..) |d, i| {
            if (i != 0) try w.writeByte(',');
            try jw.str(w, d.name);
            try w.writeAll(":{\"value\":");
            try jw.str(w, d.value);
            try w.writeByte('}');
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig 同构)
// ---------------------------------------------------------------------------

fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode(成功即完成;errcode!=0 已在 `Service.executeInternal`
/// 折叠为 .err)。
fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

pub const SubscribeMsgService = struct {
    svc: *service_mod.Service,

    /// 发送订阅通知:POST cgi-bin/message/subscribe/bizsend。
    /// 成功返回 Done(响应仅 errcode/errmsg);errcode!=0 折叠为 .err。
    pub fn send(self: *SubscribeMsgService, io: std.Io, msg: SubscribeMessage) Done {
        const gpa = self.svc.gpa;
        const body = SubscribeMessage.toJson(gpa, msg) catch |e| return .{
            .err = result_mod.WxError.internal(gpa, "build bizsend body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.bizsend, body);
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 template_msg.zig 的 Recorder)
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

test "subscribe bizsend: 全字段请求体 + URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/subscribe/bizsend", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
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
        .miniprogram = .{ .appid = "wxmp1", .pagepath = "pages/detail" },
        .scene = "1001",
        .title = "订单通知",
        .data = &.{
            .{ .name = "thing1", .value = "你好" },
            .{ .name = "amount2", .value = "10.00" },
        },
    })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/subscribe/bizsend") != null);
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
}

test "subscribe bizsend: 最小请求(data 为空对象,省略可选字段)" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/subscribe/bizsend", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };

    switch (svc.send(threaded.io(), .{ .to_user = "oX", .template_id = "T" })) {
        .ok => {},
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

test "subscribe bizsend: errcode!=0 折叠为 .err" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/subscribe/bizsend", .response = "{\"errcode\":43101,\"errmsg\":\"user refuse to accept the msg\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = SubscribeMsgService{ .svc = &base };
    switch (svc.send(threaded.io(), .{ .to_user = "oU", .template_id = "T" })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 43101), err.error_code);
        },
    }
}
