//! 重复消息检查 —— 对应 Java `api/WxMessageDuplicateChecker` 家族。
//!
//! 微信服务器 5 秒无响应会重发（最多 3 次），回调端必须排重。
//! Java 提供内存版（后台线程 5s 清理，TTL 15s）与 Redis 版（TTL 10s）。
//! Zig 版：接口 + 内存实现（惰性清理，免后台线程）。
const std = @import("std");

pub const Checker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// true = 重复消息，应丢弃。
        is_duplicate: *const fn (ctx: *anyopaque, io: std.Io, message_id: []const u8) bool,
    };

    pub fn isDuplicate(self: Checker, io: std.Io, message_id: []const u8) bool {
        return self.vtable.is_duplicate(self.ptr, io, message_id);
    }
};

/// 内存排重器（对应 `WxMessageInMemoryDuplicateChecker`）。
/// TTL 默认 15s；每次检查时惰性清理过期项。
pub const InMemoryChecker = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    seen: std.StringHashMap(i96),
    ttl_ns: i96 = 15 * std.time.ns_per_s,

    pub fn init(gpa: std.mem.Allocator) InMemoryChecker {
        return .{ .gpa = gpa, .seen = std.StringHashMap(i96).init(gpa) };
    }

    pub fn deinit(self: *InMemoryChecker) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.gpa.free(@constCast(k.*));
        self.seen.deinit();
    }

    pub fn checker(self: *InMemoryChecker) Checker {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn isDuplicateImpl(ctx: *anyopaque, io: std.Io, message_id: []const u8) bool {
        const self: *InMemoryChecker = @ptrCast(@alignCast(ctx));
        const now = std.Io.Clock.real.now(io).nanoseconds;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // 惰性清理（对应 Java 守护线程的周期清理）：先收集过期键，避免边遍历边删
        var expired = std.ArrayList([]const u8).empty;
        defer expired.deinit(self.gpa);
        var it = self.seen.iterator();
        while (it.next()) |kv| {
            if (now - kv.value_ptr.* > self.ttl_ns) {
                expired.append(self.gpa, kv.key_ptr.*) catch {};
            }
        }
        for (expired.items) |k| {
            if (self.seen.fetchRemove(k)) |removed| self.gpa.free(@constCast(removed.key));
        }

        if (self.seen.contains(message_id)) return true;
        const k = self.gpa.dupe(u8, message_id) catch return false;
        self.seen.put(k, now) catch {
            self.gpa.free(k);
            return false;
        };
        return false;
    }

    const vtable = Checker.VTable{ .is_duplicate = isDuplicateImpl };
};

/// 普通消息用 MsgId；事件消息用 FromUserName+CreateTime（对应 Router 的取键逻辑）。
pub fn messageKey(buf: []u8, msg_id: ?[]const u8, from_user: ?[]const u8, create_time: ?[]const u8) []const u8 {
    if (msg_id) |m| return m;
    const f = from_user orelse "";
    const c = create_time orelse "";
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ f, c }) catch "";
}

test "in-memory duplicate checker" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var c = InMemoryChecker.init(std.testing.allocator);
    defer c.deinit();
    const ch = c.checker();
    try std.testing.expect(!ch.isDuplicate(io, "msg-1"));
    try std.testing.expect(ch.isDuplicate(io, "msg-1"));
    try std.testing.expect(!ch.isDuplicate(io, "msg-2"));
}
