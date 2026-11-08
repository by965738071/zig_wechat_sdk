//! Redis 操作抽象 —— 对应 Java `redis/WxRedisOps` 家族。
//!
//! Java 端用 `WxRedisOps` 把 access_token/ticket 存进 Redis（Jedis /
//! RedisTemplate / Redisson 三种实现），`BaseWxRedisOps` 是一个全方法抛
//! `UnsupportedOperationException` 的骨架基类。
//! Zig 版保留同样的接缝：一个 vtable 接口 + 一个可用于测试/单机的内存实现。
//!
//! 分布式锁:`RedisOps.getLock(key)` 返回 `DistributedLock`。内存参考实现用
//! SETNX+PX 语义模拟(逐字对照 Java `RedisTemplateSimpleDistributedLock`):
//!  - `setIfAbsent(key, value, leaseMs)` 原子「不存在才设值 + 过期」(SETNX + PX);
//!  - 重入:当前值等于本锁 owner 时也算拿到;
//!  - `unlock` 用 compare-and-delete(对应 Java 的 Lua 脚本,只删自己的锁)。
//! 这是**跨进程真 Redis** 的语义参考实现,仅进程内有效;真跨进程需 RESP 客户端
//! (选型见文件末),不硬写半个客户端、不伪造跨进程效果。
const std = @import("std");
pub const DistributedLock = @import("lock.zig").DistributedLock;
const token = @import("token.zig");

pub const Error = std.mem.Allocator.Error || error{RedisUnavailable};

pub const RedisOps = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回 null = key 不存在。结果所有权归调用方。
        get_value: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, key: []const u8) Error!?[]u8,
        /// expire_seconds <= 0 表示不过期。
        set_value: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8, expire_seconds: i64) Error!void,
        get_expire: *const fn (ctx: *anyopaque, io: std.Io, key: []const u8) Error!?i64,
        expire: *const fn (ctx: *anyopaque, io: std.Io, key: []const u8, expire_seconds: i64) Error!void,
        /// 对应 `Lock getLock(String key)`。
        get_lock: *const fn (ctx: *anyopaque, key: []const u8) DistributedLock,
    };

    pub fn getValue(self: RedisOps, gpa: std.mem.Allocator, io: std.Io, key: []const u8) Error!?[]u8 {
        return self.vtable.get_value(self.ptr, gpa, io, key);
    }
    pub fn setValue(self: RedisOps, gpa: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8, expire_seconds: i64) Error!void {
        return self.vtable.set_value(self.ptr, gpa, io, key, value, expire_seconds);
    }
    pub fn getExpire(self: RedisOps, io: std.Io, key: []const u8) Error!?i64 {
        return self.vtable.get_expire(self.ptr, io, key);
    }
    pub fn expire(self: RedisOps, io: std.Io, key: []const u8, expire_seconds: i64) Error!void {
        return self.vtable.expire(self.ptr, io, key, expire_seconds);
    }
    pub fn getLock(self: RedisOps, key: []const u8) DistributedLock {
        return self.vtable.get_lock(self.ptr, key);
    }
};

/// 默认锁租约(毫秒)——对应 Java `RedisTemplateSimpleDistributedLock` 的
/// `leaseMilliseconds`(SETNX + PX 的 PX 部分)。
pub const default_lock_lease_ms: u64 = 30_000;

