//! 直播成员角色服务 —— 对应 Java `api.WxMaLiveMemberService` +
//! `api.impl.WxMaLiveMemberServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Broadcast.Role`:
//! - addRole:POST /wxaapi/broadcast/role/addrole {username,role};
//! - deleteRole:POST .../deleterole {username,role};
//! - listByRole:GET .../getrolelist?role=&offset=&limit=&keyword=
//!   → 提取 `list` 数组原样返回(gpa 拥有的 JSON 数组文本,
//!   对应 Java 返回 JsonArray)。
//!   注:Java 的 HashMap+Joiner 会把 null keyword 拼成 "keyword=null",
//!   属 Java 瑕疵;此处 null 字段省略,与语义一致。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const ADD_ROLE_URL = "https://api.weixin.qq.com/wxaapi/broadcast/role/addrole";
const DELETE_ROLE_URL = "https://api.weixin.qq.com/wxaapi/broadcast/role/deleterole";
const LIST_BY_ROLE_URL = "https://api.weixin.qq.com/wxaapi/broadcast/role/getrolelist";

// --- service -------------------------------------------------------------------

pub const LiveMemberService = struct {
    svc: *mp_service.Service,

    /// 对应 `addRole(username, role)`:POST addrole {username,role},
    /// 响应原样返回(gpa 拥有,调用方 free;Java 返回原始 String)。
    pub fn addRole(self: *LiveMemberService, io: std.Io, username: []const u8, role: i64) WxResult([]u8) {
        return self.rolePost(io, ADD_ROLE_URL, username, role);
    }

    /// 对应 `deleteRole(username, role)`:POST deleterole {username,role},
    /// 响应原样返回(同上)。
    pub fn deleteRole(self: *LiveMemberService, io: std.Io, username: []const u8, role: i64) WxResult([]u8) {
        return self.rolePost(io, DELETE_ROLE_URL, username, role);
    }

    /// 对应 `listByRole(role, offset, limit, keyword)`:GET getrolelist
    /// (null 参数省略)→ 提取 `list` 数组,原样返回其 JSON 文本
    /// (gpa 拥有,调用方 free;对应 Java 返回 JsonArray.toString 的内容体)。
    pub fn listByRole(self: *LiveMemberService, io: std.Io, role: ?i64, offset: ?i64, limit: ?i64, keyword: ?[]const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        // i64 → 十进制文本(栈上缓冲,仅在构建 query 期间存活)
        var role_buf: [24]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        var limit_buf: [24]u8 = undefined;
        var queries: [4]mp_service.Query = undefined;
        var n: usize = 0;
        if (role) |v| {
            queries[n] = .{ .key = "role", .value = std.fmt.bufPrint(&role_buf, "{d}", .{v}) catch "" };
            n += 1;
        }
        if (offset) |v| {
            queries[n] = .{ .key = "offset", .value = std.fmt.bufPrint(&offset_buf, "{d}", .{v}) catch "" };
            n += 1;
        }
        if (limit) |v| {
            queries[n] = .{ .key = "limit", .value = std.fmt.bufPrint(&limit_buf, "{d}", .{v}) catch "" };
            n += 1;
        }
        if (keyword) |v| queries[n] = .{ .key = "keyword", .value = v };
        const query = queries[0 .. n + @intFromBool(keyword != null)];

        const resp = switch (self.svc.get(io, LIST_BY_ROLE_URL, query)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "role list not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "list") orelse
            return .{ .err = WxError.transport(gpa, "role list missing `list`", .{}) };
        // getArray 返回裸 ArrayList 载荷,须包回 Value 联合再序列化。
        const out = json_util.stringify(gpa, json_util.Value{ .array = arr }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    // 内部:addrole/deleterole 共用(POST {username,role},响应原样返回)。
    fn rolePost(self: *LiveMemberService, io: std.Io, url: []const u8, username: []const u8, role: i64) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"username\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
        sj.write(username) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print(",\"role\":{d}}}", .{role}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, url, &.{}, body);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "live member addRole/deleteRole/listByRole" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "addrole", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "deleterole", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "getrolelist", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"list\":[{\"username\":\"anchor1\",\"role\":1}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveMemberService{ .svc = &base };

    // addRole:POST {username,role}
    const added = switch (s.addRole(io, "anchor1", 1)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(added);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "role/addrole") != null);
    try std.testing.expectEqualStrings("{\"username\":\"anchor1\",\"role\":1}", m.last_body);

    // deleteRole:POST {username,role}
    const deleted = switch (s.deleteRole(io, "anchor1", 1)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(deleted);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "role/deleterole") != null);
    try std.testing.expectEqualStrings("{\"username\":\"anchor1\",\"role\":1}", m.last_body);

    // listByRole:GET → list 数组文本
    const list = switch (s.listByRole(io, 1, 0, 10, "key")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "role/getrolelist?role=1&offset=0&limit=10&keyword=key") != null);
    const reparsed = try std.json.parseFromSlice(std.json.Value, gpa, list, .{});
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), reparsed.value.array.items.len);
    try std.testing.expectEqualStrings("anchor1", reparsed.value.array.items[0].object.get("username").?.string);
}

test "live member listByRole: null params omitted" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getrolelist", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"list\":[]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveMemberService{ .svc = &base };

    const list = switch (s.listByRole(io, null, null, null, null)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(list);
    // 全 null:query 只有 access_token
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getrolelist?access_token=TOK") != null);
    try std.testing.expectEqualStrings("[]", list);
}
