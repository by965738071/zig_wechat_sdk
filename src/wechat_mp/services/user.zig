//! 用户服务 —— 对应 Java `api.WxMpUserService` + `api.impl.WxMpUserServiceImpl`。
//!
//! 骨架以本文件为**子服务样板**:Java 里 40+ 个子服务都是同一形状 ——
//! 结构体持有 parent service 引用(组合而非继承),方法 = 拼 uri →
//! service.get/post → 解析 JSON 成结果结构。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
const u_error = @import("common").error_util;
const u_token = @import("common").token;

const u_config = @import("../config.zig");
const u_http = @import("../http.zig");
const service_mod = @import("../service.zig");

/// 对应用户详情(骨架收录常用字段;全部 gpa 拥有)。
pub const User = struct {
    gpa: std.mem.Allocator,
    openid: []const u8,
    nickname: ?[]const u8 = null,
    language: ?[]const u8 = null,
    city: ?[]const u8 = null,
    province: ?[]const u8 = null,
    country: ?[]const u8 = null,
    headimgurl: ?[]const u8 = null,
    /// 0/1 是否订阅
    subscribe: u1 = 0,
    subscribe_time: i64 = 0,
    unionid: ?[]const u8 = null,

    pub fn deinit(self: *User) void {
        const g = self.gpa;
        g.free(@constCast(self.openid));
        for ([_]?[]const u8{
            self.nickname, self.language,   self.city,    self.province,
            self.country,  self.headimgurl, self.unionid,
        }) |s| if (s) |v| g.free(@constCast(v));
    }

    fn dupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        const s = json_util.getStr(v, key) orelse return null;
        return try gpa.dupe(u8, s);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !User {
        return .{
            .gpa = gpa,
            .openid = (try dupe(gpa, v, "openid")) orelse "",
            .nickname = try dupe(gpa, v, "nickname"),
            .language = try dupe(gpa, v, "language"),
            .city = try dupe(gpa, v, "city"),
            .province = try dupe(gpa, v, "province"),
            .country = try dupe(gpa, v, "country"),
            .headimgurl = try dupe(gpa, v, "headimgurl"),
            .subscribe = if ((json_util.getInt(v, "subscribe") orelse 0) != 0) @as(u1, 1) else @as(u1, 0),
            .subscribe_time = json_util.getInt(v, "subscribe_time") orelse 0,
            .unionid = try dupe(gpa, v, "unionid"),
        };
    }
};

