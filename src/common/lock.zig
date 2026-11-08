//! 锁原语 —— 对应 Java `java.util.concurrent.locks.Lock` 与 `util/locks/*`。
//!
//! Java 端 ConfigStorage 用 `ReentrantLock` 做 token 刷新锁，另提供
//! `JedisDistributedLock` 等分布式锁。Zig 端统一为：
//! - `Lock`：`std.Io.Mutex` 的薄封装（骨架的进程内锁，对应 ReentrantLock 的角色）；
//! - `DistributedLock`：运行时多态接口（vtable），对应 Java 的 `Lock` 接口抽象，
//!   便于接入 Redis 等跨进程实现（`JedisDistributedLock` 在 Java 中已 @Deprecated，
//!   这里保留同构接口即可）。
const std = @import("std");

pub const Mutex = std.Io.Mutex;

/// 进程内互斥锁句柄（对应 Java `ReentrantLock` 在 ConfigStorage 中的用法）。
pub const InProcessLock = struct {
    mutex: Mutex = .init,

    pub fn tryLock(self: *InProcessLock) bool {
        return self.mutex.tryLock();
    }

    pub fn lock(self: *InProcessLock, io: std.Io) std.Io.Cancelable!void {
        try self.mutex.lock(io);
    }

    pub fn unlock(self: *InProcessLock, io: std.Io) void {
        self.mutex.unlock(io);
    }
};

/// 分布式锁接口（vtable 多态；对应 Java `java.util.concurrent.locks.Lock` 接口位）。
pub const DistributedLock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 在 timeout_ms 内尝试拿锁。
        try_lock: *const fn (ctx: *anyopaque, io: std.Io, timeout_ms: u64) bool,
        lock: *const fn (ctx: *anyopaque, io: std.Io) void,
        unlock: *const fn (ctx: *anyopaque, io: std.Io) void,
    };

    pub fn tryLock(self: DistributedLock, io: std.Io, timeout_ms: u64) bool {
        return self.vtable.try_lock(self.ptr, io, timeout_ms);
    }

    pub fn lock(self: DistributedLock, io: std.Io) void {
        self.vtable.lock(self.ptr, io);
    }

    pub fn unlock(self: DistributedLock, io: std.Io) void {
        self.vtable.unlock(self.ptr, io);
    }
};

/// 进程内注册表实现的「假分布式锁」：用于单机多协程/多线程场景与测试。
/// 语义对齐 Java `WxRedisOps.getLock(key)` 与
/// `WxOpenInMemoryConfigStorage.getLockByKey(key)`(`computeIfAbsent(key, ReentrantLock)`):
/// **同一 key 共用一把锁,不同 key 互不阻塞**;真实跨进程部署请换 Redis
/// (SETNX+PX) 实现 —— 见 redis_ops 的 TODO,本文件只负责内存版。
pub const LockRegistry = struct {
    gpa: std.mem.Allocator,
    /// 只保护 `locks` 这个 map 的结构查找/插入;key 之间的互斥由各自 KeyLock 负责。
    map_mutex: Mutex = .init,
    /// key(registry 拥有的副本) → 独立、地址稳定的 KeyLock。
    /// KeyLock 必须堆分配:StringHashMap 扩容会搬动 value,而 DistributedLock.ptr
    /// 要一直有效,不能指向 map 内部存储。
    locks: std.StringHashMap(*KeyLock),

    /// 一把锁 = 一个互斥量 + 持有标记(对应 Java `ReentrantLock` / `JedisLock(key)`)。
    const KeyLock = struct {
        mutex: Mutex = .init,
        held: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) LockRegistry {
        return .{
            .gpa = gpa,
            .locks = std.StringHashMap(*KeyLock).init(gpa),
        };
    }

    /// 释放全部 key 及其锁。返回给调用方的 DistributedLock 在此之后失效
    /// (与 Java 关闭连接池后不得再用锁同理);与 Java 的 `locks` map 一样不做逐键淘汰。
    pub fn deinit(self: *LockRegistry) void {
        var it = self.locks.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.destroy(kv.value_ptr.*);
        }
        self.locks.deinit();
    }

    /// 对应 `WxRedisOps.getLock(key)` / `getLockByKey(key)`:按 key 惰性取锁。
    /// 同一 key 返回同一把锁;仅可能在首次创建(内存分配)时报错。
    pub fn get(self: *LockRegistry, io: std.Io, key: []const u8) !DistributedLock {
        self.map_mutex.lockUncancelable(io);
        defer self.map_mutex.unlock(io);

        if (self.locks.get(key)) |kl| {
            return .{ .ptr = @ptrCast(kl), .vtable = &vtable };
        }
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const kl = try self.gpa.create(KeyLock);
        kl.* = .{};
        errdefer self.gpa.destroy(kl);
        try self.locks.put(owned_key, kl);
        return .{ .ptr = @ptrCast(kl), .vtable = &vtable };
    }

    fn tryLockImpl(ctx: *anyopaque, io: std.Io, timeout_ms: u64) bool {
        _ = timeout_ms;
        const kl: *KeyLock = @ptrCast(@alignCast(ctx));
        kl.mutex.lockUncancelable(io);
        defer kl.mutex.unlock(io);
        if (kl.held) return false;
        kl.held = true;
        return true;
    }

    fn lockImpl(ctx: *anyopaque, io: std.Io) void {
        while (!tryLockImpl(ctx, io, 100)) {
            std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
        }
    }

    fn unlockImpl(ctx: *anyopaque, io: std.Io) void {
        const kl: *KeyLock = @ptrCast(@alignCast(ctx));
        kl.mutex.lockUncancelable(io);
        defer kl.mutex.unlock(io);
        kl.held = false;
    }

    const vtable = DistributedLock.VTable{
        .try_lock = tryLockImpl,
        .lock = lockImpl,
        .unlock = unlockImpl,
    };
};

// ---------------------------------------------------------------------------

test "lock registry: same key exclusive, different keys independent" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = LockRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const a1 = try reg.get(io, "appid:A");
    const a2 = try reg.get(io, "appid:A");
    const b = try reg.get(io, "appid:B");

    // 同一 key:第一次拿到,第二次拿不到(不是退化成全局单锁)。
    try std.testing.expect(a1.tryLock(io, 0));
    try std.testing.expect(!a2.tryLock(io, 0));
    // 不同 key:B 不受 A 影响。
    try std.testing.expect(b.tryLock(io, 0));

    a1.unlock(io);
    try std.testing.expect(a2.tryLock(io, 0)); // 解锁后同一 key 可再拿
    a2.unlock(io);
    b.unlock(io);
}

test "lock registry: key identity survives map growth + cleanup" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reg = LockRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const first = try reg.get(io, "stable-key");
    // 插入足够多的其它 key 触发 StringHashMap 扩容,first.ptr 仍须有效且互斥。
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var buf: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "key-{d}", .{i}) catch unreachable;
        _ = try reg.get(io, k);
    }
    const later = try reg.get(io, "stable-key");
    try std.testing.expect(first.tryLock(io, 0));
    try std.testing.expect(!later.tryLock(io, 0)); // 同一 key 仍是同一把锁
    first.unlock(io);
    // deinit 由 std.testing.allocator 兜底:若 key/KeyLock 泄漏则测试失败。
}
