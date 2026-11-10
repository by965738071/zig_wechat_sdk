//! 公众号配置存储 —— 对应 Java `api.WxMpConfigStorage`(接口)与
//! `api.impl.WxMpInMemoryConfigStorage`(内存实现)。
//!
//! Java 用 interface + 实现类;Zig 用 vtable 结构体做运行时多态(便于接 Redis 版:
//! 对应 `WxMpRedisConfigStorageImpl`,实现同一 vtable 即可)。
//!
//! access_token 的存取协议完全委托 `common/token.zig`(双重检查 + tryLock 自旋),
//! 对应 Java 里散落在 ConfigStorage/ServiceImpl 两边的方法。
const std = @import("std");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;
const result_mod = @import("common").result;
const credentials = @import("common").credentials;

pub const WxResult = result_mod.WxResult;

/// 对应 `WxMpConfigStorage` 接口。
pub const ConfigStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        appid: *const fn (ctx: *anyopaque) []const u8,
        secret: *const fn (ctx: *anyopaque) []const u8,
        /// 回调校验 token(对应 getToken)
        token: *const fn (ctx: *anyopaque) []const u8,
        /// 消息加解密 EncodingAESKey(对应 getAesKey)
        aes_key: *const fn (ctx: *anyopaque) []const u8,
        /// 完整 access_token 获取协议(force_refresh 对应 Java 参数);
        /// 结果拷贝进 buf(≥256 字节),对应 getAccessToken(boolean)。
        acquire_access_token: *const fn (ctx: *anyopaque, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8),
        /// 仅当缓存仍等于 used_token 时失效(对应 executeInternal 的
        /// 「equals 后才 expireAccessToken」防护)。返回是否真的失效了。
        expire_access_token: *const fn (ctx: *anyopaque, io: std.Io, used_token: []const u8) bool,
        /// jsapi_ticket 获取协议(corresponds to `BaseWxMpServiceImpl#getTicket(JSAPI, boolean)`):
        /// force_refresh -> expireTicket;过期判断 + getTicketLock 双重检查;
        /// 拉取 GET_TICKET_URL -> updateTicket(type, ticket, expires_in);
        /// 结果拷贝进 buf。骨架复用 `token.acquire`(含 -200s 余量与并发保护)。
        acquire_jsapi_ticket: *const fn (ctx: *anyopaque, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8),
        /// 对应 `isTicketExpired(JSAPI)`。
        is_jsapi_ticket_expired: *const fn (ctx: *anyopaque, io: std.Io) bool,
        /// 对应 `expireTicket(JSAPI)`,带「比对 used_ticket 才失效」防护。
        expire_jsapi_ticket: *const fn (ctx: *anyopaque, io: std.Io, used_ticket: []const u8) bool,
    };

    pub fn appid(self: ConfigStorage) []const u8 {
        return self.vtable.appid(self.ptr);
    }
    pub fn secret(self: ConfigStorage) []const u8 {
        return self.vtable.secret(self.ptr);
    }
    pub fn token(self: ConfigStorage) []const u8 {
        return self.vtable.token(self.ptr);
    }
    pub fn aesKey(self: ConfigStorage) []const u8 {
        return self.vtable.aes_key(self.ptr);
    }
    pub fn acquireAccessToken(self: ConfigStorage, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        return self.vtable.acquire_access_token(self.ptr, io, buf, force_refresh);
    }
    pub fn expireAccessToken(self: ConfigStorage, io: std.Io, used_token: []const u8) bool {
        return self.vtable.expire_access_token(self.ptr, io, used_token);
    }
    pub fn acquireJsapiTicket(self: ConfigStorage, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        return self.vtable.acquire_jsapi_ticket(self.ptr, io, buf, force_refresh);
    }
    pub fn isJsapiTicketExpired(self: ConfigStorage, io: std.Io) bool {
        return self.vtable.is_jsapi_ticket_expired(self.ptr, io);
    }
    pub fn expireJsapiTicket(self: ConfigStorage, io: std.Io, used_ticket: []const u8) bool {
        return self.vtable.expire_jsapi_ticket(self.ptr, io, used_ticket);
    }
};