/// 进程内实现（测试与单机部署可用；对应 Java 的 Jedis / RedisTemplate 版位）。
pub const InMemoryRedis = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMap(Entry),
    /// 可控时钟(离线单测注入 PX 过期);null = real clock,与 token.TokenSlot 同款。
    now_fn: ?token.NowFn = null,
    now_ctx: *anyopaque = undefined,
    /// 锁 owner 计数(为每个 getLock 生成唯一 value,对应 Java 的 UUID ThreadLocal)。
    lock_owner_counter: u64 = 0,
    /// 已分配的锁对象(堆分配、地址稳定),deinit 统一释放。
    lock_handles: std.ArrayList(*RedisLock) = .empty,

    const Entry = struct {
        value: []u8,
        expire_at_ns: i96 = 0, // 0 = 永不过期
    };

    pub fn init(gpa: std.mem.Allocator) InMemoryRedis {
        return .{ .gpa = gpa, .entries = std.StringHashMap(Entry).init(gpa) };
    }

    pub fn deinit(self: *InMemoryRedis) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.value);
        }
        self.entries.deinit();
        for (self.lock_handles.items) |h| {
            self.gpa.free(h.key);
            self.gpa.free(h.owner);
            self.gpa.destroy(h);
        }
        self.lock_handles.deinit(self.gpa);
    }

    fn nowNs(self: *const InMemoryRedis, io: std.Io) i96 {
        if (self.now_fn) |f| return f(self.now_ctx, io);
        return std.Io.Clock.real.now(io).nanoseconds;
    }

    pub fn redis(self: *InMemoryRedis) RedisOps {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// SETNX + PX:仅当 key 不存在或已过期时写入 value 并设置过期;返回是否拿到。
    /// 对应 Java `setIfAbsent(key, value, leaseMs, MILLISECONDS)`,整个判定在锁内原子完成。
    pub fn setIfAbsent(self: *InMemoryRedis, gpa: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8, lease_ms: u64) Error!bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = self.nowNs(io);
        if (self.entries.get(key)) |e| {
            // 已有且未过期 -> 不覆盖(SETNX 失败)
            if (e.expire_at_ns == 0 or now <= e.expire_at_ns) return false;
            // 已过期 -> 先清掉旧值,再当作不存在
            if (self.entries.fetchRemove(key)) |old| {
                self.gpa.free(old.key);
                self.gpa.free(old.value.value);
            }
        }
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        try self.entries.put(k, .{
            .value = v,
            .expire_at_ns = if (lease_ms > 0) now + @as(i96, @intCast(lease_ms)) * std.time.ns_per_ms else 0,
        });
        return true;
    }

    /// compare-and-delete:仅当 key 当前值等于 expected 才删除。
    /// 对应 Java unlock 的 Lua 脚本
    /// `if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end`,
    /// 避免误删别的持有者(或锁过期后被他人重入)的锁。
    pub fn compareAndDelete(self: *InMemoryRedis, io: std.Io, key: []const u8, expected: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.get(key) orelse return false;
        if (!std.mem.eql(u8, e.value, expected)) return false;
        if (self.entries.fetchRemove(key)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value.value);
        }
        return true;
    }

    /// 当前值是否等于 value(重入判定,对应 Java `value.equals(currentValue)`)。
    fn owns(self: *InMemoryRedis, io: std.Io, key: []const u8, value: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.get(key) orelse return false;
        const now = self.nowNs(io);
        if (e.expire_at_ns > 0 and now > e.expire_at_ns) return false;
        return std.mem.eql(u8, e.value, value);
    }

    fn getValueImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, key: []const u8) Error!?[]u8 {
        const self: *InMemoryRedis = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.get(key) orelse return null;
        if (e.expire_at_ns > 0 and self.nowNs(io) > e.expire_at_ns) return null;
        return try gpa.dupe(u8, e.value);
    }

    fn setValueImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8, expire_seconds: i64) Error!void {
        const self: *InMemoryRedis = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.fetchRemove(key)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value.value);
        }
        const now = self.nowNs(io);
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        try self.entries.put(k, .{
            .value = v,
            .expire_at_ns = if (expire_seconds > 0) now + @as(i96, @intCast(expire_seconds)) * std.time.ns_per_s else 0,
        });
    }

    fn getExpireImpl(ctx: *anyopaque, io: std.Io, key: []const u8) Error!?i64 {
        const self: *InMemoryRedis = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.get(key) orelse return null;
        if (e.expire_at_ns == 0) return null;
        const remain_ns = e.expire_at_ns - self.nowNs(io);
        if (remain_ns <= 0) return null;
        return @intCast(@divTrunc(remain_ns, @as(i96, std.time.ns_per_s)));
    }

    fn expireImpl(ctx: *anyopaque, io: std.Io, key: []const u8, expire_seconds: i64) Error!void {
        const self: *InMemoryRedis = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.getPtr(key) orelse return error.RedisUnavailable;
        e.expire_at_ns = self.nowNs(io) + @as(i96, @intCast(expire_seconds)) * std.time.ns_per_s;
    }

    /// 内存参考实现的一把锁:持有 InMemoryRedis 引用 + 锁 key + 唯一 owner value。
    /// owner 是 SETNX 写入的 value,也是 unlock 时 compare-and-delete 的比对依据
    /// (对应 Java `valueThreadLocal` 里的 UUID)。堆分配以保证 DistributedLock.ptr 稳定。
    const RedisLock = struct {
        redis: *InMemoryRedis,
        key: []u8,
        owner: []u8,
        lease_ms: u64 = default_lock_lease_ms,
    };

    fn getLockImpl(ctx: *anyopaque, key: []const u8) DistributedLock {
        const self: *InMemoryRedis = @ptrCast(@alignCast(ctx));
        const gpa = self.gpa;
        // 分配失败时退化为「永远拿不到锁」的占位(诚实,不伪造成功)。
        const h = gpa.create(RedisLock) catch return .{ .ptr = undefined, .vtable = &noop_lock_vtable };
        h.* = .{ .redis = self, .key = &.{}, .owner = &.{} };
        const k = gpa.dupe(u8, key) catch {
            gpa.destroy(h);
            return .{ .ptr = undefined, .vtable = &noop_lock_vtable };
        };
        self.lock_owner_counter +%= 1;
        const owner = std.fmt.allocPrint(gpa, "lock-owner-{d}", .{self.lock_owner_counter}) catch {
            gpa.free(k);
            gpa.destroy(h);
            return .{ .ptr = undefined, .vtable = &noop_lock_vtable };
        };
        self.lock_handles.append(gpa, h) catch {
            gpa.free(k);
            gpa.free(owner);
            gpa.destroy(h);
            return .{ .ptr = undefined, .vtable = &noop_lock_vtable };
        };
        h.key = k;
        h.owner = owner;
        return .{ .ptr = @ptrCast(h), .vtable = &redis_lock_vtable };
    }

    /// try_lock:SETNX+PX,失败且重入(值==owner)也算成功;否则在 timeout_ms 内自旋。
    /// 对应 Java `tryLock(time, unit)` 的 while+sleep 循环。
    fn redisTryLock(ctx: *anyopaque, io: std.Io, timeout_ms: u64) bool {
        const h: *RedisLock = @ptrCast(@alignCast(ctx));
        const r = h.redis;
        const start = r.nowNs(io);
        const budget_ns: i96 = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms;
        while (true) {
            // SETNX + PX
            if (r.setIfAbsent(r.gpa, io, h.key, h.owner, h.lease_ms) catch false) return true;
            // 重入:当前持有者就是自己(Java `value.equals(currentValue)`)
            if (r.owns(io, h.key, h.owner)) return true;
            if (r.nowNs(io) - start >= budget_ns) return false;
            std.Io.sleep(io, .fromMilliseconds(1), .real) catch return false;
        }
    }

    /// lock:阻塞直到拿到(对应 Java `lock()` 的 while(!tryLock) 循环)。
    fn redisLock(ctx: *anyopaque, io: std.Io) void {
        while (!redisTryLock(ctx, io, 100)) {
            std.Io.sleep(io, .fromMilliseconds(1), .real) catch return;
        }
    }

    /// unlock:compare-and-delete(对应 Java Lua 脚本),只删自己的锁。
    fn redisUnlock(ctx: *anyopaque, io: std.Io) void {
        const h: *RedisLock = @ptrCast(@alignCast(ctx));
        _ = h.redis.compareAndDelete(io, h.key, h.owner);
    }

    const redis_lock_vtable = DistributedLock.VTable{
        .try_lock = redisTryLock,
        .lock = redisLock,
        .unlock = redisUnlock,
    };

    // OOM 等失败时的占位:永远拿不到锁,不伪造成功。
    fn noopTryLock(_: *anyopaque, _: std.Io, _: u64) bool {
        return false;
    }
    fn noopLock(_: *anyopaque, _: std.Io) void {}
    fn noopUnlock(_: *anyopaque, _: std.Io) void {}
    const noop_lock_vtable = DistributedLock.VTable{
        .try_lock = noopTryLock,
        .lock = noopLock,
        .unlock = noopUnlock,
    };

    const vtable = RedisOps.VTable{
        .get_value = getValueImpl,
        .set_value = setValueImpl,
        .get_expire = getExpireImpl,
        .expire = expireImpl,
        .get_lock = getLockImpl,
    };
};

