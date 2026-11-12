//! 客服会话服务 —— 对应微信公众平台「客服会话」接口 / Java `WxMpKefuService`
//! 的会话相关方法(与 `kefu.zig` 的客服消息、客服账号管理互补)。
//!
//! URL(路径由 `api_host_url` 拼前缀):
//! - 创建会话 POST cgi-bin/customservice/kfsession/create
//! - 关闭会话 POST cgi-bin/customservice/kfsession/close
//! - 获取会话 GET  cgi-bin/customservice/kfsession/getsession?openid=
//! - 获取客服会话列表 GET cgi-bin/customservice/kfsession/getsessionlist?kf_account=
//! - 获取未接入会话列表 GET cgi-bin/customservice/kfsession/getwaitcase
//!
//! 注:客服账号管理(kfaccount/add|update|delete|getkflist)已在 `kefu.zig`
//! 实现(`kfAccountAdd` / `kfAccountList` / `kfAccountDel` / `updateKfNickname`),
//! 本文件**不重复收录**(刻意省略,避免功能重复)。
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
    pub const create = "cgi-bin/customservice/kfsession/create";
    pub const close = "cgi-bin/customservice/kfsession/close";
    pub const getsession = "cgi-bin/customservice/kfsession/getsession";
    pub const getsessionlist = "cgi-bin/customservice/kfsession/getsessionlist";
    pub const getwaitcase = "cgi-bin/customservice/kfsession/getwaitcase";
};

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 一条会话记录 —— getsession / getsessionlist / getwaitcase 共用。
/// 字段按响应有无取舍(全为可选):getsession 带 kf_account+createtime;
/// getsessionlist / waitcaselist 带 openid(+ kf_account)+createtime。
pub const KfSession = struct {
    gpa: std.mem.Allocator,
    openid: ?[]const u8 = null,
    kf_account: ?[]const u8 = null,
    createtime: i64 = 0,

    pub fn deinit(self: *KfSession) void {
        const g = self.gpa;
        if (self.openid) |v| g.free(@constCast(v));
        if (self.kf_account) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn dupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        const s = json_util.getStr(v, key) orelse return null;
        return try gpa.dupe(u8, s);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfSession {
        return .{
            .gpa = gpa,
            .openid = try dupe(gpa, v, "openid"),
            .kf_account = try dupe(gpa, v, "kf_account"),
            .createtime = json_util.getIntOr(v, "createtime", 0),
        };
    }
};

/// 客服会话列表 —— 所有权:逐元素 deinit + `len != 0` 时 free 切片本身
/// (口径同 `material.zig#BatchGetResult` / `user_tag.zig#TagListUser`)。
pub const KfSessionList = struct {
    gpa: std.mem.Allocator,
    items: []KfSession = &.{},

    pub fn deinit(self: *KfSessionList) void {
        for (self.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

/// 未接入会话列表 —— {count, waitcaselist[]}。
pub const WaitCase = struct {
    gpa: std.mem.Allocator,
    count: i64 = 0,
    items: []KfSession = &.{},

    pub fn deinit(self: *WaitCase) void {
        for (self.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// 手写 JSON 转义 / 请求体
// ---------------------------------------------------------------------------

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// {"openid":..,"kf_account":..[,"text":..]} —— create / close 共用请求体。
fn sessionBody(gpa: std.mem.Allocator, openid: []const u8, kf_account: []const u8, text: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"openid\":");
    try jw.str(w, openid);
    try w.writeAll(",\"kf_account\":");
    try jw.str(w, kf_account);
    if (text) |t| {
        try w.writeAll(",\"text\":");
        try jw.str(w, t);
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// 通用列表解析:从 root[key] 数组取 KfSession(逐元素 deinit + 切片 free 的
/// 所有权由上层 deinit 负责;此处 errdefer 负责失败回退)。
fn parseSessionList(gpa: std.mem.Allocator, root: json_util.Value, key: []const u8) ![]KfSession {
    const arr = json_util.getArray(root, key) orelse return &[_]KfSession{};
    var list: std.ArrayList(KfSession) = .empty;
    errdefer {
        for (list.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    for (arr.items) |item| try list.append(gpa, try KfSession.fromJson(gpa, item));
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig / kefu.zig 同构)
// ---------------------------------------------------------------------------

fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiGet(svc: *service_mod.Service, io: std.Io, path: []const u8, qs: []const service_mod.Query) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.get(io, uri, qs);
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode(errcode!=0 已在 `Service.executeInternal` 折叠为 .err)。
fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

pub const KfSessionService = struct {
    svc: *service_mod.Service,

    /// 创建会话:POST kfsession/create {openid,kf_account[,text]},成功即完成。
    pub fn kfsessionCreate(self: *KfSessionService, io: std.Io, openid: []const u8, kf_account: []const u8, text: ?[]const u8) Done {
        const gpa = self.svc.gpa;
        const body = sessionBody(gpa, openid, kf_account, text) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build create body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.create, body);
    }

    /// 关闭会话:POST kfsession/close {openid,kf_account[,text]},成功即完成。
    pub fn kfsessionClose(self: *KfSessionService, io: std.Io, openid: []const u8, kf_account: []const u8, text: ?[]const u8) Done {
        const gpa = self.svc.gpa;
        const body = sessionBody(gpa, openid, kf_account, text) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build close body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.close, body);
    }

    /// 获取某用户的会话状态:GET getsession?openid= → {kf_account,createtime}。
    pub fn getSession(self: *KfSessionService, io: std.Io, openid: []const u8) WxResult(KfSession) {
        const gpa = self.svc.gpa;
        const qs = [_]service_mod.Query{.{ .key = "openid", .value = openid }};
        const resp = switch (apiGet(self.svc, io, Path.getsession, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "getsession not json", .{}) };
        defer parsed.deinit();
        const s = KfSession.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.transport(gpa, "getsession parse failed", .{}) };
        return .{ .ok = s };
    }

    /// 某客服的会话列表:GET getsessionlist?kf_account= → {sessionlist:[...]}。
    pub fn getSessionList(self: *KfSessionService, io: std.Io, kf_account: []const u8) WxResult(KfSessionList) {
        const gpa = self.svc.gpa;
        const qs = [_]service_mod.Query{.{ .key = "kf_account", .value = kf_account }};
        const resp = switch (apiGet(self.svc, io, Path.getsessionlist, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "getsessionlist not json", .{}) };
        defer parsed.deinit();
        const items = parseSessionList(gpa, parsed.value, "sessionlist") catch
            return .{ .err = result_mod.WxError.internal(gpa, "parse sessionlist failed", .{}) };
        return .{ .ok = .{ .gpa = gpa, .items = items } };
    }

    /// 未接入会话列表:GET getwaitcase → {count,waitcaselist:[...]}。
    pub fn getWaitCase(self: *KfSessionService, io: std.Io) WxResult(WaitCase) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, Path.getwaitcase, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "getwaitcase not json", .{}) };
        defer parsed.deinit();
        var wc = WaitCase{ .gpa = gpa };
        errdefer wc.deinit();
        wc.count = json_util.getIntOr(parsed.value, "count", 0);
        wc.items = parseSessionList(gpa, parsed.value, "waitcaselist") catch
            return .{ .err = result_mod.WxError.internal(gpa, "parse waitcaselist failed", .{}) };
        return .{ .ok = wc };
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 template_msg.zig / kefu.zig 的 Recorder)
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

test "kfsession create / close: 请求体 + URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfsession/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfsession/close", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KfSessionService{ .svc = &base };
    const io = threaded.io();

    switch (svc.kfsessionCreate(io, "oABC", "kf1@test", "您好")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/create") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    var b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"openid\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"kf_account\":\"kf1@test\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"text\":\"您好\"") != null);

    switch (svc.kfsessionClose(io, "oABC", "kf1@test", null)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/close") != null);
    b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"openid\":\"oABC\"") != null);
    // text=null -> Gson 省略该字段
    try testing.expect(std.mem.indexOf(u8, b, "\"text\"") == null);
}

test "kfsession getSession / getSessionList / getWaitCase: 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfsession/getsession?", .response = "{\"kf_account\":\"kf1@test\",\"createtime\":1700000000}" },
        .{ .match = "kfsession/getsessionlist", .response = "{\"sessionlist\":[{\"openid\":\"o1\",\"createtime\":1700000001},{\"openid\":\"o2\",\"createtime\":1700000002}]}" },
        .{ .match = "kfsession/getwaitcase", .response = "{\"count\":2,\"waitcaselist\":[{\"openid\":\"o3\",\"createtime\":1700000003}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KfSessionService{ .svc = &base };
    const io = threaded.io();

    // getSession
    switch (svc.getSession(io, "oABC")) {
        .ok => |*s| {
            var session = s.*;
            defer session.deinit();
            try testing.expectEqualStrings("kf1@test", session.kf_account.?);
            try testing.expectEqual(@as(i64, 1700000000), session.createtime);
            try testing.expect(session.openid == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "openid=oABC") != null);

    // getSessionList(逐元素 deinit + 切片 free 由 KfSessionList.deinit 负责)
    switch (svc.getSessionList(io, "kf1@test")) {
        .ok => |*r| {
            var list = r.*;
            defer list.deinit();
            try testing.expectEqual(@as(usize, 2), list.items.len);
            try testing.expectEqualStrings("o1", list.items[0].openid.?);
            try testing.expectEqual(@as(i64, 1700000002), list.items[1].createtime);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kf_account=kf1%40test") != null);

    // getWaitCase
    switch (svc.getWaitCase(io)) {
        .ok => |*r| {
            var wc = r.*;
            defer wc.deinit();
            try testing.expectEqual(@as(i64, 2), wc.count);
            try testing.expectEqual(@as(usize, 1), wc.items.len);
            try testing.expectEqualStrings("o3", wc.items[0].openid.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/getwaitcase") != null);
}

test "kfsession errcode!=0 折叠为 .err" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfsession/create", .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KfSessionService{ .svc = &base };
    switch (svc.kfsessionCreate(threaded.io(), "o", "kf", null)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 48001), err.error_code);
        },
    }
}
