//! Token 槽位与刷新协议 —— 对应各模块 `ConfigStorage.isAccessTokenExpired / updateAccessToken /
//! getAccessTokenLock` 与 `BaseWx*ServiceImpl.getAccessToken(forceRefresh)` 的时序。
//!
//! 这是整套 SDK 复用度最高的一段逻辑（mp / miniapp / open / pay 都同构复刻过），
//! 骨架里抽成一份公共实现。精确语义（对齐 Java）：
//! 1. 快路径：未强制刷新且未过期 → 直接返回缓存；
//! 2. `tryLock(100ms)` 自旋 + 每轮重新检查过期（别的线程可能已刷新）；
//!    总预算 3s，超预算返回错误（Java 抛 InterruptedException 包装）；
//! 3. 持锁后再次双重检查，仍过期才真正发请求换新 token；
//! 4. 新 token 按 `expires_in - 200s` 计算过期时刻（提前量防边界）；
//! 5. finally 语义：确实拿到锁才解锁。
//!
//! 与 Java 的差异：Java 直接返回缓存 String 引用（不可变对象安全）；Zig 的缓存是
//! 堆上的 `[]u8`，并发 update 会让旧引用悬垂，因此 `acquire` 把 token 拷贝进
//! 调用方栈缓冲（token 约 200 字节，拷贝成本可忽略），语义上与 Java 等值。
const std = @import("std");
pub const WxError = @import("error.zig").WxError;
pub const WxResult = @import("result.zig").WxResult;
pub const consts = @import("consts.zig");

/// 一次成功的 token 获取结果。`token` 由 fetcher 分配，acquire 在写入槽位后释放。
pub const Fetched = struct {
    token: []const u8,
    expires_in: i64, // 秒（微信返回的 expires_in）
};

pub const FetchOutcome = union(enum) {
    ok: Fetched,
    err: WxError,
};

/// 刷新回调：由各模块实现（GET /cgi-bin/token、POST /cgi-bin/stable_token、
/// 第三方平台 api_authorizer_token 等）。vtable 形式便于运行时多态。
pub const Fetcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fetch: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) FetchOutcome,
    };

    pub fn fetch(self: Fetcher, gpa: std.mem.Allocator, io: std.Io) FetchOutcome {
        return self.vtable.fetch(self.ptr, gpa, io);
    }
};

/// 可控时钟(离线单测注入)：`now_ns` 返回纳秒时间。默认 null = 使用 real clock。
/// `now_ctx` 由注入方持有(如固定时钟或步进计数器)，使「过期判断」可确定性测试。
pub const NowFn = *const fn (ctx: *anyopaque, io: std.Io) i96;

/// 一个带锁的 token 缓存位（access_token / jsapi_ticket / component_access_token…）。
pub const TokenSlot = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    token: ?[]u8 = null,
    /// 过期时刻（纳秒，real clock）。0 = 从未取到 / 已强制失效。
    expires_at_ns: i96 = 0,
    /// 提前过期余量，对应 Java 的 `expiresInSeconds - 200`。
    slack_ns: i96 = consts.TOKEN_EXPIRE_SLACK_SECONDS * std.time.ns_per_s,
    /// 可控时钟(测试注入)。生产保持 null -> real clock。
    now_fn: ?NowFn = null,
    now_ctx: *anyopaque = undefined,

    pub fn init(gpa: std.mem.Allocator) TokenSlot {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TokenSlot) void {
        if (self.token) |t| self.gpa.free(t);
        self.* = undefined;
    }

    fn nowNs(self: *const TokenSlot, io: std.Io) i96 {
        if (self.now_fn) |f| return f(self.now_ctx, io);
        return std.Io.Clock.real.now(io).nanoseconds;
    }

    pub fn isExpired(self: *const TokenSlot, io: std.Io) bool {
        if (self.token == null) return true;
        return self.nowNs(io) > self.expires_at_ns;
    }

    /// 写入新 token（持锁调用）。
    pub fn update(self: *TokenSlot, io: std.Io, token: []const u8, expires_in_seconds: i64) !void {
        const duped = try self.gpa.dupe(u8, token);
        if (self.token) |old| self.gpa.free(old);
        self.token = duped;
        const effective: i64 = expires_in_seconds - consts.TOKEN_EXPIRE_SLACK_SECONDS;
        self.expires_at_ns = self.nowNs(io) + @as(i96, @max(effective, 0)) * std.time.ns_per_s;
    }

    /// 强制失效（对应 `expireAccessToken()`：仅把过期时刻清零）。
    pub fn expire(self: *TokenSlot) void {
        self.expires_at_ns = 0;
    }

    /// 仅当缓存仍是 `expected` 时失效。
    /// 对应 BaseWxMpServiceImpl.executeInternal 里「比对存储中的 token 仍等于
    /// 本次使用的 token 才 expire」的防护（避免误杀别的线程刚刷新的 token）。
    pub fn expireIfUnchanged(self: *TokenSlot, io: std.Io, expected: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const cur = self.token orelse {
            self.expires_at_ns = 0;
            return false;
        };
        if (std.mem.eql(u8, cur, expected)) {
            self.expires_at_ns = 0;
            return true;
        }
        return false;
    }

    /// 借用当前缓存 token（仅在调用方保证无并发 update 时使用；一般请用 acquire）。
    pub fn peek(self: *const TokenSlot) ?[]const u8 {
        return self.token;
    }
};

