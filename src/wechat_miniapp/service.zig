//! 小程序服务 —— 对应 Java `api.WxMaService` + `impl.WxMaServiceImpl` /
//! `impl.BaseWxMaServiceImpl`。
//!
//! 执行协议与 mp 完全同构(-1 退避 + token 失效重试一次)。骨架阶段
//! 直接**组合** mp 的 Service(注释里说明:Java 因跨模块不能互用而各写一份,
//! 同一 Zig 工程内复用同一实现反而更忠实于「同一协议」的事实)。
//! 本文件补小程序特有面:jsCode2Session、stable token 提示、cloud 环境 TODO。
const std = @import("std");
const mp_service = @import("wechat_mp").service;
const mp_http = @import("wechat_mp").http;
const mp_config = @import("wechat_mp").config;
const result_mod = @import("common").result;
const json_util = @import("common").json_util;
const subscribe_msg = @import("subscribe_msg.zig");
const qrcode = @import("qrcode.zig");
const link = @import("link.zig");
const uniform_msg = @import("uniform_msg.zig");
pub const api_signature = @import("api_signature.zig");
const intracity_mod = @import("intracity.zig");

pub const WxResult = result_mod.WxResult;
pub const Service = mp_service.Service; // 同构复用(wx_type 可覆写为 .mini_app)

/// 对应 `WxMaJscode2SessionResult`(login 凭证;session_key 属用户,不入配置)。
pub const Jscode2Session = struct {
    gpa: std.mem.Allocator,
    openid: []const u8,
    session_key: []const u8,
    unionid: ?[]const u8 = null,

    pub fn deinit(self: *Jscode2Session) void {
        self.gpa.free(@constCast(self.openid));
        self.gpa.free(@constCast(self.session_key));
        if (self.unionid) |u| self.gpa.free(@constCast(u));
    }
};

