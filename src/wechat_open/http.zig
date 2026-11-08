//! 第三方平台 HTTP 层 —— 对应 Java `impl.WxOpenComponentServiceImpl` 里
//! component/authorizer token 的两条获取通道:
//! - POST /cgi-bin/component/api_component_token(需 verify_ticket);
//! - POST /cgi-bin/component/api_authorizer_token(refresh_token 每次轮换)。
const std = @import("std");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;
const result_mod = @import("common").result;
const json_util = @import("common").json_util;
const mp_http = @import("wechat_mp").http;
const open_config = @import("config.zig");

pub const WxError = error_mod.WxError;
pub const WxResult = result_mod.WxResult;

const api_component_token = "https://api.weixin.qq.com/cgi-bin/component/api_component_token";
const api_authorizer_token = "https://api.weixin.qq.com/cgi-bin/component/api_authorizer_token";

// ---------------------------------------------------------------------------
// component_access_token 刷新源
// ---------------------------------------------------------------------------

pub const ComponentTokenSource = struct {
    cfg: open_config.OpenConfigStorage,
    exec: mp_http.RequestExecutor,

    pub fn fetcher(self: *ComponentTokenSource) token_mod.Fetcher {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) token_mod.FetchOutcome {
        const self: *ComponentTokenSource = @ptrCast(@alignCast(ctx));
        var tickbuf: [512]u8 = undefined;
        const ticket = self.cfg.componentVerifyTicket(&tickbuf) orelse
            return .{ .err = WxError.configError(gpa, "component_verify_ticket 未就绪(等待微信 10 分钟推送)", .{}) };

        const body = std.fmt.allocPrint(gpa,
            \\{{"component_appid":"{s}","component_app_secret":"{s}","component_verify_ticket":"{s}"}}
        , .{ self.cfg.componentAppid(), self.cfg.componentSecret(), ticket }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body);

        return switch (self.exec.execute(gpa, io, .post, api_component_token, body)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp);
                var parsed = json_util.parse(gpa, resp) catch
                    break :blk .{ .err = WxError.transport(gpa, "component token not json", .{}) };
                defer parsed.deinit();
                const tok = json_util.getStr(parsed.value, "component_access_token") orelse
                    break :blk .{ .err = WxError.fromJson(gpa, resp, .open) catch WxError.transport(gpa, "bad component token resp", .{}) };
                const t = gpa.dupe(u8, tok) catch break :blk .{ .err = WxError.transport(gpa, "oom", .{}) };
                break :blk .{ .ok = .{ .token = t, .expires_in = json_util.getInt(parsed.value, "expires_in") orelse 7200 } };
            },
        };
    }
};

// ---------------------------------------------------------------------------
// authorizer_access_token 刷新源(实现 AuthorizerTokenSource)
// ---------------------------------------------------------------------------

pub const HttpAuthorizerTokenSource = struct {
    cfg: open_config.OpenConfigStorage,
    exec: mp_http.RequestExecutor,

    pub fn source(self: *HttpAuthorizerTokenSource) open_config.AuthorizerTokenSource {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, authorizer_appid: []const u8, refresh_token: []const u8) open_config.AuthorizerOutcome {
        const self: *HttpAuthorizerTokenSource = @ptrCast(@alignCast(ctx));
        var tbuf: [256]u8 = undefined;
        const comp_tok = switch (self.cfg.acquireComponentAccessToken(io, &tbuf, false)) {
            .err => |e| return .{ .err = e },
            .ok => |t| t,
        };

        const body = std.fmt.allocPrint(gpa,
            \\{{"component_appid":"{s}","component_access_token":"{s}","authorizer_appid":"{s}","authorizer_refresh_token":"{s}"}}
        , .{ self.cfg.componentAppid(), comp_tok, authorizer_appid, refresh_token }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body);

        return switch (self.exec.execute(gpa, io, .post, api_authorizer_token, body)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp);
                var parsed = json_util.parse(gpa, resp) catch
                    break :blk .{ .err = WxError.transport(gpa, "authorizer token not json", .{}) };
                defer parsed.deinit();
                const tok = json_util.getStr(parsed.value, "authorizer_access_token") orelse
                    break :blk .{ .err = WxError.fromJson(gpa, resp, .open) catch WxError.transport(gpa, "bad authorizer token resp", .{}) };
                // refresh_token 轮换:响应里带新的,存储层负责写回
                const new_refresh = json_util.getStr(parsed.value, "authorizer_refresh_token") orelse refresh_token;
                const t = gpa.dupe(u8, tok) catch break :blk .{ .err = WxError.transport(gpa, "oom", .{}) };
                errdefer gpa.free(t);
                const nr = gpa.dupe(u8, new_refresh) catch break :blk .{ .err = WxError.transport(gpa, "oom", .{}) };
                break :blk .{ .ok = .{
                    .token = t,
                    .expires_in = json_util.getInt(parsed.value, "authorizer_expires_in") orelse json_util.getInt(parsed.value, "expires_in") orelse 7200,
                    .new_refresh_token = nr,
                } };
            },
        };
    }
};

