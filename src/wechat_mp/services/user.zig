//! 用户服务 —— 对应 Java `api.WxMpUserService` + `api.impl.WxMpUserServiceImpl`。
//!
//! 骨架以本文件为**子服务样板**:Java 里 40+ 个子服务都是同一形状 ——
//! 结构体持有 parent service 引用(组合而非继承),方法 = 拼 uri →
//! service.get/post → 解析 JSON 成结果结构。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;

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
