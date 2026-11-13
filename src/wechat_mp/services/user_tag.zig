//! 用户标签服务 —— 逐字对齐 Java `api.WxMpUserTagService`(8 方法)+
//! `api.impl.WxMpUserTagServiceImpl`。方法名沿用 Java 的 camelCase(rule 2),全文件一致。
//!
//! 底座(rule 3):所有 URL 路径来自 `../api_url.zig:UserTag`,经 `api()`(=
//! `api_url.url(Host.api, path)`)拼绝对 URL;移除旧 `service.zig:ApiUrl.*` 与本地
//! `Path` 字符串。本服务全部为「无 query 的 GET/POST」,故不涉及手工 query 组包,
//! 无需 `mp_helpers.buildUrl`;Service.execute* 统一注入 access_token 并折叠 errcode。
//!
//! 与 Java impl 的对应(逐方法见各自 doc):
//!   tagCreate → POST tags/create {"tag":{"name":..}} → WxUserTag.fromJson(取 "tag");
//!   tagGet    → GET  tags/get → WxUserTag.listFromJson(取 "tags");
//!   tagUpdate → POST tags/update {"tag":{"id":N,"name":..}} → errcode==0 即 true;
//!   tagDelete → POST tags/delete {"tag":{"id":N}} → errcode==0 即 true;
//!   tagListUser → POST user/tag/get {"tagid":N,"next_openid":trimToEmpty(..)} → WxTagListUser;
//!   batchTagging/batchUntagging → POST {"tagid":N,"openid_list":[..]} → errcode==0 即 true;
//!   userTagList → POST tags/getidlist {"openid":..} → 取 "tagid_list" → List<Long>。
//!
//! ★ Java 逻辑核对(重要):本仓库 vendored 的 `WxMpUserTagServiceImpl`(142 行,唯一一份)
//!   **没有分片/分块循环** —— `batchTagging`/`batchUntagging` 把整个 openids 数组装进一个
//!   JsonArray,一次 POST 完成(impl :92-108 / :111-127 无 subList/partition/limit)。因此本轮
//!   忠实移植「单次 POST 全量」,不臆造分片。微信接口文档的单次上限(常见 50/100)由服务端
//!   校验,SDK 此处不拦截 —— 作为集成阶段可能的增强点如实登记(见交付报告)。
//!
//! Java↔Zig 差异:`Boolean`/`boolean` 返回值 → `Done`(`.ok`=true、`.err`=抛出 WxError);
//! Java 对 tagUpdate/tagDelete 再次 `WxError.fromJson(...).getErrorCode()==0` 的检查,
//! 在 Zig 由 Service.executeInternal 统一折叠 errcode→`.err` 完成,语义等价。
//!
//! 内存所有权(全部 gpa 拥有):`UserTag` 用 `deinit()`;`[]UserTag`/`[]i64` 裸切片由调用方
//! `gpa.free()`(切片元素 UserTag 需逐元素 deinit);`TagListUser` 用 `deinit()`;`.err` 用
//! `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;
const u_token = @import("common").token;