test "in-memory redis" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = InMemoryRedis.init(std.testing.allocator);
    defer r.deinit();
    const ops = r.redis();

    try ops.setValue(std.testing.allocator, io, "k", "v", 60);
    const got = (try ops.getValue(std.testing.allocator, io, "k")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("v", got);
}

// ---------------------------------------------------------------------------
// 分布式锁 SETNX+PX 离线单测(对照 Java RedisTemplateSimpleDistributedLock)
// ---------------------------------------------------------------------------

const TestClock = struct {
    now_ns: i96 = 1_700_000_000 * std.time.ns_per_s,
    fn nowFn(c: *anyopaque, io: std.Io) i96 {
        _ = io;
        return @as(*TestClock, @ptrCast(@alignCast(c))).now_ns;
    }
    fn install(self: *TestClock, r: *InMemoryRedis) void {
        r.now_fn = nowFn;
        r.now_ctx = @ptrCast(self);
    }
};

test "setIfAbsent = SETNX+PX: only absent/expired wins, value stored" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = InMemoryRedis.init(std.testing.allocator);
    defer r.deinit();
    var clock = TestClock{};
    clock.install(&r);

    // 首次 SETNX 成功
    try std.testing.expect(try r.setIfAbsent(std.testing.allocator, io, "lock", "owner-A", 1000));
    // 值确实写进了 Redis(锁就是一个 Redis key)
    const v = (try r.redis().getValue(std.testing.allocator, io, "lock")).?;
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("owner-A", v);
    // 未过期时再 SETNX 失败(不覆盖)
    try std.testing.expect(!(try r.setIfAbsent(std.testing.allocator, io, "lock", "owner-B", 1000)));
    // PX 过期后新的 SETNX 成功(可控时钟推进 1001ms)
    clock.now_ns += 1001 * std.time.ns_per_ms;
    try std.testing.expect(try r.setIfAbsent(std.testing.allocator, io, "lock", "owner-B", 1000));
    const v2 = (try r.redis().getValue(std.testing.allocator, io, "lock")).?;
    defer std.testing.allocator.free(v2);
    try std.testing.expectEqualStrings("owner-B", v2);
}