// ---------------------------------------------------------------------------
// 关注者列表 / 批量用户信息 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// 关注者列表 —— GET cgi-bin/user/get 响应
/// {total,count,data:{openid:[...]},next_openid}。openid 切片与 next_openid
/// 全部 gpa 拥有;deinit 逐元素 free + free 切片本身
/// (口径同 `user_tag.zig#TagListUser`)。
pub const Followers = struct {
    gpa: std.mem.Allocator,
    total: i64 = 0,
    count: i64 = 0,
    openids: [][]u8 = &.{},
    next_openid: []const u8 = "",

    pub fn deinit(self: *Followers) void {
        const g = self.gpa;
        for (self.openids) |o| g.free(o);
        if (self.openids.len > 0) g.free(self.openids);
        g.free(@constCast(self.next_openid));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !Followers {
        var r = Followers{ .gpa = gpa };
        errdefer r.deinit();
        r.total = json_util.getIntOr(v, "total", 0);
        r.count = json_util.getIntOr(v, "count", 0);
        r.next_openid = try gpa.dupe(u8, json_util.getStrOr(v, "next_openid", ""));

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |o| gpa.free(o);
            list.deinit(gpa);
        }
        if (json_util.objectOf(v, "data")) |d| {
            if (d.get("openid")) |oi| {
                if (oi == .array) for (oi.array.items) |s| {
                    if (s == .string) try list.append(gpa, try gpa.dupe(u8, s.string));
                };
            }
        }
        r.openids = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// batchget 的单个 user_list 项(官方文档:{openid, lang?})。
pub const UserListEntry = struct {
    openid: []const u8,
    lang: ?[]const u8 = null,
};

/// 批量用户信息结果 —— 复用既有 `User` 类型;切片逐元素 `User.deinit()` +
/// free 切片本身(口径同 `user_tag.zig:382-389` / `material.zig#BatchGetResult`)。
pub const UserInfoBatchResult = struct {
    gpa: std.mem.Allocator,
    users: []User = &.{},

    pub fn deinit(self: *UserInfoBatchResult) void {
        for (self.users) |*u| {
            var tmp = u.*;
            tmp.deinit();
        }
        if (self.users.len != 0) self.gpa.free(self.users);
        self.* = undefined;
    }
};

/// {"user_list":[{openid,lang?},...]}。
fn batchGetBody(gpa: std.mem.Allocator, user_list: []const UserListEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"user_list\":[");
    for (user_list, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"openid\":");
        try jw.str(w, e.openid);
        if (e.lang) |l| {
            try w.writeAll(",\"lang\":");
            try jw.str(w, l);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

pub const UserService = struct {
    svc: *service_mod.Service,

    /// 对应 `WxMpUserService.userInfo(openid)`。
    pub fn userInfo(self: *UserService, io: std.Io, openid: []const u8, lang: ?[]const u8) WxResult(User) {
        const gpa = self.svc.gpa;
        var qs_buf: [2]service_mod.Query = .{ .{ .key = "openid", .value = openid }, .{ .key = "lang", .value = "" } };
        const qs = if (lang) |l| blk: {
            qs_buf[1] = .{ .key = "lang", .value = l };
            break :blk &qs_buf;
        } else qs_buf[0..1];

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, service_mod.ApiUrl.user_info.asUri() }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const resp = switch (self.svc.get(io, uri, qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "user info not json", .{}),
        };
        defer parsed.deinit();

        const user = User.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.transport(gpa, "user info parse failed", .{}),
        };
        return .{ .ok = user };
    }

    /// 对应 `WxMpUserService.userGet(nextOpenid)` / 关注者列表:
    /// GET cgi-bin/user/get?next_openid= → {total,count,data.openid[],next_openid}。
    /// next_openid 传 "" 取第一页。所有权:结果 gpa 拥有,用毕 deinit。
    pub fn userGet(self: *UserService, io: std.Io, next_openid: []const u8) WxResult(Followers) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, service_mod.ApiUrl.user_get.asUri() }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const qs = [_]service_mod.Query{.{ .key = "next_openid", .value = next_openid }};
        const resp = switch (self.svc.get(io, uri, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "user/get not json", .{}),
        };
        defer parsed.deinit();
        const r = Followers.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.transport(gpa, "user/get parse failed", .{}),
        };
        return .{ .ok = r };
    }

    /// `userGet` 的别名(Java 里 followers 亦指关注者列表)。
    pub fn followers(self: *UserService, io: std.Io, next_openid: []const u8) WxResult(Followers) {
        return self.userGet(io, next_openid);
    }

    /// 对应 `WxMpUserService.userInfoBatchGet`:
    /// POST cgi-bin/user/info/batchget {user_list:[...]} → {user_info_list:[...]}。
    /// 复用既有 `User` 类型;所有权:结果 gpa 拥有,用毕 deinit
    /// (逐元素 User.deinit + free 切片)。
    pub fn batchGet(self: *UserService, io: std.Io, user_list: []const UserListEntry) WxResult(UserInfoBatchResult) {
        const gpa = self.svc.gpa;
        const body = batchGetBody(gpa, user_list) catch |e| return .{
            .err = result_mod.WxError.internal(gpa, "build batchget body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, service_mod.ApiUrl.user_info_batch.asUri() }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "user/info/batchget not json", .{}),
        };
        defer parsed.deinit();

        var res = UserInfoBatchResult{ .gpa = gpa };
        errdefer res.deinit();
        var list: std.ArrayList(User) = .empty;
        errdefer {
            for (list.items) |*u| {
                var tmp = u.*;
                tmp.deinit();
            }
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "user_info_list")) |arr| {
            for (arr.items) |item| {
                const u = User.fromJson(gpa, item) catch return .{
                    .err = result_mod.WxError.transport(gpa, "batchget user parse failed", .{}),
                };
                list.append(gpa, u) catch return .{
                    .err = result_mod.WxError.internal(gpa, "oom", .{}),
                };
            }
        }
        res.users = list.toOwnedSlice(gpa) catch return .{
            .err = result_mod.WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = res };
    }

    /// `batchGet` 的别名。
    pub fn userInfoBatchGet(self: *UserService, io: std.Io, user_list: []const UserListEntry) WxResult(UserInfoBatchResult) {
        return self.batchGet(io, user_list);
    }
};

