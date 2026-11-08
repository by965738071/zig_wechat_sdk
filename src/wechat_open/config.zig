//! 第三方平台配置存储 —— 对应 Java `config.WxOpenConfigStorage`(接口)、
//! `config.impl.WxOpenInMemoryConfigStorage`(内存实现)与
//! `impl.WxOpenInnerConfigStorage`(内部类,把「某个授权方」伪装成 WxMpConfigStorage)。
//!
//! 与 mp/miniapp 的本质区别:两层 token
//!   1. component_access_token(平台级;依赖微信每 10 分钟推送的 component_verify_ticket);
//!   2. authorizer_access_token(**按授权方 appid 分桶**,配套 authorizer_refresh_token,
//!      且 refresh_token **每次刷新都会轮换**,必须持久化 —— Java 里踩坑最多的点)。
//! 另:Java `getLockByKey(key)` 为每个 token 键单独一把锁;Zig 用
//! common/lock.LockRegistry 按 key 分锁(与 Redis 版同构),见 authorizer_locks。
const std = @import("std");
const token_mod = @import("common").token;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const lock_mod = @import("common").lock;
const mp_config = @import("wechat_mp").config;

pub const WxResult = result_mod.WxResult;
pub const WxError = error_mod.WxError;

/// 授权方 token 刷新源(对应 Java `doGetComponentAccessTokenRequest` 之外,
/// 授权方侧的 `WxOpenService.getWxOpenComponentService()
///   .getWxMpServiceByAppid(...)` 内部走 api_authorizer_token 的通道)。
/// 返回的 new_refresh_token 由存储层负责写回(轮换语义)。
pub const AuthorizerTokenSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fetch: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, authorizer_appid: []const u8, refresh_token: []const u8) AuthorizerOutcome,
    };

    pub fn fetch(self: AuthorizerTokenSource, gpa: std.mem.Allocator, io: std.Io, appid: []const u8, refresh: []const u8) AuthorizerOutcome {
        return self.vtable.fetch(self.ptr, gpa, io, appid, refresh);
    }
};

pub const AuthorizerOutcome = union(enum) {
    ok: struct { token: []u8, expires_in: i64, new_refresh_token: []u8 }, // 三者均 gpa 拥有
    err: WxError,
};

/// 对应 `WxOpenConfigStorage`(骨架收录核心面)。
pub const OpenConfigStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        component_appid: *const fn (ctx: *anyopaque) []const u8,
        component_secret: *const fn (ctx: *anyopaque) []const u8,
        /// component_verify_ticket 读写(微信推送 → set;取 component token 时读)
        component_verify_ticket: *const fn (ctx: *anyopaque, buf: []u8) ?[]const u8,
        set_component_verify_ticket: *const fn (ctx: *anyopaque, ticket: []const u8) bool,
        acquire_component_access_token: *const fn (ctx: *anyopaque, io: std.Io, buf: []u8, force: bool) WxResult([]const u8),
        expire_component_access_token: *const fn (ctx: *anyopaque, io: std.Io, used: []const u8) bool,
        /// 授权方 access_token(按 appid 分桶)
        acquire_authorizer_access_token: *const fn (ctx: *anyopaque, io: std.Io, authorizer_appid: []const u8, buf: []u8, force: bool) WxResult([]const u8),
        expire_authorizer_access_token: *const fn (ctx: *anyopaque, io: std.Io, authorizer_appid: []const u8, used: []const u8) bool,
        authorizer_refresh_token: *const fn (ctx: *anyopaque, authorizer_appid: []const u8) ?[]const u8,
        /// 写回(或首次注册)某授权方的 token 桶 —— 对应 Java
        /// `updateAuthorizerAccessToken` + `updateAuthorizerRefreshToken`
        /// (query_auth / getAuthorizerList 路径)。access_token 传 null 表示只更新
        /// refresh_token(列表接口只回 refresh)。
        store_authorizer: *const fn (ctx: *anyopaque, io: std.Io, authorizer_appid: []const u8, access_token: ?[]const u8, expires_in: i64, refresh_token: []const u8) bool,
    };

    pub fn componentAppid(self: OpenConfigStorage) []const u8 {
        return self.vtable.component_appid(self.ptr);
    }
    pub fn componentSecret(self: OpenConfigStorage) []const u8 {
        return self.vtable.component_secret(self.ptr);
    }
    pub fn componentVerifyTicket(self: OpenConfigStorage, buf: []u8) ?[]const u8 {
        return self.vtable.component_verify_ticket(self.ptr, buf);
    }
    pub fn setComponentVerifyTicket(self: OpenConfigStorage, ticket: []const u8) bool {
        return self.vtable.set_component_verify_ticket(self.ptr, ticket);
    }
    pub fn acquireComponentAccessToken(self: OpenConfigStorage, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        return self.vtable.acquire_component_access_token(self.ptr, io, buf, force);
    }
    pub fn expireComponentAccessToken(self: OpenConfigStorage, io: std.Io, used: []const u8) bool {
        return self.vtable.expire_component_access_token(self.ptr, io, used);
    }
    pub fn acquireAuthorizerAccessToken(self: OpenConfigStorage, io: std.Io, appid: []const u8, buf: []u8, force: bool) WxResult([]const u8) {
        return self.vtable.acquire_authorizer_access_token(self.ptr, io, appid, buf, force);
    }
    pub fn expireAuthorizerAccessToken(self: OpenConfigStorage, io: std.Io, appid: []const u8, used: []const u8) bool {
        return self.vtable.expire_authorizer_access_token(self.ptr, io, appid, used);
    }
    pub fn authorizerRefreshToken(self: OpenConfigStorage, appid: []const u8) ?[]const u8 {
        return self.vtable.authorizer_refresh_token(self.ptr, appid);
    }
    pub fn storeAuthorizer(self: OpenConfigStorage, io: std.Io, appid: []const u8, access_token: ?[]const u8, expires_in: i64, refresh_token: []const u8) bool {
        return self.vtable.store_authorizer(self.ptr, io, appid, access_token, expires_in, refresh_token);
    }
};

