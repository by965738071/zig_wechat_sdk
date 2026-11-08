//! 公众号服务门面 —— 对应 Java `api.impl.WxMpServiceImpl`
//! (extends BaseWxMpServiceImpl,构造时 eager 创建全部子服务)。
//!
//! Zig 侧用「原地初始化」表达同一组合:子服务持有 `&self.base` 反向引用,
//! 因此 MpService 初始化后**不得再移动**(需要堆上持有就 `create` 后再 init)。
const std = @import("std");
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const service = @import("service.zig");
pub const router = @import("router.zig");
pub const user = @import("services/user.zig");

pub const MpService = struct {
    base: service.Service,
    /// 子服务(骨架示例 UserService;其余同构追加即可)
    user_service: user.UserService,

    /// 对应 `new WxMpServiceImpl()`:注入配置与执行器,原地组合子服务。
    /// 子服务持 `&self.base` 反向引用,初始化后不得移动本结构。
    /// 用法:
    /// ```zig
    /// var mp: MpService = undefined;
    /// mp.init(gpa, cfg.config(), exec.executor());
    /// mp.user_service.userInfo(io, "openid", null);
    /// ```
    pub fn init(self: *MpService, gpa: std.mem.Allocator, cfg: config.ConfigStorage, exec: http.RequestExecutor) void {
        self.* = .{
            .base = service.Service.init(gpa, cfg, exec),
            .user_service = undefined,
        };
        self.user_service = .{ .svc = &self.base };
    }
};

// ---------------------------------------------------------------------------

// 端到端骨架链路:StubExecutor 同时喂 token 与业务接口。
test "mp service full chain (stubbed)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "{\"access_token\":\"AT1\",\"expires_in\":7200}" },
        .{ .match = "cgi-bin/user/info", .response = "{\"openid\":\"oX\",\"subscribe\":1}" },
    });

    var cfg = try config.InMemoryConfigStorage.init(gpa, undefined_fetcher, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tfetch = http.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = stub.executor(),
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = tfetch.fetcher();

    var mp: MpService = undefined;
    mp.init(gpa, cfg.config(), stub.executor());

    const r = mp.user_service.userInfo(io, "oX", null);
    switch (r) {
        .ok => |*u| {
            var usr = u.*;
            defer usr.deinit();
            try std.testing.expectEqualStrings("oX", usr.openid);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("mp err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
}

// access_token 错误码 → 自动刷新 → 重试一次(核心协议验证)。
test "token error triggers auto refresh retry" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 可编程 stub:第 1 次 token 返回 AT1;业务第 1 次回 40001,之后成功;
    // token 第 2 次返回 AT2。
    const Scripted = struct {
        token_calls: usize = 0,
        api_calls: usize = 0,

        fn execute(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) service.WxResult([]u8) {
            _ = i;
            _ = method;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, uri, "cgi-bin/token") != null) {
                self.token_calls += 1;
                // 槽里已预置过期 AT1,所以任何一次真实 fetch 都是新 token AT2
                const resp = "{\"access_token\":\"AT2\",\"expires_in\":7200}";
                return .{ .ok = g.dupe(u8, resp) catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
            }
            self.api_calls += 1;
            if (std.mem.indexOf(u8, uri, "AT1") != null) {
                // 旧 token 已失效
                return .{ .ok = g.dupe(u8, "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}") catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
            }
            return .{ .ok = g.dupe(u8, "{\"openid\":\"oZ\"}") catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
        }
    };
    var script = Scripted{};
    const exec = http.RequestExecutor{ .ptr = @ptrCast(&script), .vtable = &.{ .execute = Scripted.execute } };

    var cfg = try config.InMemoryConfigStorage.init(gpa, undefined_fetcher, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tfetch = http.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = exec,
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = tfetch.fetcher();

    var svc = service.Service.init(gpa, cfg.config(), exec);
    // 预先塞入 AT1(模拟缓存里躺着过期 token)
    try cfg.slot.update(io, "AT1", 7200);

    var uri_buf = std.ArrayList(u8).empty;
    defer uri_buf.deinit(gpa);
    try uri_buf.appendSlice(gpa, "https://api.weixin.qq.com/cgi-bin/user/info?openid=oZ");

    const r = svc.get(io, uri_buf.items, &.{});
    switch (r) {
        .ok => |b| {
            defer gpa.free(b);
            try std.testing.expect(std.mem.indexOf(u8, b, "oZ") != null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("retry err: [{d}] {s}\n", .{ err.error_code, err.error_msg });
            return error.Unexpected;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), script.token_calls); // 旧 token 预置在槽里,失效后自动刷新了一次
    try std.testing.expectEqual(@as(usize, 2), script.api_calls); // 业务重试了一次
}

/// 未注入真实 fetcher 前的占位(任何调用都会报错)。
const undefined_fetcher = @import("common").token.Fetcher{
    .ptr = undefined,
    .vtable = &.{ .fetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) @import("common").token.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = @import("common").error_util.WxError.transport(g, "fetcher not wired", .{}) };
        }
    }.f },
};
