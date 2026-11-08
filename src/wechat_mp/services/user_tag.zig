//! 标签服务 —— 对应 Java `api.WxMpUserTagService` + `api.impl.WxMpUserTagServiceImpl`。
//!
//! URL 以 Java 枚举 `enums.WxMpApiUrl.UserTag` 为准:
//! - TAGS_CREATE  → cgi-bin/tags/create
//! - TAGS_GET     → cgi-bin/tags/get
//! - TAGS_UPDATE  → cgi-bin/tags/update
//! - TAGS_DELETE  → cgi-bin/tags/delete
//! - TAG_GET      → cgi-bin/user/tag/get(按标签取用户)
//! - TAGS_MEMBERS_BATCHTAGGING   → cgi-bin/tags/members/batchtagging
//! - TAGS_MEMBERS_BATCHUNTAGGING → cgi-bin/tags/members/batchuntagging
//! - TAGS_GETIDLIST              → cgi-bin/tags/getidlist
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 标签 —— 对应 Java `bean.tag.WxUserTag`(id 可为 null;name 全部 gpa 拥有)。
pub const UserTag = struct {
    gpa: std.mem.Allocator,
    id: ?i64 = null,
    name: []const u8 = "",
    count: ?i64 = null,

    pub fn deinit(self: *UserTag) void {
        self.gpa.free(@constCast(self.name));
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !UserTag {
        var t = UserTag{ .gpa = gpa, .name = try gpa.dupe(u8, json_util.getStrOr(v, "name", "")) };
        errdefer t.deinit();
        t.id = json_util.getInt(v, "id");
        t.count = json_util.getInt(v, "count");
        return t;
    }
};

/// 按标签取用户结果 —— 对应 Java `bean.tag.WxTagListUser`
/// ({count, data.openid[], next_openid};openid 列表与 next 全部 gpa 拥有)。
pub const TagListUser = struct {
    gpa: std.mem.Allocator,
    count: i64 = 0,
    openids: [][]u8 = &.{},
    next_openid: []const u8 = "",

    pub fn deinit(self: *TagListUser) void {
        const g = self.gpa;
        for (self.openids) |o| g.free(o);
        if (self.openids.len > 0) g.free(self.openids);
        g.free(@constCast(self.next_openid));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !TagListUser {
        var r = TagListUser{ .gpa = gpa, .count = json_util.getInt(v, "count") orelse 0 };
        errdefer r.deinit();
        r.next_openid = try gpa.dupe(u8, json_util.getStrOr(v, "next_openid", ""));

        var list: std.ArrayList([]u8) = .empty;
        errdefer for (list.items) |o| gpa.free(o);
        if (json_util.objectOf(v, "data")) |_| {
            // data.openid 是字符串数组
            const data = blk: {
                const o = json_util.object(v) orelse break :blk null;
                const c = o.get("data") orelse break :blk null;
                break :blk json_util.object(c);
            };
            if (data) |d| {
                const oi = d.get("openid") orelse return r;
                if (oi == .array) for (oi.array.items) |s| {
                    if (s == .string) try list.append(gpa, try gpa.dupe(u8, s.string));
                };
            }
        }
        r.openids = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// 拼 api.weixin.qq.com 前缀(uri 交给调用方 free;与 template_msg.zig 同一样板)。
fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiGet(svc: *service_mod.Service, io: std.Io, path: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.get(io, uri, &.{});
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 Service 折叠为 .err)。
fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

/// 手写 JSON 转义写串(与 template_msg.toJson 同法,零容器生命周期风险)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// `{"tag":{"id":N,"name":"..."}}`(id<0 表示不带 id 字段)。
fn tagBodyJson(gpa: std.mem.Allocator, id: i64, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"tag\":{");
    if (id >= 0) try w.print("\"id\":{d},", .{id});
    try w.writeAll("\"name\":");
    try jw.str(w, name);
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

pub const UserTagService = struct {
    svc: *service_mod.Service,

    /// 对应 `tagCreate(name)`:POST cgi-bin/tags/create {"tag":{"name":...}}
    /// → {"tag":{"id":..,"name":..}}。
    pub fn tagCreate(self: *UserTagService, io: std.Io, name: []const u8) WxResult(UserTag) {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, -1, name) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.tagFromResp(io, "cgi-bin/tags/create", body);
    }

    /// 对应 `tagGet()`:GET cgi-bin/tags/get → {"tags":[{id,name},...]}。
    /// 所有权:切片逐元素 deinit;`len != 0` 时由调用方 `free` 切片本身。
    pub fn tagGet(self: *UserTagService, io: std.Io) WxResult([]UserTag) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, "cgi-bin/tags/get")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "tags/get not json", .{}),
        };
        defer parsed.deinit();

        var list: std.ArrayList(UserTag) = .empty;
        errdefer for (list.items) |*t| {
            var tmp = t.*;
            tmp.deinit();
        };
        if (json_util.getArray(parsed.value, "tags")) |arr| {
            for (arr.items) |item| {
                const tag = UserTag.fromJson(gpa, item) catch
                    return .{ .err = result_mod.WxError.transport(gpa, "tags item parse failed", .{}) };
                list.append(gpa, tag) catch
                    return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
            }
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `tagUpdate(tagId, name)`:POST cgi-bin/tags/update,成功即 errcode==0。
    pub fn tagUpdate(self: *UserTagService, io: std.Io, tag_id: i64, name: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, tag_id, name) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, "cgi-bin/tags/update", body);
    }

    /// 对应 `tagDelete(tagId)`:POST cgi-bin/tags/delete {"tag":{"id":N}}。
    pub fn tagDelete(self: *UserTagService, io: std.Io, tag_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, tag_id, "") catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, "cgi-bin/tags/delete", body);
    }

    /// 对应 `tagListUser(tagId, nextOpenid)`:POST cgi-bin/user/tag/get
    /// {"tagid":N,"next_openid":..}(Java 用 trimToEmpty → 空串必填)。
    pub fn tagListUser(self: *UserTagService, io: std.Io, tag_id: i64, next_openid: []const u8) WxResult(TagListUser) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        w.print("{{\"tagid\":{d},\"next_openid\":", .{tag_id}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        jw.str(w, next_openid) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        w.writeByte('}') catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        return self.tagListFromResp(io, "cgi-bin/user/tag/get", body);
    }

    /// 对应 `batchTagging(tagId, openids)`:POST tags/members/batchtagging。
    pub fn batchTagging(self: *UserTagService, io: std.Io, tag_id: i64, openids: []const []const u8) Done {
        return self.batchBody(io, "cgi-bin/tags/members/batchtagging", tag_id, openids);
    }

    /// 对应 `batchUntagging(tagId, openids)`:POST tags/members/batchuntagging。
    pub fn batchUntagging(self: *UserTagService, io: std.Io, tag_id: i64, openids: []const []const u8) Done {
        return self.batchBody(io, "cgi-bin/tags/members/batchuntagging", tag_id, openids);
    }

    /// 对应 `userTagList(openid)`:POST tags/getidlist {"openid":..}
    /// → {"tagid_list":[1,2,..]}。
    /// 所有权:切片由 gpa 分配,调用方 free。
    pub fn userTagList(self: *UserTagService, io: std.Io, openid: []const u8) WxResult([]i64) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"openid\":") catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        jw.str(w, openid) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        w.writeByte('}') catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, "cgi-bin/tags/getidlist", body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "tags/getidlist not json", .{}),
        };
        defer parsed.deinit();

        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(gpa);
        if (json_util.getArray(parsed.value, "tagid_list")) |arr| {
            for (arr.items) |item| switch (item) {
                .integer => |n| list.append(gpa, n) catch
                    return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) },
                else => {},
            };
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
    }

    // ---- 内部 ----

    fn tagFromResp(self: *UserTagService, io: std.Io, path: []const u8, body: []const u8) WxResult(UserTag) {
        const gpa = self.svc.gpa;
        const resp = switch (apiPost(self.svc, io, path, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "tags not json", .{}),
        };
        defer parsed.deinit();
        const tag_v = if (json_util.objectOf(parsed.value, "tag")) |_| blk: {
            const o = json_util.object(parsed.value) orelse break :blk json_util.Value{ .null = {} };
            break :blk o.get("tag").?;
        } else json_util.Value{ .null = {} };
        const t = UserTag.fromJson(gpa, tag_v) catch return .{
            .err = result_mod.WxError.transport(gpa, "tags parse failed", .{}),
        };
        return .{ .ok = t };
    }

    fn tagListFromResp(self: *UserTagService, io: std.Io, path: []const u8, body: []const u8) WxResult(TagListUser) {
        const gpa = self.svc.gpa;
        const resp = switch (apiPost(self.svc, io, path, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "user/tag/get not json", .{}),
        };
        defer parsed.deinit();
        const r = TagListUser.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.transport(gpa, "user/tag/get parse failed", .{}),
        };
        return .{ .ok = r };
    }

    fn batchBody(self: *UserTagService, io: std.Io, path: []const u8, tag_id: i64, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        w.print("{{\"tagid\":{d},\"openid_list\":[", .{tag_id}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        for (openids, 0..) |o, i| {
            if (i != 0) w.writeByte(',') catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
            jw.str(w, o) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, path, body);
    }
};

