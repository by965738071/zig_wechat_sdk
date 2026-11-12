//! 发布能力服务 —— 对应 Java `api.WxMpFreePublishService` +
//! `api.impl.WxMpFreePublishServiceImpl`,端点常量取自 `enums.WxMpApiUrl.FreePublish`。
//!
//! 样板见 `services/user.zig`。逐字对照 Java impl(5 个端点,全部 POST):
//!   submit               POST /cgi-bin/freepublish/submit     {"media_id":..} → publish_id
//!   getPushStatus        POST /cgi-bin/freepublish/get         {"publish_id":..} → WxMpFreePublishStatus{publish_status,article_id,...}
//!   deletePush           POST /cgi-bin/freepublish/delete      {"article_id":..,"index":..} → errcode==0
//!   deletePushAllArticle POST /cgi-bin/freepublish/delete      index=0(impl:52-53,删除全部文章)
//!   getArticleFromId     POST /cgi-bin/freepublish/getarticle  {"article_id":..} → WxMpFreePublishInfo{news_item:[...]}
//!   getPublicationRecordsPOST /cgi-bin/freepublish/batchget    {"offset","count","no_content"} → WxMpFreePublishList
//!
//! 注:Java 接口 javadoc 把 getPublicationRecords 的 URL 误写成 `/cgi-bin/draft/batchget`,
//! 但 impl 用的是枚举常量 `FreePublish.BATCH_GET` = `/cgi-bin/freepublish/batchget`;
//! 本实现以枚举/impl 为准(不以注释为准)。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

fn mediaIdBody(gpa: std.mem.Allocator, media_id: []const u8) ![]u8 {
    return json_util.stringify(gpa, .{ .media_id = media_id });
}
fn publishIdBody(gpa: std.mem.Allocator, publish_id: []const u8) ![]u8 {
    return json_util.stringify(gpa, .{ .publish_id = publish_id });
}
fn articleIdBody(gpa: std.mem.Allocator, article_id: []const u8) ![]u8 {
    return json_util.stringify(gpa, .{ .article_id = article_id });
}
/// {"article_id":..,"index":..} —— 对应 impl:46 `buildJsonObject(ARTICLE_ID, articleId, "index", index)`。
fn deleteBody(gpa: std.mem.Allocator, article_id: []const u8, index: i64) ![]u8 {
    return json_util.stringify(gpa, .{ .article_id = article_id, .index = index });
}
fn listBody(gpa: std.mem.Allocator, offset: i64, count: i64, no_content: i64) ![]u8 {
    return json_util.stringify(gpa, .{ .offset = offset, .count = count, .no_content = no_content });
}

/// WxMpFreePublishStatus —— bean 字段(无 @SerializedName,字段名即 JSON 名):
/// publish_status / article_id。全部 gpa 拥有,用毕 deinit。
pub const PublishStatus = struct {
    gpa: std.mem.Allocator,
    publish_status: i64 = 0,
    article_id: []u8,

    pub fn deinit(self: *PublishStatus) void {
        self.gpa.free(self.article_id);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !PublishStatus {
        return .{
            .gpa = gpa,
            .publish_status = json_util.getIntOr(v, "publish_status", 0),
            .article_id = try gpa.dupe(u8, json_util.getStrOr(v, "article_id", "")),
        };
    }
};

pub const FreePublishService = struct {
    svc: *service_mod.Service,

    /// 对应 `submit(mediaId)`:响应取 `publish_id`(impl:34 `get(PUBLISH_ID)`)。
    pub fn submit(self: *FreePublishService, io: std.Io, media_id: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = mediaIdBody(gpa, media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.freepublish_submit.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.strField(gpa, resp, "publish_id");
    }

    /// 对应 `getPushStatus(publishId)`:POST {"publish_id":..} → WxMpFreePublishStatus。
    pub fn getPushStatus(self: *FreePublishService, io: std.Io, publish_id: []const u8) WxResult(PublishStatus) {
        const gpa = self.svc.gpa;
        const body = publishIdBody(gpa, publish_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.freepublish_get.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "freepublish/get not json", .{}),
        };
        defer parsed.deinit();
        const r = PublishStatus.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = r };
    }

    /// 对应 `deletePush(articleId, index)`:POST {"article_id":..,"index":..} → errcode==0。
    pub fn deletePush(self: *FreePublishService, io: std.Io, article_id: []const u8, index: i64) Done {
        const gpa = self.svc.gpa;
        const body = deleteBody(gpa, article_id, index) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.freepublish_delete.asUri(), body);
    }

    /// 对应 `deletePushAllArticle(articleId)`:impl:52-53 直接 `deletePush(articleId, 0)`。
    pub fn deletePushAllArticle(self: *FreePublishService, io: std.Io, article_id: []const u8) Done {
        return self.deletePush(io, article_id, 0);
    }

    /// 对应 `getArticleFromId(articleId)`:响应 WxMpFreePublishInfo 的
    /// @SerializedName("news_item")。
    pub fn getArticleFromId(self: *FreePublishService, io: std.Io, article_id: []const u8) WxResult(h.NewsInfo) {
        const gpa = self.svc.gpa;
        const body = articleIdBody(gpa, article_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.freepublish_getarticle.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "freepublish/getarticle not json", .{}),
        };
        defer parsed.deinit();
        const r = h.parseNewsItem(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = r };
    }

    /// 对应 `getPublicationRecords(offset,count,noContent)` → WxMpFreePublishList 的
    /// @SerializedName total_count / item_count / item。
    pub fn getPublicationRecords(self: *FreePublishService, io: std.Io, offset: i64, count: i64, no_content: i64) WxResult(h.ListCounts) {
        const gpa = self.svc.gpa;
        const body = listBody(gpa, offset, count, no_content) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.freepublish_batchget.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "freepublish/batchget not json", .{}),
        };
        defer parsed.deinit();
        return .{ .ok = h.parseListCounts(parsed.value) };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:5 端点(+ deletePushAllArticle 别名)URL/method/请求体/响应字段