/// 内存实现(对应 `WxMpInMemoryConfigStorage`)。
/// 字符串字段全部 gpa 拥有(对应 Java volatile 字段 + setter;Zig 侧初始化后不
/// 支持热切换,如需 setXxx 可再补 setter 并加锁)。
/// 默认 ticket 刷新桩:未注入真实 ticket fetcher 时返回配置错误(诚实,不伪造)。
/// 生产经 `Service`/`http.JsapiTicketFetcher` 注入;离线单测可注入可控 stub。
const StubTicketFetcher = struct {
    fn f(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) token_mod.FetchOutcome {
        _ = ctx;
        _ = io;
        return .{ .err = error_mod.WxError.configError(gpa, "未配置 jsapi_ticket 刷新通道(ticket_fetcher)", .{}) };
    }
    const fetcher = token_mod.Fetcher{ .ptr = undefined, .vtable = &.{ .fetch = f } };
};

pub const InMemoryConfigStorage = struct {
    gpa: std.mem.Allocator,
    slot: token_mod.TokenSlot,
    /// token 刷新通道(GET cgi-bin/token 或 POST stable_token),由调用方注入
    fetcher: token_mod.Fetcher,
    /// jsapi_ticket 缓存槽 —— 对应 Java `WxMpDefaultConfigImpl` 的
    /// jsapiTicket / jsapiTicketExpiresTime / jsapiTicketLock 三件套。
    /// 与 access_token 用**各自独立**的 TokenSlot(各自一把锁、互不阻塞)。
    ticket_slot: token_mod.TokenSlot,
    /// ticket 刷新通道(GET cgi-bin/ticket/getticket?type=jsapi),由调用方注入。
    ticket_fetcher: token_mod.Fetcher,
    appid_: []u8,
    secret_: []u8,
    token_: []u8,
    aes_key_: []u8,

    pub const InitArgs = struct {
        appid: []const u8,
        secret: []const u8,
        /// 可空(直连 API 不校验回调时)
        token: []const u8 = "",
        aes_key: []const u8 = "",
        /// 可选:jsapi_ticket 刷新通道。空 -> 用 StubTicketFetcher(acquire 时报配置错误),
        /// 这样 23 处既有 `init` 调用点无需改动,且离线单测可注入可控 stub。
        ticket_fetcher: ?token_mod.Fetcher = null,
    };

    pub fn init(gpa: std.mem.Allocator, fetcher: token_mod.Fetcher, args: InitArgs) !InMemoryConfigStorage {
        return .{
            .gpa = gpa,
            .slot = token_mod.TokenSlot.init(gpa),
            .fetcher = fetcher,
            .ticket_slot = token_mod.TokenSlot.init(gpa),
            .ticket_fetcher = args.ticket_fetcher orelse StubTicketFetcher.fetcher,
            .appid_ = try gpa.dupe(u8, args.appid),
            .secret_ = try gpa.dupe(u8, args.secret),
            .token_ = try gpa.dupe(u8, args.token),
            .aes_key_ = try gpa.dupe(u8, args.aes_key),
        };
    }

    /// 凭证注入构造(对应 Java 从环境/配置中心注入 appid/secret)。
    /// appid/secret 由 `credentials.Source`(文件/环境变量/文本)读入,值由返回
    /// 的 storage 拥有;错误只暴露来源标识,不回显材料。与 `init` 同协议,只是把
    /// 凭据来源外置,便于生产从文件/环境变量加载、离线测试用 `Source.text`。
    pub const CredentialArgs = struct {
        appid: credentials.Source,
        secret: credentials.Source,
        token: []const u8 = "",
        aes_key: []const u8 = "",
        ticket_fetcher: ?token_mod.Fetcher = null,
    };

    pub fn initWithCredentials(gpa: std.mem.Allocator, fetcher: token_mod.Fetcher, io: std.Io, args: CredentialArgs) !InMemoryConfigStorage {
        const appid = try credentials.read(gpa, io, args.appid);
        defer gpa.free(appid);
        const secret = try credentials.read(gpa, io, args.secret);
        defer gpa.free(secret);
        return init(gpa, fetcher, .{
            .appid = appid,
            .secret = secret,
            .token = args.token,
            .aes_key = args.aes_key,
            .ticket_fetcher = args.ticket_fetcher,
        });
    }

    pub fn deinit(self: *InMemoryConfigStorage) void {
        self.gpa.free(self.appid_);
        self.gpa.free(self.secret_);
        self.gpa.free(self.token_);
        self.gpa.free(self.aes_key_);
        self.slot.deinit();
        self.ticket_slot.deinit();
    }

    pub fn config(self: *InMemoryConfigStorage) ConfigStorage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn appidImpl(ctx: *anyopaque) []const u8 {
        return field(ctx).appid_;
    }
    fn secretImpl(ctx: *anyopaque) []const u8 {
        return field(ctx).secret_;
    }
    fn tokenImpl(ctx: *anyopaque) []const u8 {
        return field(ctx).token_;
    }
    fn aesKeyImpl(ctx: *anyopaque) []const u8 {
        return field(ctx).aes_key_;
    }
    fn acquireImpl(ctx: *anyopaque, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        const self: *InMemoryConfigStorage = @ptrCast(@alignCast(ctx));
        return token_mod.acquire(&self.slot, io, buf, force_refresh, .{}, self.fetcher);
    }
    fn expireImpl(ctx: *anyopaque, io: std.Io, used: []const u8) bool {
        const self: *InMemoryConfigStorage = @ptrCast(@alignCast(ctx));
        return self.slot.expireIfUnchanged(io, used);
    }
    /// 对应 `BaseWxMpServiceImpl#getTicket(JSAPI, forceRefresh)`:
    /// forceRefresh -> expireTicket;isTicketExpired -> getTicketLock 双重检查 ->
    /// 拉取 -> updateTicket(expires_in)。整条协议由 `token.acquire` 提供。
    fn acquireTicketImpl(ctx: *anyopaque, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        const self: *InMemoryConfigStorage = @ptrCast(@alignCast(ctx));
        return token_mod.acquire(&self.ticket_slot, io, buf, force_refresh, .{}, self.ticket_fetcher);
    }
    fn isTicketExpiredImpl(ctx: *anyopaque, io: std.Io) bool {
        const self: *InMemoryConfigStorage = @ptrCast(@alignCast(ctx));
        return self.ticket_slot.isExpired(io);
    }
    fn expireTicketImpl(ctx: *anyopaque, io: std.Io, used: []const u8) bool {
        const self: *InMemoryConfigStorage = @ptrCast(@alignCast(ctx));
        return self.ticket_slot.expireIfUnchanged(io, used);
    }

    fn field(ctx: *anyopaque) *InMemoryConfigStorage {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable = ConfigStorage.VTable{
        .appid = appidImpl,
        .secret = secretImpl,
        .token = tokenImpl,
        .aes_key = aesKeyImpl,
        .acquire_access_token = acquireImpl,
        .expire_access_token = expireImpl,
        .acquire_jsapi_ticket = acquireTicketImpl,
        .is_jsapi_ticket_expired = isTicketExpiredImpl,
        .expire_jsapi_ticket = expireTicketImpl,
    };
};

// ---------------------------------------------------------------------------

test "in-memory config storage acquire via fake fetcher" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const F = struct {
        count: usize = 0,
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = i;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.count += 1;
            const t = g.dupe(u8, "fake-token") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var f = F{};
    const fetcher = token_mod.Fetcher{ .ptr = @ptrCast(&f), .vtable = &.{ .fetch = F.f } };

    var cfg = try InMemoryConfigStorage.init(gpa, fetcher, .{ .appid = "wxAPP", .secret = "SEC", .token = "TK", .aes_key = "AES" });
    defer cfg.deinit();

    var buf: [256]u8 = undefined;
    const r = cfg.config().acquireAccessToken(io, &buf, false);
    switch (r) {
        .ok => |t| try std.testing.expectEqualStrings("fake-token", t),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.TestUnexpectedResult;
        },
    }
    // 第二次走缓存,fetcher 不再被调用
    _ = cfg.config().acquireAccessToken(io, &buf, false);
    try std.testing.expectEqual(@as(usize, 1), f.count);

    // expireAccessToken:used_token 匹配才失效(不匹配返回 false)
    try std.testing.expect(!cfg.config().expireAccessToken(io, "wrong"));
    try std.testing.expect(cfg.config().expireAccessToken(io, "fake-token"));
    _ = cfg.config().acquireAccessToken(io, &buf, false);
    try std.testing.expectEqual(@as(usize, 2), f.count);
}