/// 内存实现。与 Java 同:component 一个槽 + authorizer 一个 map。
/// 锁分两层(对齐 Java `getLockByKey(appid)` + ConcurrentHashMap):
/// - `authorizer_locks`:按 appid 分锁(内存版 = LockRegistry,换 Redis 实现即分布式锁);
/// - `authorizer_mutex`:仅保护 `authorizers` 这个 StringHashMap 的结构(getPtr/put),
///   对应 Java ConcurrentHashMap 的内部同步——该容器非并发安全,无法按 appid 分锁。
/// 授权方 token 刷新本身由各 entry 自带的 `TokenSlot.mutex` 串行化(等价于 Java 的
/// `appId:accessTokenLock`),故不同 appid 的刷新互不阻塞。
pub const InMemoryOpenConfigStorage = struct {
    gpa: std.mem.Allocator,
    component_appid_: []u8,
    component_secret_: []u8,
    /// 对应 Java 的 volatile String ticket(缓冲区固定,10min 一换)
    verify_ticket_buf: [512]u8 = undefined,
    verify_ticket_len: usize = 0,

    component_slot: token_mod.TokenSlot,
    /// component_access_token 刷新源（POST api_component_token，依赖 verify_ticket）
    component_fetcher: token_mod.Fetcher,

    authorizers: std.StringHashMap(Authorizer),
    /// 结构短锁:只护 authorizers map 的查找/插入,不承载按 appid 的业务互斥。
    authorizer_mutex: std.Io.Mutex = .init,
    /// 按 appid 分锁(对应 Java `getLockByKey(appid)`,进程内注册表实现)。
    authorizer_locks: lock_mod.LockRegistry,
    /// 刷新授权方 token 的数据源（HTTP 或测试桩）
    authorizer_source: AuthorizerTokenSource,

    pub const Authorizer = struct {
        appid: []u8,
        slot: token_mod.TokenSlot,
        refresh_token: []u8, // 轮换后原地更新
    };

    pub fn init(
        gpa: std.mem.Allocator,
        component_appid: []const u8,
        component_secret: []const u8,
        component_fetcher: token_mod.Fetcher,
        authorizer_source: AuthorizerTokenSource,
    ) !InMemoryOpenConfigStorage {
        return .{
            .gpa = gpa,
            .component_appid_ = try gpa.dupe(u8, component_appid),
            .component_secret_ = try gpa.dupe(u8, component_secret),
            .component_slot = token_mod.TokenSlot.init(gpa),
            .component_fetcher = component_fetcher,
            .authorizers = std.StringHashMap(Authorizer).init(gpa),
            .authorizer_locks = lock_mod.LockRegistry.init(gpa),
            .authorizer_source = authorizer_source,
        };
    }

    pub fn deinit(self: *InMemoryOpenConfigStorage) void {
        self.gpa.free(self.component_appid_);
        self.gpa.free(self.component_secret_);
        self.component_slot.deinit();
        var it = self.authorizers.valueIterator();
        while (it.next()) |a| {
            self.gpa.free(a.appid);
            self.gpa.free(a.refresh_token);
            a.slot.deinit();
        }
        self.authorizers.deinit();
        self.authorizer_locks.deinit();
    }

    /// 对应 Java `WxOpenConfigStorage.getLockByKey(appid)`:按授权方 appid 取锁。
    /// 进程内由 LockRegistry 提供(同一 appid 串行、不同 appid 互不阻塞);
    /// 换 Redis 实现即为跨进程分布式锁。
    pub fn authorizerLock(self: *InMemoryOpenConfigStorage, io: std.Io, appid: []const u8) !lock_mod.DistributedLock {
        return self.authorizer_locks.get(io, appid);
    }

    /// 拿到(必要时用业务给的 refresh_token 注册)授权方条目。
    /// 对应 Java `updateAuthorizerRefreshToken/getAuthorizerRefreshToken` 一族。
    /// 对应 Java `getLockByKey(appid)`:先用按 appid 的锁串行化同一授权方的
    /// get-or-create,再用 `authorizer_mutex` 短锁保护 StringHashMap 的结构插入。
    pub fn ensureAuthorizer(self: *InMemoryOpenConfigStorage, io: std.Io, appid: []const u8, initial_refresh_token: []const u8) !*Authorizer {
        const per_appid = try self.authorizerLock(io, appid);
        per_appid.lock(io);
        defer per_appid.unlock(io);

        self.authorizer_mutex.lockUncancelable(io);
        defer self.authorizer_mutex.unlock(io);
        if (self.authorizers.getPtr(appid)) |a| return a;
        const entry = Authorizer{
            .appid = try self.gpa.dupe(u8, appid),
            .slot = token_mod.TokenSlot.init(self.gpa),
            .refresh_token = try self.gpa.dupe(u8, initial_refresh_token),
        };
        try self.authorizers.put(entry.appid, entry);
        return self.authorizers.getPtr(appid).?;
    }

    pub fn config(self: *InMemoryOpenConfigStorage) OpenConfigStorage {
        return .{ .ptr = @ptrCast(self), .vtable = &open_vtable };
    }

    // ---- OpenConfigStorage vtable 实现 ----

    fn f(ctx: *anyopaque) *InMemoryOpenConfigStorage {
        return @ptrCast(@alignCast(ctx));
    }
    fn compAppidImpl(ctx: *anyopaque) []const u8 {
        return f(ctx).component_appid_;
    }
    fn compSecretImpl(ctx: *anyopaque) []const u8 {
        return f(ctx).component_secret_;
    }
    fn ticketGetImpl(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self = f(ctx);
        if (self.verify_ticket_len == 0) return null;
        const n = @min(self.verify_ticket_len, buf.len);
        @memcpy(buf[0..n], self.verify_ticket_buf[0..self.verify_ticket_len]);
        return buf[0..n];
    }
    fn ticketSetImpl(ctx: *anyopaque, ticket: []const u8) bool {
        const self = f(ctx);
        if (ticket.len > self.verify_ticket_buf.len) return false;
        @memcpy(self.verify_ticket_buf[0..ticket.len], ticket);
        self.verify_ticket_len = ticket.len;
        return true;
    }
    fn compAcquireImpl(ctx: *anyopaque, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        const self = f(ctx);
        return token_mod.acquire(&self.component_slot, io, buf, force, .{}, self.component_fetcher);
    }
    fn compExpireImpl(ctx: *anyopaque, io: std.Io, used: []const u8) bool {
        return f(ctx).component_slot.expireIfUnchanged(io, used);
    }

    /// 授权方槽位的刷新闭包:entry + storage 成对出现在 acquire 的同一次调用栈里,
    /// 所以下面 authAcquireImpl 的栈局部 AuthCtx 生命周期足够(fetch 同步执行)。
    fn authAcquireImpl(ctx: *anyopaque, io: std.Io, appid: []const u8, buf: []u8, force: bool) WxResult([]const u8) {
        const self: *InMemoryOpenConfigStorage = @ptrCast(@alignCast(ctx));
        const entry = self.authorizers.getPtr(appid) orelse
            return .{ .err = WxError.configError(self.gpa, "authorizer not registered: {s}", .{appid}) };
        // 每个 entry 一个「闭包」:entry + storage,放进线程局部?骨架简化:
        // 借助 entry 内嵌的 fetch_ctx。见 AuthCtx。
        var auth_ctx = AuthCtx{ .storage = self, .entry = entry };
        const fetcher = token_mod.Fetcher{ .ptr = @ptrCast(&auth_ctx), .vtable = &AuthCtx.vtable };
        return token_mod.acquire(&entry.slot, io, buf, force, .{}, fetcher);
    }

    const AuthCtx = struct {
        storage: *InMemoryOpenConfigStorage,
        entry: *Authorizer,

        fn fetchPtr(c: *anyopaque, gpa: std.mem.Allocator, io: std.Io) token_mod.FetchOutcome {
            const self: *AuthCtx = @ptrCast(@alignCast(c));
            const src = self.storage.authorizer_source;
            switch (src.fetch(gpa, io, self.entry.appid, self.entry.refresh_token)) {
                .ok => |r| {
                    // refresh_token 轮换:写回条目(此处持有 slot 锁,同 entry 串行安全)
                    gpa.free(self.entry.refresh_token);
                    self.entry.refresh_token = r.new_refresh_token;
                    return .{ .ok = .{ .token = r.token, .expires_in = r.expires_in } };
                },
                .err => |e| return .{ .err = e },
            }
        }

        const vtable = token_mod.Fetcher.VTable{ .fetch = fetchPtr };
    };

    fn authExpireImpl(ctx: *anyopaque, io: std.Io, appid: []const u8, used: []const u8) bool {
        const self: *InMemoryOpenConfigStorage = @ptrCast(@alignCast(ctx));
        const entry = self.authorizers.getPtr(appid) orelse return false;
        return entry.slot.expireIfUnchanged(io, used);
    }

    fn refreshTokenImpl(ctx: *anyopaque, appid: []const u8) ?[]const u8 {
        const self: *InMemoryOpenConfigStorage = @ptrCast(@alignCast(ctx));
        const entry = self.authorizers.getPtr(appid) orelse return null;
        return entry.refresh_token;
    }

    /// 对应 Java `updateAuthorizerAccessToken/updateAuthorizerRefreshToken`:
    /// 条目不存在则新建(ensureAuthorizer)，存在则覆盖 token 槽与 refresh_token。
    fn storeAuthorizerImpl(
        ctx: *anyopaque,
        io: std.Io,
        appid: []const u8,
        access_token: ?[]const u8,
        expires_in: i64,
        refresh_token: []const u8,
    ) bool {
        const self = f(ctx);
        const entry = self.ensureAuthorizer(io, appid, refresh_token) catch return false;
        if (access_token) |t| entry.slot.update(io, t, expires_in) catch return false;
        // refresh_token 统一覆盖(新建时 ensureAuthorizer 已 dupe 同值，此处只处理差异)
        if (!std.mem.eql(u8, entry.refresh_token, refresh_token)) {
            const dupe = self.gpa.dupe(u8, refresh_token) catch return false;
            self.gpa.free(entry.refresh_token);
            entry.refresh_token = dupe;
        }
        return true;
    }

    const open_vtable = OpenConfigStorage.VTable{
        .component_appid = compAppidImpl,
        .component_secret = compSecretImpl,
        .component_verify_ticket = ticketGetImpl,
        .set_component_verify_ticket = ticketSetImpl,
        .acquire_component_access_token = compAcquireImpl,
        .expire_component_access_token = compExpireImpl,
        .acquire_authorizer_access_token = authAcquireImpl,
        .expire_authorizer_access_token = authExpireImpl,
        .authorizer_refresh_token = refreshTokenImpl,
        .store_authorizer = storeAuthorizerImpl,
    };
};

