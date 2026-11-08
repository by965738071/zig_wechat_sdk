//! 测试专用 mock —— 记录最近一次请求的 method/uri/body 并按子串路由响应。
//! 对应 Java 测试里 Mockito mock `RequestHttp` 的模式;仅供本模块测试文件
//! (subscribe_msg/qrcode/link/uniform_message)复用,不从 root.zig 导出。
const std = @import("std");
const mp_http = @import("wechat_mp").http;
const mp_config = @import("wechat_mp").config;
const error_mod = @import("common").error_util;
const token_mod = @import("common").token;

pub const MockExecutor = struct {
    gpa: std.mem.Allocator,
    /// 简单路由表:uri 里包含 match 即返回 response(按声明顺序取第一个命中)。
    /// response 允许是二进制(如 PNG 假字节),因此存 []const u8。
    entries: []const Entry,
    /// 最近一次请求快照(均 gpa 拥有;重复请求时自动释放旧值)
    last_method: ?mp_http.RequestExecutor.Method = null,
    last_uri: []const u8 = "",
    last_body: []const u8 = "",
    last_body_is_null: bool = false,
    calls: usize = 0,

    pub const Entry = struct { match: []const u8, response: []const u8 };

    pub fn init(gpa: std.mem.Allocator, entries: []const Entry) MockExecutor {
        return .{ .gpa = gpa, .entries = entries };
    }

    pub fn deinit(self: *MockExecutor) void {
        self.gpa.free(@constCast(self.last_uri));
        self.gpa.free(@constCast(self.last_body));
    }

    pub fn executor(self: *MockExecutor) mp_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) mp_http.WxResult([]u8) {
        _ = io;
        const self: *MockExecutor = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = method;
        self.gpa.free(@constCast(self.last_uri));
        self.last_uri = gpa.dupe(u8, uri) catch "";
        self.gpa.free(@constCast(self.last_body));
        if (body) |b| {
            self.last_body = gpa.dupe(u8, b) catch "";
            self.last_body_is_null = false;
        } else {
            self.last_body = "";
            self.last_body_is_null = true;
        }
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, uri, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) } };
            }
        }
        return .{ .err = error_mod.WxError.transport(gpa, "mock miss: {s}", .{uri}) };
    }

    const vtable = mp_http.RequestExecutor.VTable{ .execute = executeImpl };
};

/// 返回固定 token("TOK")的配置存储,免去每个测试重复手写 Fetcher vtable。
pub fn fakeTokenConfig(gpa: std.mem.Allocator) !mp_config.InMemoryConfigStorage {
    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    return mp_config.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "MA", .secret = "MS" });
}