// ---------------------------------------------------------------------------
// 平台门面(对应 `WxOpenComponentServiceImpl` 的骨架面)
// ---------------------------------------------------------------------------

pub const ComponentService = struct {
    gpa: std.mem.Allocator,
    cfg: open_config.OpenConfigStorage,
    exec: mp_http.RequestExecutor,

    pub fn init(gpa: std.mem.Allocator, cfg: open_config.OpenConfigStorage, exec: mp_http.RequestExecutor) ComponentService {
        return .{ .gpa = gpa, .cfg = cfg, .exec = exec };
    }

    /// 对应 `getComponentAccessToken(forceRefresh)`。
    pub fn getComponentAccessToken(self: *ComponentService, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        return self.cfg.acquireComponentAccessToken(io, buf, force);
    }

    /// 对应 `getWxMpServiceByAppid(authorizerAppid)`:
    /// 返回可直接喂给 mp Service 的 InnerView(授权方伪装成公众号)。
    pub fn authorizerMpConfig(self: *ComponentService, view: *open_config.InnerView, authorizer_appid: []const u8) mp_config_like_Config {
        view.* = .{ .open = self.cfg, .appid = authorizer_appid, .gpa = self.gpa };
        return view.mpConfig();
    }

    /// 收到 component_verify_ticket 事件回调时调用(对应 `setComponentVerifyTicket`)。
    pub fn onVerifyTicket(self: *ComponentService, ticket: []const u8) bool {
        return self.cfg.setComponentVerifyTicket(ticket);
    }
};

// 别名澄清:mp 的 ConfigStorage 类型(open 视角只借它的 vtable)。
const mp_config_like_Config = @import("wechat_mp").config.ConfigStorage;

// ---------------------------------------------------------------------------

test "open config: verify ticket + authorizer refresh rotation" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 假 component token 通道
    const CompFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "COMP-TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };

    // 假授权方刷新源:refresh_token 每轮换 R1→R2→R3…
    const FakeSrc = struct {
        count: usize = 0,
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io, appid: []const u8, refresh: []const u8) open_config.AuthorizerOutcome {
            _ = i;
            _ = appid;
            _ = refresh;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.count += 1;
            const tok = std.fmt.allocPrint(g, "AUTH-{d}", .{self.count}) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            const nr = std.fmt.allocPrint(g, "R{d}", .{self.count + 1}) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = tok, .expires_in = 7200, .new_refresh_token = nr } };
        }
    };
    var src = FakeSrc{};
    const source = open_config.AuthorizerTokenSource{ .ptr = @ptrCast(&src), .vtable = &.{ .fetch = FakeSrc.f } };

    var comp = ComponentTokenSource{ .cfg = undefined, .exec = undefined };
    _ = &comp;

    var storage = try open_config.InMemoryOpenConfigStorage.init(gpa, "wxCOMP", "COMP_SECRET", .{
        .ptr = undefined,
        .vtable = &.{ .fetch = CompFetch.f },
    }, source);
    defer storage.deinit();

    // 无 ticket 也能取 component token(此桩不依赖),真实实现会先检查 ticket
    var buf: [256]u8 = undefined;
    const cfg = storage.config();
    switch (cfg.acquireComponentAccessToken(io, &buf, false)) {
        .ok => |t| try std.testing.expectEqualStrings("COMP-TOK", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // 注册授权方 + 拉取授权方 token(refresh_token 应为 R1→R2)
    _ = try storage.ensureAuthorizer(io, "wxAUTH", "R1");
    switch (cfg.acquireAuthorizerAccessToken(io, "wxAUTH", &buf, false)) {
        .ok => |t| try std.testing.expectEqualStrings("AUTH-1", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expectEqualStrings("R2", cfg.authorizerRefreshToken("wxAUTH").?);

    // 失效后强制刷新 → AUTH-2,R3(refresh_token 轮换语义)
    try std.testing.expect(cfg.expireAuthorizerAccessToken(io, "wxAUTH", "AUTH-1"));
    switch (cfg.acquireAuthorizerAccessToken(io, "wxAUTH", &buf, false)) {
        .ok => |t| try std.testing.expectEqualStrings("AUTH-2", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expectEqualStrings("R3", cfg.authorizerRefreshToken("wxAUTH").?);

    // InnerView:伪装成 mp ConfigStorage
    var view = open_config.InnerView{ .open = cfg, .appid = "wxAUTH", .gpa = gpa };
    const mp_cfg = view.mpConfig();
    try std.testing.expectEqualStrings("wxAUTH", mp_cfg.appid());
    switch (mp_cfg.acquireAccessToken(io, &buf, false)) {
        .ok => |t| try std.testing.expect(std.mem.eql(u8, "AUTH-2", t)),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}
