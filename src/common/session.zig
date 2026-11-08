//! 会话管理 —— 对应 Java `session/` 包（WxSession / WxSessionManager /
//! StandardSession 的 Tomcat 移植）。
//!
//! 用途：按 openid 维持多轮对话上下文（如客服会话状态机）。
//! 骨架保留接口形状 + 一个功能完整的内存实现（属性值为字符串，覆盖常见场景；
//! Java 的 Object 属性可通过 JSON 编码放进来）。
const std = @import("std");

pub const Session = struct {
    id: []u8,
    creation_time_ms: i64,
    last_accessed_ms: i64,
    attributes: std.StringHashMap([]u8), // value 拥有所有权
    invalidated: bool = false,

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        var it = self.attributes.iterator();
        while (it.next()) |kv| {
            gpa.free(@constCast(kv.key_ptr.*)); // key 为手动 dupe，需显式释放
            gpa.free(kv.value_ptr.*);
        }
        self.attributes.deinit();
    }
};

pub const Error = error{ TooManyActiveSessions, SessionNotFound } || std.mem.Allocator.Error;

pub const SessionManager = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    sessions: std.StringHashMap(Session),
    max_active_sessions: usize = 10_000, // 对应 Java maxActiveSessions 配置

    pub fn init(gpa: std.mem.Allocator) SessionManager {
        return .{ .gpa = gpa, .sessions = std.StringHashMap(Session).init(gpa) };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |s| s.deinit(self.gpa);
        self.sessions.deinit();
    }

    /// 获取（必要时创建）会话；后续属性操作均按 id 寻址。
    /// 对应 `getSession(sessionId, create)`。
    pub fn ensureSession(self: *SessionManager, io: std.Io, id: []const u8, create: bool) Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.sessions.getPtr(id)) |s| {
            s.last_accessed_ms = nowMs(io);
            return;
        }
        if (!create) return error.SessionNotFound;
        if (self.sessions.count() >= self.max_active_sessions) return error.TooManyActiveSessions;

        const now = nowMs(io);
        const id_dup = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(id_dup);
        const s = Session{
            .id = id_dup,
            .creation_time_ms = now,
            .last_accessed_ms = now,
            .attributes = std.StringHashMap([]u8).init(self.gpa),
        };
        try self.sessions.put(id_dup, s);
    }

    pub fn setAttribute(self: *SessionManager, io: std.Io, id: []const u8, name: []const u8, value: []const u8) Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var s = self.sessions.getPtr(id) orelse return error.SessionNotFound;
        if (s.invalidated) return error.SessionNotFound;
        if (s.attributes.fetchRemove(name)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        try s.attributes.put(try self.gpa.dupe(u8, name), try self.gpa.dupe(u8, value));
    }

    pub fn getAttribute(self: *SessionManager, io: std.Io, id: []const u8, name: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const s = self.sessions.getPtr(id) orelse return null;
        if (s.invalidated) return null;
        return s.attributes.get(name);
    }

    pub fn invalidate(self: *SessionManager, io: std.Io, id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.sessions.getPtr(id)) |s| s.invalidated = true;
    }

    pub fn count(self: *SessionManager) usize {
        return self.sessions.count();
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, @as(i96, std.time.ns_per_ms)));
}

test "session manager" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.ensureSession(io, "openid-1", true);
    try mgr.setAttribute(io, "openid-1", "step", "waiting_phone");
    try std.testing.expectEqualStrings("waiting_phone", mgr.getAttribute(io, "openid-1", "step").?);
    mgr.invalidate(io, "openid-1");
    try std.testing.expectEqual(@as(?[]const u8, null), mgr.getAttribute(io, "openid-1", "step"));
}