pub const MiniappService = struct {
    base: Service,
    /// 子服务(对应 Java `BaseWxMaServiceImpl` 构造期 eager 创建的子服务;
    /// 持 `&self.base` 反向引用,初始化后**不得再移动**本结构,同 mp.zig 的 MpService)。
    subscribe_service: subscribe_msg.SubscribeService = undefined,
    qrcode_service: qrcode.QrcodeService = undefined,
    link_service: link.LinkService = undefined,
    uniform_msg_service: uniform_msg.UniformMsgService = undefined,
    intracity_service: intracity_mod.IntracityService = undefined,
    /// 服务端 API 签名状态(`enableApiSignature` 装入;null = 未启用,全部走
    /// 普通明文通道)。启用后 base.executor 被替换为签名装饰器,命中等名 URL
    /// 列表的 POST 透明加密 —— 对应 Java 配置 ApiSignatureAesKey 后的行为。
    sig: ?api_signature.State = null,

    pub fn init(self: *MiniappService, gpa: std.mem.Allocator, cfg: mp_config.ConfigStorage, exec: mp_http.RequestExecutor) void {
        self.* = .{ .base = Service.init(gpa, cfg, exec) };
        self.base.wx_type = .mini_app;
        // 原地组合子服务(Java 各子服务持 WxMaService 引用,组合而非继承)。
        self.subscribe_service = .{ .svc = &self.base };
        self.qrcode_service = .{ .svc = &self.base };
        self.link_service = .{ .svc = &self.base };
        self.uniform_msg_service = .{ .svc = &self.base };
        self.intracity_service = .{ .ma = self };
    }

    /// 启用服务端 API 签名(对应 Java 配置 ApiSignatureAesKey/RsaPrivateKey
    /// 后 BaseWxMaServiceImpl 的自动加密路由)。失败时返回错误且状态不变。
    /// 本结构初始化后不得再移动(装饰器/子服务均持内部指针)。
    pub fn enableApiSignature(self: *MiniappService, args: api_signature.Args) (api_signature.State.InitError || error{AlreadyEnabled})!void {
        if (self.sig != null) return error.AlreadyEnabled; // 已启用:报错防重复包裹
        self.sig = try api_signature.State.init(self.base.gpa, self.base.executor, args, self.base.config.appid());
        self.base.executor = self.sig.?.executor();
    }

    /// 关闭并释放签名状态(恢复原执行器);测试用,生产常驻无需调用。
    pub fn disableApiSignature(self: *MiniappService) void {
        if (self.sig) |*st| {
            self.base.executor = st.inner;
            st.deinit();
            self.sig = null;
        }
    }

    /// 对应 `getSubscribeService()`(任务书要求名 `subscribeMsg()`)。
    pub fn subscribeMsg(self: *MiniappService) *subscribe_msg.SubscribeService {
        return &self.subscribe_service;
    }

    /// 对应 `getQrcodeService()`。
    pub fn qrcodeService(self: *MiniappService) *qrcode.QrcodeService {
        return &self.qrcode_service;
    }

    /// 对应 `getLinkService()`(scheme 面已合并进 LinkService,见 link.zig 头注)。
    pub fn linkService(self: *MiniappService) *link.LinkService {
        return &self.link_service;
    }

    /// 对应 `getMsgService()` 的 sendUniformMsg 面(任务书要求名 `uniformMsgService()`)。
    pub fn uniformMsgService(self: *MiniappService) *uniform_msg.UniformMsgService {
        return &self.uniform_msg_service;
    }

    /// 对应 `getIntracityService()`(同城配送;接口要求 API 签名)。
    pub fn intracity(self: *MiniappService) *intracity_mod.IntracityService {
        return &self.intracity_service;
    }

    /// 对应 `WxMaUserService.getCode2SessionResult(jsCode)`。
    /// GET https://api.weixin.qq.com/sns/jscode2session?appid=&secret=&js_code=&grant_type=authorization_code
    pub fn jsCode2Session(self: *MiniappService, io: std.Io, js_code: []const u8) WxResult(Jscode2Session) {
        const gpa = self.base.gpa;
        const uri = "https://api.weixin.qq.com/sns/jscode2session";
        const qs = [_]mp_service.Query{
            .{ .key = "appid", .value = self.base.config.appid() },
            .{ .key = "secret", .value = self.base.config.secret() },
            .{ .key = "js_code", .value = js_code },
            .{ .key = "grant_type", .value = "authorization_code" },
        };
        // 注意:jscode2session 走「无 access_token」通道(与 Java 一致:
        // Java 该接口用 SimpleHttpGet 绕过 token,附加 token 反而会被微信拒绝)。
        const resp = switch (self.base.executeNoToken(io, uri, &qs, null)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "jscode2session not json", .{}),
        };
        defer parsed.deinit();
        const openid = json_util.getStr(parsed.value, "openid") orelse return .{
            .err = result_mod.WxError.transport(gpa, "jscode2session missing openid", .{}),
        };
        const skey = json_util.getStr(parsed.value, "session_key") orelse return .{
            .err = result_mod.WxError.transport(gpa, "jscode2session missing session_key", .{}),
        };
        const unionid = json_util.getStr(parsed.value, "unionid");

        const openid_d = gpa.dupe(u8, openid) catch return .{ .err = result_mod.WxError.transport(gpa, "oom", .{}) };
        errdefer gpa.free(openid_d);
        const skey_d = gpa.dupe(u8, skey) catch return .{ .err = result_mod.WxError.transport(gpa, "oom", .{}) };
        errdefer gpa.free(skey_d);
        const uni_d = if (unionid) |u| gpa.dupe(u8, u) catch return .{ .err = result_mod.WxError.transport(gpa, "oom", .{}) } else null;

        return .{ .ok = .{ .gpa = gpa, .openid = openid_d, .session_key = skey_d, .unionid = uni_d } };
    }
};

// ---------------------------------------------------------------------------