const api_url = @import("../api_url.zig");
const u_config = @import("../config.zig");
const u_http = @import("../http.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

// 仅复用纯 JSON 助手与离线测试脚手架(Recorder/Fixture)

/// host+path 绝对 URL,路径取自 `api_url.zig:UserTag`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 Service 折叠为 .err)。
fn postVoid(self: *UserTagService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (self.svc.post(io, api(path), &.{}, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

/// 手写 JSON 转义写串(零容器生命周期风险)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

// ---------------------------------------------------------------------------
// 请求体组包(纯逻辑,离线可测;字段形状逐字对照 Java impl 的 JsonObject)
// ---------------------------------------------------------------------------

/// `{"tag":{ ["id":N,] ["name":..] }}` —— id/name 为 null 时省略该键。
/// tagCreate: (null, name);tagUpdate: (id, name);tagDelete: (id, null)。
fn tagBodyJson(gpa: std.mem.Allocator, id: ?i64, name: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"tag\":{");
    var first = true;
    if (id) |n| {
        try w.print("\"id\":{d}", .{n});
        first = false;
    }
    if (name) |s| {
        if (!first) try w.writeByte(',');
        try w.writeAll("\"name\":");
        try jw.str(w, s);
    }
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

/// `{"tagid":N,"next_openid":..}` —— Java `StringUtils.trimToEmpty(nextOpenid)`。
fn tagListUserBody(gpa: std.mem.Allocator, tag_id: i64, next_openid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"tagid\":{d},\"next_openid\":", .{tag_id});
    try jw.str(w, std.mem.trim(u8, next_openid, " \t\r\n"));
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// `{"tagid":N,"openid_list":[..]}` —— Java batchTagging/batchUntagging 的 OpenidArrayJson。
fn batchBody(gpa: std.mem.Allocator, tag_id: i64, openids: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"tagid\":{d},\"openid_list\":[", .{tag_id});
    for (openids, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try jw.str(w, o);
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

/// `{"openid":..}` —— Java userTagList 的 JsonObject。
fn userTagListBody(gpa: std.mem.Allocator, openid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"openid\":");
    try jw.str(w, openid);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 标签 —— 对应 Java `bean.tag.WxUserTag`(id/count 可为 null;name gpa 拥有)。
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
        errdefer {
            for (list.items) |o| gpa.free(o);
            list.deinit(gpa);
        }
        if (json_util.objectOf(v, "data")) |d| {
            if (d.get("openid")) |oi| {
                if (oi == .array) for (oi.array.items) |s| {
                    if (s == .string) try list.append(gpa, try gpa.dupe(u8, s.string));
                };
            }
        }
        r.openids = try list.toOwnedSlice(gpa);
        return r;
    }
};

// ---------------------------------------------------------------------------
// UserTagService —— 对应 Java `WxMpUserTagService`(8 方法) + `WxMpUserTagServiceImpl`
// ---------------------------------------------------------------------------

pub const UserTagService = struct {
    svc: *service_mod.Service,

    /// `WxMpUserTagService.tagCreate(name)` (接口 :46 / impl :32-40)。
    /// POST cgi-bin/tags/create {"tag":{"name":..}} → 解析响应 "tag" → WxUserTag.fromJson。
    pub fn tagCreate(self: *UserTagService, io: std.Io, name: []const u8) WxResult(UserTag) {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, null, name) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.UserTag.tags_create), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "tags not json", .{}),
        };
        defer parsed.deinit();
        const tag_v = if (json_util.objectOf(parsed.value, "tag")) |_| blk: {
            const o = json_util.object(parsed.value) orelse break :blk json_util.Value{ .null = {} };
            break :blk o.get("tag").?;
        } else json_util.Value{ .null = {} };
        const t = UserTag.fromJson(gpa, tag_v) catch return .{
            .err = WxError.transport(gpa, "tags parse failed", .{}),
        };
        return .{ .ok = t };
    }

    /// `WxMpUserTagService.tagGet()` (接口 :68 / impl :43-46)。
    /// GET cgi-bin/tags/get(无 query)→ 解析 "tags" → WxUserTag.listFromJson。
    /// 所有权:[]UserTag 由调用方 free;每个元素用 deinit()。
    pub fn tagGet(self: *UserTagService, io: std.Io) WxResult([]UserTag) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, api(api_url.UserTag.tags_get), &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "tags/get not json", .{}),
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
                    return .{ .err = WxError.transport(gpa, "tags item parse failed", .{}) };
                list.append(gpa, tag) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// `WxMpUserTagService.tagUpdate(tagId, name)` (接口 :93 / impl :49-63)。
    /// POST cgi-bin/tags/update {"tag":{"id":N,"name":..}};errcode==0 即 true。
    pub fn tagUpdate(self: *UserTagService, io: std.Io, tag_id: i64, name: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, tag_id, name) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserTag.tags_update, body);
    }

    /// `WxMpUserTagService.tagDelete(tagId)` (接口 :117 / impl :66-79)。
    /// POST cgi-bin/tags/delete {"tag":{"id":N}}(Java 不带 name);errcode==0 即 true。
    pub fn tagDelete(self: *UserTagService, io: std.Io, tag_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = tagBodyJson(gpa, tag_id, null) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserTag.tags_delete, body);
    }

    /// `WxMpUserTagService.tagListUser(tagId, nextOpenid)` (接口 :142 / impl :82-89)。
    /// POST cgi-bin/user/tag/get {"tagid":N,"next_openid":trimToEmpty(..)} → WxTagListUser。
    pub fn tagListUser(self: *UserTagService, io: std.Io, tag_id: i64, next_openid: []const u8) WxResult(TagListUser) {
        const gpa = self.svc.gpa;
        const body = tagListUserBody(gpa, tag_id, next_openid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.UserTag.tag_get), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "user/tag/get not json", .{}),
        };
        defer parsed.deinit();
        const r = TagListUser.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.transport(gpa, "user/tag/get parse failed", .{}),
        };
        return .{ .ok = r };
    }

    /// `WxMpUserTagService.batchTagging(tagId, openids)` (接口 :167 / impl :92-108)。
    /// POST cgi-bin/tags/members/batchtagging {"tagid":N,"openid_list":[..]}(单次全量,不分片)。
    pub fn batchTagging(self: *UserTagService, io: std.Io, tag_id: i64, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = batchBody(gpa, tag_id, openids) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserTag.tags_members_batchtagging, body);
    }

    /// `WxMpUserTagService.batchUntagging(tagId, openids)` (接口 :192 / impl :111-127)。
    /// POST cgi-bin/tags/members/batchuntagging {"tagid":N,"openid_list":[..]}(单次全量,不分片)。
    pub fn batchUntagging(self: *UserTagService, io: std.Io, tag_id: i64, openids: []const []const u8) Done {
        const gpa = self.svc.gpa;
        const body = batchBody(gpa, tag_id, openids) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.UserTag.tags_members_batchuntagging, body);
    }

    /// `WxMpUserTagService.userTagList(openid)` (接口 :216 / impl :130-140)。
    /// POST cgi-bin/tags/getidlist {"openid":..} → 取 "tagid_list" → List<Long>(gpa 拥有,调用方 free)。
    pub fn userTagList(self: *UserTagService, io: std.Io, openid: []const u8) WxResult([]i64) {
        const gpa = self.svc.gpa;
        const body = userTagListBody(gpa, openid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.UserTag.tags_getidlist), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "tags/getidlist not json", .{}),
        };
        defer parsed.deinit();

        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(gpa);
        if (json_util.getArray(parsed.value, "tagid_list")) |arr| {
            for (arr.items) |item| switch (item) {
                .integer => |n| list.append(gpa, n) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) },
                else => {},
            };
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试
// ---------------------------------------------------------------------------