// (逐字对照 WxMpApiUrl.FreePublish + WxMpFreePublishServiceImpl + 各 bean 字段)
// ---------------------------------------------------------------------------

test "FreePublish 契约: 5 端点+别名 URL/method/请求体/响应字段 (WxMpApiUrl.FreePublish)" {
    const gpa = testing.allocator;
    // 用带 '?' 的 match 区分 `/get`(状态轮询) 与 `/getarticle`,以及 batchget。
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "freepublish/submit?", .response = "{\"publish_id\":\"PUB1\",\"publish_status\":0}" },
        .{ .match = "freepublish/getarticle?", .response = "{\"news_item\":[{\"title\":\"已发布文章A\"},{\"title\":\"已发布文章B\"}]}" },
        .{ .match = "freepublish/get?", .response = "{\"publish_id\":\"PUB1\",\"publish_status\":1,\"article_id\":\"ART1\"}" },
        .{ .match = "freepublish/delete?", .response = "{\"errcode\":0}" },
        .{ .match = "freepublish/batchget?", .response = "{\"total_count\":4,\"item_count\":2,\"item\":[{},{}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = FreePublishService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // SUBMIT: POST {"media_id":..} → publish_id
    switch (svc.submit(io, "M1")) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expectEqualStrings("PUB1", b);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedSubmit;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/freepublish/submit") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"M1\"") != null);

    // GET_PUSH_STATUS: POST {"publish_id":..} → publish_status / article_id
    switch (svc.getPushStatus(io, "PUB1")) {
        .ok => |*r| {
            var s = r.*;
            defer s.deinit();
            try testing.expectEqual(@as(i64, 1), s.publish_status);
            try testing.expectEqualStrings("ART1", s.article_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGetPushStatus;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/freepublish/get?") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"publish_id\":\"PUB1\"") != null);

    // DEL_PUSH: POST {"article_id":..,"index":..} → errcode==0
    switch (svc.deletePush(io, "ART1", 2)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeletePush;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/freepublish/delete") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"article_id\":\"ART1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"index\":2") != null);

    // deletePushAllArticle 别名:impl 固定 index=0
    switch (svc.deletePushAllArticle(io, "ART2")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeletePushAll;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"index\":0") != null);

    // GET_ARTICLE: POST {"article_id":..} → news_item[] 长度 + 首项 title
    switch (svc.getArticleFromId(io, "ART1")) {
        .ok => |*r| {
            var n = r.*;
            defer n.deinit();
            try testing.expectEqual(@as(usize, 2), n.count);
            try testing.expectEqualStrings("已发布文章A", n.first_title);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGetArticle;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/freepublish/getarticle") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"article_id\":\"ART1\"") != null);

    // BATCH_GET: POST {"offset","count","no_content"} → total_count/item_count/item[]
    switch (svc.getPublicationRecords(io, 0, 20, 1)) {
        .ok => |r| {
            try testing.expectEqual(@as(i64, 4), r.total_count);
            try testing.expectEqual(@as(i64, 2), r.item_count);
            try testing.expectEqual(@as(usize, 2), r.item_len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedPublicationRecords;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/freepublish/batchget") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"offset\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"count\":20") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"no_content\":1") != null);
}
