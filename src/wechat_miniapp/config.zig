//! 小程序配置存储 —— 对应 Java `api.WxMaConfig` + `impl.WxMaInMemoryConfig`。
//!
//! 与 mp 的 ConfigStorage 同构(vtable + TokenSlot),差异:
//! - 没有消息回调 token/aes_key 的强需求,但 Java WxMaConfig 同样带
//!   token/aesKey(消息安全模式),这里一并保留;
//! - 支持 stable_token:Java `getAccessToken(forceRefresh, forceCheck)` 走
//!   POST /cgi-bin/stable_token —— 差异只在注入的 Fetcher,协议不变;
//! - 注意 **session_key 不在这里**!session_key 是每个用户(login 时)的凭据,
//!   对应 Java `WxMaJscode2SessionResult`,由业务自己存储。
const std = @import("std");
const token_mod = @import("common").token;
const result_mod = @import("common").result;

pub const WxResult = result_mod.WxResult;

pub const ConfigStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        appid: *const fn (ctx: *anyopaque) []const u8,
        secret: *const fn (ctx: *anyopaque) []const u8,
        token: *const fn (ctx: *anyopaque) []const u8,
        aes_key: *const fn (ctx: *anyopaque) []const u8,
        acquire_access_token: *const fn (ctx: *anyopaque, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8),
        expire_access_token: *const fn (ctx: *anyopaque, io: std.Io, used_token: []const u8) bool,
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
    pub fn expireAccessToken(self: ConfigStorage, io: std.Io, used: []const u8) bool {
        return self.vtable.expire_access_token(self.ptr, io, used);
    }
};

pub const InMemoryConfigStorage = struct {
    gpa: std.mem.Allocator,
    slot: token_mod.TokenSlot,
    fetcher: token_mod.Fetcher,
    appid_: []u8,
    secret_: []u8,
    token_: []u8,
    aes_key_: []u8,

    pub const InitArgs = struct {
        appid: []const u8,
        secret: []const u8,
        token: []const u8 = "",
        aes_key: []const u8 = "",
    };

    pub fn init(gpa: std.mem.Allocator, fetcher: token_mod.Fetcher, args: InitArgs) !InMemoryConfigStorage {
        return .{
            .gpa = gpa,
            .slot = token_mod.TokenSlot.init(gpa),
            .fetcher = fetcher,
            .appid_ = try gpa.dupe(u8, args.appid),
            .secret_ = try gpa.dupe(u8, args.secret),
            .token_ = try gpa.dupe(u8, args.token),
            .aes_key_ = try gpa.dupe(u8, args.aes_key),
        };
    }

    pub fn deinit(self: *InMemoryConfigStorage) void {
        self.gpa.free(self.appid_);
        self.gpa.free(self.secret_);
        self.gpa.free(self.token_);
        self.gpa.free(self.aes_key_);
        self.slot.deinit();
    }

    pub fn config(self: *InMemoryConfigStorage) ConfigStorage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn f(ctx: *anyopaque) *InMemoryConfigStorage {
        return @ptrCast(@alignCast(ctx));
    }
    fn appidImpl(c: *anyopaque) []const u8 {
        return f(c).appid_;
    }
    fn secretImpl(c: *anyopaque) []const u8 {
        return f(c).secret_;
    }
    fn tokenImpl(c: *anyopaque) []const u8 {
        return f(c).token_;
    }
    fn aesKeyImpl(c: *anyopaque) []const u8 {
        return f(c).aes_key_;
    }
    fn acquireImpl(c: *anyopaque, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        return token_mod.acquire(&f(c).slot, io, buf, force, .{}, f(c).fetcher);
    }
    fn expireImpl(c: *anyopaque, io: std.Io, used: []const u8) bool {
        return f(c).slot.expireIfUnchanged(io, used);
    }

    const vtable = ConfigStorage.VTable{
        .appid = appidImpl,
        .secret = secretImpl,
        .token = tokenImpl,
        .aes_key = aesKeyImpl,
        .acquire_access_token = acquireImpl,
        .expire_access_token = expireImpl,
    };
};