test "miniapp jscode2session + decrypt skeleton chain" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = mp_http.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "{\"access_token\":\"MAT\",\"expires_in\":7200}" },
        .{ .match = "jscode2session", .response = "{\"openid\":\"oM\",\"session_key\":\"SK\",\"unionid\":\"U1\"}" },
    });

    var cfg = try mp_config.InMemoryConfigStorage.init(gpa, .{
        .ptr = undefined,
        .vtable = &.{ .fetch = struct {
            fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) @import("common").token.FetchOutcome {
                _ = c;
                _ = i;
                const t = g.dupe(u8, "MAT") catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) };
                return .{ .ok = .{ .token = t, .expires_in = 7200 } };
            }
        }.f },
    }, .{ .appid = "MA", .secret = "MS" });
    defer cfg.deinit();

    var ma: MiniappService = undefined;
    ma.init(gpa, cfg.config(), stub.executor());

    const r = ma.jsCode2Session(io, "CODE123");
    switch (r) {
        .ok => |*s| {
            var sess = s.*;
            defer sess.deinit();
            try std.testing.expectEqualStrings("oM", sess.openid);
            try std.testing.expectEqualStrings("SK", sess.session_key);
            try std.testing.expectEqualStrings("U1", sess.unionid.?);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("mini err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
}

test "jscode2session goes through no-token channel: does not append access_token; js errcode is reported directly" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 记录最终 uri + 返回 js 错误(errcode=40029 对应 invalid code)
    const Recorder = struct {
        gpa: std.mem.Allocator,
        resp: []const u8,
        last_uri: [512]u8 = undefined,
        last_len: usize = 0,

        fn uri(self: *const @This()) []const u8 {
            return self.last_uri[0..self.last_len];
        }

        fn executeImpl(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: mp_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) result_mod.WxResult([]u8) {
            _ = i;
            _ = method;
            _ = payload;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last_len = @min(target.len, self.last_uri.len);
            @memcpy(self.last_uri[0..self.last_len], target[0..self.last_len]);
            return .{ .ok = g.dupe(u8, self.resp) catch
                return .{ .err = result_mod.WxError.transport(g, "oom", .{}) } };
        }

        const vtable = mp_http.RequestExecutor.VTable{ .execute = executeImpl };
    };

    var rec = Recorder{ .gpa = gpa, .resp = "{\"errcode\":40029,\"errmsg\":\"invalid code\"}" };
    var cfg = try mp_config.InMemoryConfigStorage.init(gpa, .{
        .ptr = undefined,
        .vtable = &.{ .fetch = struct {
            fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) @import("common").token.FetchOutcome {
                _ = c;
                _ = i;
                const t = g.dupe(u8, "SHOULD_NOT_FETCH") catch
                    return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) };
                return .{ .ok = .{ .token = t, .expires_in = 7200 } };
            }
        }.f },
    }, .{ .appid = "MA", .secret = "MS" });
    defer cfg.deinit();

    var ma: MiniappService = undefined;
    ma.init(gpa, cfg.config(), .{ .ptr = @ptrCast(&rec), .vtable = &Recorder.vtable });

    const r = ma.jsCode2Session(io, "BAD_CODE");
    switch (r) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 40029), err.error_code);
        },
    }
    // 关键断言:-uri 不带 access_token(Java 该接口不带;不然微信会报错)
    try std.testing.expect(std.mem.indexOf(u8, rec.uri(), "/sns/jscode2session") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.uri(), "access_token=") == null);
    try std.testing.expect(std.mem.indexOf(u8, rec.uri(), "js_code=BAD_CODE") != null);
}

test "facade accessors wire subservices to base" {
    const mock_mod = @import("_mock.zig");
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "message/subscribe/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "getwxacodeunlimit", .response = "\x89PNG fake" },
        .{ .match = "template/uniform_send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var ma: MiniappService = undefined;
    ma.init(gpa, cfg.config(), m.executor());

    // 门面 → 订阅消息 send
    const r = ma.subscribeMsg().send(io, .{ .to_user = "o", .template_id = "T" });
    try std.testing.expect(!r.failed());

    // 门面 → 小程序码二进制
    const img = switch (ma.qrcodeService().get_wxacode_unlimit(io, .{ .scene = "s" })) {
        .ok => |b| b,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(img);
    try std.testing.expectEqualStrings("\x89PNG fake", img);

    // 门面 → 统一消息 send
    const u = ma.uniformMsgService().send(io, .{ .to_user = "o", .template_id = "T" });
    try std.testing.expect(!u.failed());

    // 四个子服务均已接到 base 上
    try std.testing.expect(ma.linkService().svc == &ma.base);
    try std.testing.expect(ma.subscribeMsg().svc == &ma.base);
    try std.testing.expect(ma.qrcodeService().svc == &ma.base);
    try std.testing.expect(ma.uniformMsgService().svc == &ma.base);
}