// ---- jsapi_ticket 槽:可控时钟/stub 离线单测(对齐 Java getTicket/isTicketExpired)----

const TestClock = struct {
    now_ns: i96 = 1_700_000_000 * std.time.ns_per_s,
    fn nowFn(ctx: *anyopaque, io: std.Io) i96 {
        _ = io;
        return @as(*TestClock, @ptrCast(@alignCast(ctx))).now_ns;
    }
    fn install(self: *TestClock, slot: *token_mod.TokenSlot) void {
        slot.now_fn = nowFn;
        slot.now_ctx = @ptrCast(self);
    }
};

const TicketFetchStub = struct {
    count: usize = 0,
    value: []const u8 = "TICKET",
    expires_in: i64 = 7200,
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = i;
        const self: *@This() = @ptrCast(@alignCast(c));
        self.count += 1;
        const t = g.dupe(u8, self.value) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = t, .expires_in = self.expires_in } };
    }
    fn fetcher(self: *@This()) token_mod.Fetcher {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = f } };
    }
};

test "jsapi ticket slot: cache, expiry, force refresh, expire guard (controllable clock)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tfs = TicketFetchStub{};
    const AF = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .ok = .{ .token = g.dupe(u8, "AT") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
        }
    };
    var cfg = try InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = AF.f } }, .{
        .appid = "wxAPP",
        .secret = "SEC",
        .ticket_fetcher = tfs.fetcher(),
    });
    defer cfg.deinit();

    // 注入可控时钟到 ticket 槽(access_token 槽仍用真实时钟,互不干扰)
    var clock = TestClock{};
    clock.install(&cfg.ticket_slot);
    const c = cfg.config();

    var buf: [256]u8 = undefined;
    // 首次 -> 拉取(TICKET),count=1
    switch (c.acquireJsapiTicket(io, &buf, false)) {
        .ok => |t| try std.testing.expectEqualStrings("TICKET", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedTicketError;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), tfs.count);
    try std.testing.expect(!c.isJsapiTicketExpired(io));

    // 第二次 -> 命中缓存,count 仍为 1
    _ = c.acquireJsapiTicket(io, &buf, false);
    try std.testing.expectEqual(@as(usize, 1), tfs.count);

    // force_refresh -> 强制失效并重新拉取,count=2(对应 getTicket(type, true) -> expireTicket)
    switch (c.acquireJsapiTicket(io, &buf, true)) {
        .ok => |t| try std.testing.expectEqualStrings("TICKET", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedTicketError;
        },
    }
    try std.testing.expectEqual(@as(usize, 2), tfs.count);

    // 时钟推进超过 expires_in(7200s)- 余量(200s)= 7000s -> 过期 -> 再拉取,count=3
    clock.now_ns += 7001 * std.time.ns_per_s;
    try std.testing.expect(c.isJsapiTicketExpired(io));
    _ = c.acquireJsapiTicket(io, &buf, false);
    try std.testing.expectEqual(@as(usize, 3), tfs.count);
    try std.testing.expect(!c.isJsapiTicketExpired(io));

    // expireJsapiTicket:used_ticket 匹配才失效(不匹配 false)
    try std.testing.expect(!c.expireJsapiTicket(io, "wrong"));
    try std.testing.expect(c.expireJsapiTicket(io, "TICKET"));
    try std.testing.expect(c.isJsapiTicketExpired(io));
    _ = c.acquireJsapiTicket(io, &buf, false);
    try std.testing.expectEqual(@as(usize, 4), tfs.count);

    // access_token 与 ticket 是独立槽,互不影响
    var abuf: [256]u8 = undefined;
    _ = c.acquireAccessToken(io, &abuf, false);
    try std.testing.expect(!c.isJsapiTicketExpired(io));
}