pub const AcquireOptions = struct {
    poll_ms: u64 = consts.TOKEN_LOCK_POLL_MS,
    budget_ms: u64 = consts.TOKEN_LOCK_BUDGET_MS,
};

/// 完整 token 获取协议。结果拷贝进 `buf`（建议 ≥256 字节）。
pub fn acquire(
    slot: *TokenSlot,
    io: std.Io,
    buf: []u8,
    force_refresh: bool,
    opts: AcquireOptions,
    fetcher: Fetcher,
) WxResult([]const u8) {
    // 1. 快路径
    if (!force_refresh and !slot.isExpired(io)) {
        return copyOut(slot, buf);
    }

    // 2. tryLock 自旋 + 每轮双重检查
    const start = std.Io.Clock.real.now(io).nanoseconds;
    var locked = false;
    while (!locked) {
        if (!force_refresh and !slot.isExpired(io)) return copyOut(slot, buf);
        locked = slot.mutex.tryLock();
        if (!locked) {
            const spent = std.Io.Clock.real.now(io).nanoseconds - start;
            if (spent > @as(i96, @intCast(opts.budget_ms)) * std.time.ns_per_ms) {
                return .{ .err = WxError.internal(slot.gpa, "acquire token lock timeout after {d}ms", .{@divTrunc(spent, @as(i96, std.time.ns_per_ms))}) };
            }
            std.Io.sleep(io, .fromMilliseconds(@intCast(opts.poll_ms)), .real) catch {
                return .{ .err = WxError.transport(slot.gpa, "sleep interrupted", .{}) };
            };
        }
    }

    // 3. 持锁双重检查 + 真正刷新；4/5. 解锁（defer）
    defer slot.mutex.unlock(io);
    if (!force_refresh and !slot.isExpired(io)) return copyOut(slot, buf);

    switch (fetcher.fetch(slot.gpa, io)) {
        .ok => |got| {
            defer slot.gpa.free(got.token); // Fetched.token 所有权在调用方
            slot.update(io, got.token, got.expires_in) catch |e| {
                return .{ .err = WxError.transport(slot.gpa, "token update failed: {s}", .{@errorName(e)}) };
            };
            return copyOut(slot, buf);
        },
        .err => |e| return .{ .err = e },
    }
}

fn copyOut(slot: *TokenSlot, buf: []u8) WxResult([]const u8) {
    const t = slot.token orelse return .{ .err = WxError.internal(slot.gpa, "token unavailable", .{}) };
    if (buf.len < t.len) return .{ .err = WxError.internal(slot.gpa, "token buffer too small", .{}) };
    @memcpy(buf[0..t.len], t);
    return .{ .ok = buf[0..t.len] };
}

// ---------------------------------------------------------------------------

test "token slot expiry with slack" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var slot = TokenSlot.init(std.testing.allocator);
    defer slot.deinit();

    try std.testing.expect(slot.isExpired(io));
    // expires_in=300s，扣除 200s 余量 → 100s 后过期 → 当下仍未过期
    try slot.update(io, "abc", 300);
    try std.testing.expect(!slot.isExpired(io));
    try std.testing.expectEqualStrings("abc", slot.peek().?);

    slot.expire();
    try std.testing.expect(slot.isExpired(io));
}

test "token acquire protocol refreshes once" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const F = struct {
        count: usize = 0,
        fn f(ctx: *anyopaque, gpa: std.mem.Allocator, ioo: std.Io) FetchOutcome {
            _ = ioo;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            const t = gpa.dupe(u8, "tok-1") catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var fctx = F{};
    const fetcher = Fetcher{ .ptr = @ptrCast(&fctx), .vtable = &.{ .fetch = F.f } };

    var slot = TokenSlot.init(std.testing.allocator);
    defer slot.deinit();

    var buf: [256]u8 = undefined;
    const r = acquire(&slot, io, &buf, false, .{}, fetcher);
    switch (r) {
        .ok => |t| try std.testing.expectEqualStrings("tok-1", t),
        .err => |e| std.debug.panic("unexpected err: {s}", .{e.error_msg}),
    }
    try std.testing.expectEqual(@as(usize, 1), fctx.count);

    // 第二次走缓存
    _ = acquire(&slot, io, &buf, false, .{}, fetcher);
    try std.testing.expectEqual(@as(usize, 1), fctx.count);

    // 强制刷新
    _ = acquire(&slot, io, &buf, true, .{}, fetcher);
    try std.testing.expectEqual(@as(usize, 2), fctx.count);
}