// ---------------------------------------------------------------------------
// 测试:复用 user.zig 的 stub 样板。
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

test "user_tag service: create/get/update/delete/batch/idlist" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/tags/create", .response = "{\"tag\":{\"id\":102,\"name\":\"标签\"}}" },
        .{ .match = "cgi-bin/tags/getidlist", .response = "{\"tagid_list\":[1,2,3]}" },
        .{ .match = "cgi-bin/tags/get", .response = "{\"tags\":[{\"id\":1,\"name\":\"A\",\"count\":7},{\"id\":2,\"name\":\"B\"}]}" },
        .{ .match = "cgi-bin/tags/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/tags/delete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/user/tag/get", .response = "{\"count\":2,\"data\":{\"openid\":[\"o1\",\"o2\"]},\"next_openid\":\"o2\"}" },
        .{ .match = "batchtagging", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "batchuntagging", .response = "{\"errcode\":45051,\"errmsg\":\"tagid 0 is invalid\"}" },
    });

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var tags = UserTagService{ .svc = &svc };

    // tagCreate
    {
        switch (tags.tagCreate(io, "标签")) {
            .ok => |*t| {
                var tag = t.*;
                defer tag.deinit();
                try testing.expectEqual(@as(?i64, 102), tag.id);
                try testing.expectEqualStrings("标签", tag.name);
            },
            .err => return error.Unexpected,
        }
    }

    // tagGet
    {
        switch (tags.tagGet(io)) {
            .ok => |list| {
                defer if (list.len != 0) gpa.free(list);
                try testing.expectEqual(@as(usize, 2), list.len);
                var t0 = list[0];
                defer t0.deinit();
                try testing.expectEqualStrings("A", t0.name);
                try testing.expectEqual(@as(?i64, 7), t0.count);
                var t1 = list[1];
                defer t1.deinit();
                try testing.expectEqual(@as(usize, 1), t1.name.len); // "B"
            },
            .err => return error.Unexpected,
        }
    }

    // tagUpdate / tagDelete(POST errcode==0 语义)
    switch (tags.tagUpdate(io, 102, "改名")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    switch (tags.tagDelete(io, 102)) {
        .ok => {},
        .err => return error.Unexpected,
    }

    // tagListUser
    switch (tags.tagListUser(io, 102, "oX")) {
        .ok => |*t| {
            var r = t.*;
            defer r.deinit();
            try testing.expectEqual(@as(i64, 2), r.count);
            try testing.expectEqualStrings("o2", r.next_openid);
            try testing.expectEqualStrings("o1", r.openids[0]);
        },
        .err => return error.Unexpected,
    }

    // batchTagging 成功 / batchUntagging 直接抛错
    switch (tags.batchTagging(io, 102, &.{ "o1", "o2" })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    switch (tags.batchUntagging(io, 102, &.{"o3"})) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45051), err.error_code);
        },
    }

    // userTagList
    switch (tags.userTagList(io, "oX")) {
        .ok => |list| {
            defer gpa.free(list);
            try testing.expectEqual(@as(usize, 3), list.len);
            try testing.expectEqual(@as(i64, 3), list[2]);
        },
        .err => return error.Unexpected,
    }
}