test "jsapi ticket: no ticket_fetcher -> honest config error, not fake" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const AF = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .ok = .{ .token = g.dupe(u8, "AT") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
        }
    };
    var cfg = try InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = AF.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var buf: [256]u8 = undefined;
    switch (cfg.config().acquireJsapiTicket(io, &buf, false)) {
        .ok => return error.ShouldNotSucceed,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.config, err.source);
        },
    }
}

test "InMemoryConfigStorage.initWithCredentials: appid/secret from credential sources" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const DummyFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .ok = .{ .token = g.dupe(u8, "T") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
        }
    };
    const fetcher = token_mod.Fetcher{ .ptr = undefined, .vtable = &.{ .fetch = DummyFetch.f } };

    // 只回显来源标识的 text 源(非真实凭证),保持离线;appid/secret 分别读入。
    var cfg = try InMemoryConfigStorage.initWithCredentials(gpa, fetcher, io, .{
        .appid = .{ .text = "wxAPP_FROM_SOURCE" },
        .secret = .{ .text = "SECRET_FROM_SOURCE" },
        .token = "TK",
        .aes_key = "AES",
    });
    defer cfg.deinit();
    const view = cfg.config();
    try std.testing.expectEqualStrings("wxAPP_FROM_SOURCE", view.appid());
    try std.testing.expectEqualStrings("SECRET_FROM_SOURCE", view.secret());
    try std.testing.expectEqualStrings("TK", view.token());
    try std.testing.expectEqualStrings("AES", view.aesKey());
}