test "getLock: same key mutually exclusive, reentrant, unlock only deletes own" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = InMemoryRedis.init(std.testing.allocator);
    defer r.deinit();
    var clock = TestClock{};
    clock.install(&r);
    const ops = r.redis();

    const a = ops.getLock("resource");
    const a2 = ops.getLock("resource"); // 另一持有者
    const b = ops.getLock("other"); // 不同 key

    // 同一 key:a 拿到,a2 拿不到(SETNX 互斥)
    try std.testing.expect(a.tryLock(io, 0));
    try std.testing.expect(!a2.tryLock(io, 0));
    // 重入:同一把锁再次 tryLock 成功(值 == 自己 owner)
    try std.testing.expect(a.tryLock(io, 0));
    // 不同 key 不受影响
    try std.testing.expect(b.tryLock(io, 0));

    // 非持有者 unlock 不能删别人的锁(compare-and-delete)
    a2.unlock(io);
    try std.testing.expect(!a2.tryLock(io, 0)); // a 仍持有
    // 持有者 unlock 后 a2 才能拿到
    a.unlock(io);
    try std.testing.expect(a2.tryLock(io, 0));
    a2.unlock(io);
    b.unlock(io);
}

test "getLock: PX lease auto-release after expiry (controllable clock)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = InMemoryRedis.init(std.testing.allocator);
    defer r.deinit();
    var clock = TestClock{};
    clock.install(&r);
    const ops = r.redis();

    // 短租约锁
    const a = ops.getLock("lease");
    try std.testing.expect(a.tryLock(io, 0));
    // 直接构造一把已知租约的小锁:用 setIfAbsent 造 5ms 过期的键,再推进时钟
    // 这里改用默认 30s 租约 + 可控时钟推进超过 30s,验证过期后他人可获取
    const other = ops.getLock("lease");
    try std.testing.expect(!other.tryLock(io, 0)); // 未过期,拿不到
    clock.now_ns += (default_lock_lease_ms + 1) * std.time.ns_per_ms;
    try std.testing.expect(other.tryLock(io, 0)); // 过期后可重入获取
    other.unlock(io);
}

// ---------------------------------------------------------------------------
// 选型结论(跨进程真 Redis):
// 本 InMemoryRedis 用 `std.StringHashMap + std.Io.Mutex` 在**单进程内**逼真模拟
// SETNX+PX / compare-and-delete,`RedisOps` vtable 已是接入接缝。跨进程部署需一个
// 真正的 RESP(Redis Serialization Protocol)客户端,推荐顺序:
//   1) 首选纯 Zig、支持 0.18 std.Io 的 RESP 客户端 crate(在 build.zig.zon 声明,
//      按 RedisOps.VTable 包装 get/set/expire/getLock,把 setIfAbsent 映射到
//      `SET key value NX PX leaseMs`、unlock 映射到 compare-and-delete Lua);
//   2) 若无成熟纯 Zig 实现,用 std.Io.net 起一条 TCP + 手写最小 RESP(仅本 SDK 用的
//      5 个命令),仍经同一 vtable 接入 —— 但这已是独立客户端工程,不在本骨架范围;
//   3) 不引入任何半成品客户端、不把单机内存锁冒充分布式锁。
// 本轮按用户「能安全加入且不破坏构建就加,否则做到协议层+接缝+单测并如实标注」,
// 不新增外部 crate(网络依赖无法离线验证、也会给纯离线测试引入不稳定),仅把
// `WxRedisOps` 接口 + 内存参考实现做实并离线单测,选型建议如上。
// ---------------------------------------------------------------------------