test "user service via stub" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stub_mod = @import("../http.zig");
    const token_mod = @import("common").token;
    const error_mod = @import("common").error_util;
    const config_mod = @import("../config.zig");

    var stub = stub_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/user/info", .response = "{\"openid\":\"oABC\",\"nickname\":\"nick\",\"subscribe\":1,\"subscribe_time\":1700000000}" },
    });

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var users = UserService{ .svc = &svc };

    const r = users.userInfo(io, "oABC", null);
    switch (r) {
        .ok => |*u| {
            var user = u.*;
            defer user.deinit();
            try std.testing.expectEqualStrings("oABC", user.openid);
            try std.testing.expectEqualStrings("nick", user.nickname.?);
            try std.testing.expectEqual(@as(u1, 1), user.subscribe);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("user err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
}

// ---------------------------------------------------------------------------
// 关注者列表 / 批量用户信息 测试(mock 记录 method/uri/body,离线)
// ---------------------------------------------------------------------------

const URecorder = struct {
    const Entry = struct { match: []const u8, response: []const u8 };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    fn uri(self: *const URecorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const URecorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
    fn executor(self: *URecorder) u_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: u_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *URecorder = @ptrCast(@alignCast(ctx));
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
                    .err = u_error.WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = u_error.WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }
    const vtable = u_http.RequestExecutor.VTable{ .execute = executeImpl };
};

const UFakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) u_token.FetchOutcome {
        _ = c;
        _ = i;
        const tok = g.dupe(u8, "TOK") catch return .{ .err = u_error.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = tok, .expires_in = 7200 } };
    }
};

fn uSetup(
    gpa: std.mem.Allocator,
    mock: *URecorder,
    threaded: *std.Io.Threaded,
    cfg: *u_config.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try u_config.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = UFakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), mock.executor());
}

test "user userGet / followers: 关注者列表解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/get", .response = "{\"total\":3,\"count\":2,\"data\":{\"openid\":[\"o1\",\"o2\"]},\"next_openid\":\"o2\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try uSetup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };
    const io = threaded.io();

    // userGet
    switch (svc.userGet(io, "NEXT1")) {
        .ok => |*r| {
            var f = r.*;
            defer f.deinit();
            try testing.expectEqual(@as(i64, 3), f.total);
            try testing.expectEqual(@as(i64, 2), f.count);
            try testing.expectEqual(@as(usize, 2), f.openids.len);
            try testing.expectEqualStrings("o1", f.openids[0]);
            try testing.expectEqualStrings("o2", f.openids[1]);
            try testing.expectEqualStrings("o2", f.next_openid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "next_openid=NEXT1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

    // followers 别名(空 next_openid 取第一页)
    switch (svc.followers(io, "")) {
        .ok => |*r| {
            var f = r.*;
            defer f.deinit();
            try testing.expectEqual(@as(usize, 2), f.openids.len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "user batchGet / userInfoBatchGet: user_list 请求体 + 复用 User 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/info/batchget", .response = "{\"user_info_list\":[{\"openid\":\"o1\",\"nickname\":\"甲\",\"subscribe\":1,\"subscribe_time\":1700000000},{\"openid\":\"o2\",\"nickname\":\"乙\",\"subscribe\":0}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try uSetup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };
    const io = threaded.io();

    switch (svc.batchGet(io, &.{
        .{ .openid = "o1", .lang = "zh_CN" },
        .{ .openid = "o2" },
    })) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit(); // 逐元素 User.deinit + free 切片(testing.allocator 校验无泄漏)
            try testing.expectEqual(@as(usize, 2), res.users.len);
            try testing.expectEqualStrings("o1", res.users[0].openid);
            try testing.expectEqualStrings("甲", res.users[0].nickname.?);
            try testing.expectEqual(@as(u1, 1), res.users[0].subscribe);
            try testing.expectEqualStrings("o2", res.users[1].openid);
            try testing.expectEqual(@as(u1, 0), res.users[1].subscribe);
            try testing.expect(res.users[1].subscribe_time == 0);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/info/batchget") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"user_list\":[") != null);
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o1\",\"lang\":\"zh_CN\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o2\"}") != null);

    // userInfoBatchGet 别名
    switch (svc.userInfoBatchGet(io, &.{.{ .openid = "o1" }})) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 2), res.users.len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "user userGet errcode!=0 折叠为 .err" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/get", .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try uSetup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };
    switch (svc.followers(threaded.io(), "")) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40003), err.error_code);
        },
    }
}