/// InnerConfigStorage 适配器 —— 对应 Java `WxOpenInnerConfigStorage`:
/// 把「第三方平台 + 某个授权方 appid」伪装成一份 `WxMpConfigStorage`,
/// 这样所有现成的 mp 服务(Service/子服务)不改一行就能替授权方发 API 请求。
/// 这是整个 open 模块最关键的架构模式。
pub const InnerView = struct {
    open: OpenConfigStorage,
    appid: []const u8,
    gpa: std.mem.Allocator,

    pub fn mpConfig(self: *InnerView) mp_config.ConfigStorage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn appidImpl(ctx: *anyopaque) []const u8 {
        return @as(*InnerView, @ptrCast(@alignCast(ctx))).appid;
    }
    fn secretImpl(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return ""; // 授权方没有 secret(第三方代发 API 不需要)
    }
    fn tokenImpl(ctx: *anyopaque) []const u8 {
        _ = ctx; // 第三方代发场景的回调 token/aesKey 由平台自有配置决定,骨架置空
        return "";
    }
    fn aesKeyImpl(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "";
    }
    fn acquireImpl(ctx: *anyopaque, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        const self: *InnerView = @ptrCast(@alignCast(ctx));
        return self.open.acquireAuthorizerAccessToken(io, self.appid, buf, force);
    }
    fn expireImpl(ctx: *anyopaque, io: std.Io, used: []const u8) bool {
        const self: *InnerView = @ptrCast(@alignCast(ctx));
        return self.open.expireAuthorizerAccessToken(io, self.appid, used);
    }
    // jsapi ticket:开放平台 InnerView(授权方伪装成公众号)在本骨架不管理 ticket。
    // 与 Java `WxOpenInnerConfigStorage` 不同,这里显式返回「不支持」而非伪造:
    // acquire -> 配置错误;isExpired -> true(保守,任何尝试都会走刷新并拿到错误);
    // expire -> false(无缓存可失效)。
    fn acquireTicketImpl(ctx: *anyopaque, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        _ = io;
        _ = buf;
        _ = force;
        const self: *InnerView = @ptrCast(@alignCast(ctx));
        return .{ .err = WxError.configError(self.gpa, "开放平台 InnerView 不管理 jsapi_ticket", .{}) };
    }
    fn isTicketExpiredImpl(ctx: *anyopaque, io: std.Io) bool {
        _ = ctx;
        _ = io;
        return true;
    }
    fn expireTicketImpl(ctx: *anyopaque, io: std.Io, used: []const u8) bool {
        _ = ctx;
        _ = io;
        _ = used;
        return false;
    }

    const vtable = mp_config.ConfigStorage.VTable{
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

test "open config: getLockByKey(appid) per-appid locks + registration" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Dummy = struct {
        fn compFetch(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = WxError.transport(g, "unused", .{}) };
        }
        fn authFetch(c: *anyopaque, g: std.mem.Allocator, i: std.Io, appid: []const u8, refresh: []const u8) AuthorizerOutcome {
            _ = c;
            _ = i;
            _ = appid;
            _ = refresh;
            return .{ .err = WxError.transport(g, "unused", .{}) };
        }
    };
    var storage = try InMemoryOpenConfigStorage.init(gpa, "wxCOMP", "SECRET", .{
        .ptr = undefined,
        .vtable = &.{ .fetch = Dummy.compFetch },
    }, .{
        .ptr = undefined,
        .vtable = &.{ .fetch = Dummy.authFetch },
    });
    defer storage.deinit();

    // 对应 Java getLockByKey(appid):同一 appid 互斥,不同 appid 互不阻塞。
    const a1 = try storage.authorizerLock(io, "wxA");
    const a2 = try storage.authorizerLock(io, "wxA");
    const b = try storage.authorizerLock(io, "wxB");
    try std.testing.expect(a1.tryLock(io, 0));
    try std.testing.expect(!a2.tryLock(io, 0));
    try std.testing.expect(b.tryLock(io, 0));
    a1.unlock(io);
    b.unlock(io);

    // ensureAuthorizer 走按 appid 分锁路径,多个授权方各自独立注册且互不覆盖。
    const ea = try storage.ensureAuthorizer(io, "wxA", "R-A");
    const eb = try storage.ensureAuthorizer(io, "wxB", "R-B");
    try std.testing.expectEqualStrings("R-A", ea.refresh_token);
    try std.testing.expectEqualStrings("R-B", eb.refresh_token);
    const ea2 = try storage.ensureAuthorizer(io, "wxA", "IGNORED");
    try std.testing.expectEqualStrings("R-A", ea2.refresh_token);
}