test "user_tag service: create/get/update/delete/batch/idlist(StubExecutor 端到端)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = u_http.StubExecutor.init(gpa, &.{
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
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) u_token.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try u_config.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var tags = UserTagService{ .svc = &svc };

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
    switch (tags.tagUpdate(io, 102, "改名")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    switch (tags.tagDelete(io, 102)) {
        .ok => {},
        .err => return error.Unexpected,
    }
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
    switch (tags.userTagList(io, "oX")) {
        .ok => |list| {
            defer gpa.free(list);
            try testing.expectEqual(@as(usize, 3), list.len);
            try testing.expectEqual(@as(i64, 3), list[2]);
        },
        .err => return error.Unexpected,
    }
}

// 请求体逐字对齐 Java impl(JsonObject 字段顺序/缺省键)。复用 sub_util.Recorder。
test "user_tag 请求体契约: create/update/delete/listUser/batch/getidlist" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/tags/create", .response = "{\"tag\":{\"id\":1,\"name\":\"n\"}}" },
        .{ .match = "cgi-bin/tags/update", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/tags/delete", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/user/tag/get", .response = "{\"count\":0,\"data\":{\"openid\":[]},\"next_openid\":\"\"}" },
        .{ .match = "batchtagging", .response = "{\"errcode\":0}" },
        .{ .match = "batchuntagging", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/tags/getidlist", .response = "{\"tagid_list\":[]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = UserTagService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // tagCreate: {"tag":{"name":..}} —— 不带 id
    switch (svc.tagCreate(io, "n")) {
        .ok => |*t| {
            var tag = t.*;
            defer tag.deinit();
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"tag\":{\"name\":\"n\"}}") != null);

    // tagUpdate: {"tag":{"id":102,"name":..}} —— id 在前
    switch (svc.tagUpdate(io, 102, "改名")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"tag\":{\"id\":102,\"name\":\"改名\"}}") != null);

    // tagDelete: {"tag":{"id":102}} —— 不带 name(Java impl 只 addProperty("id"))
    switch (svc.tagDelete(io, 102)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "name") == null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"tag\":{\"id\":102}}") != null);

    // tagListUser: next_openid 经 trimToEmpty(首尾空白)
    switch (svc.tagListUser(io, 102, "  oX  ")) {
        .ok => |*r| {
            var t = r.*;
            defer t.deinit();
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"tagid\":102,\"next_openid\":\"oX\"}") != null);

    // batchTagging / batchUntagging: {"tagid":N,"openid_list":[..]}
    const ids = [_][]const u8{ "o1", "o2" };
    switch (svc.batchTagging(io, 102, &ids)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"tagid\":102,\"openid_list\":[\"o1\",\"o2\"]}") != null);
    switch (svc.batchUntagging(io, 102, &ids)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "batchuntagging") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"o1\",\"o2\"]") != null);

    // userTagList: {"openid":..}
    switch (svc.userTagList(io, "oX")) {
        .ok => |list| gpa.free(list),
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"openid\":\"oX\"}") != null);
}

// 核对 Java impl 无分片:大数组仍**单次 POST 全量**(不臆造 subList/partition 循环)。
test "user_tag batchTagging 不分片: 120 个 openid 一次 POST 全量" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "batchtagging", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = UserTagService{ .svc = &fx.svc };

    var ids_buf: [120][]const u8 = undefined;
    for (&ids_buf, 0..) |*s, i| s.* = try std.fmt.allocPrint(gpa, "oid{d}", .{i});
    defer for (ids_buf) |s| gpa.free(s);

    switch (svc.batchTagging(fx.threaded.io(), 7, &ids_buf)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 1), mock.calls); // 单次 POST,无分片
    try testing.expect(std.mem.indexOf(u8, mock.body(), "oid0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "oid119") != null); // 末尾也在同一 body
}
