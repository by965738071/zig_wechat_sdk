//! 草稿箱服务 —— 对应 Java `api.WxMpDraftService` + `api.impl.WxMpDraftServiceImpl`,
//! 端点常量取自 `enums.WxMpApiUrl.Draft`。
//!
//! 样板见 `services/user.zig`。逐字对照 Java impl(6 端点;countDraft 为 GET,其余 POST):
//!   addDraft    POST /cgi-bin/draft/add       {"articles":[{title,content,thumb_media_id}]} → media_id
//!   updateDraft POST /cgi-bin/draft/update    {media_id,index,articles:{...}} → errcode==0
//!   getDraft    POST /cgi-bin/draft/get       {"media_id":..} → WxMpDraftInfo{news_item:[...]}
//!   delDraft    POST /cgi-bin/draft/delete    {"media_id":..} → errcode==0
//!   listDraft   POST /cgi-bin/draft/batchget  {"offset","count","no_content"} → WxMpDraftList{total_count,item_count,item[]}
//!   countDraft  GET  /cgi-bin/draft/count     (无 body) → total_count
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 单篇文章 —— 字段名取自 WxMpDraftArticles 的 @SerializedName
/// (title / content / thumb_media_id)。
const Article = struct {
    title: []const u8,
    content: []const u8,
    thumb_media_id: []const u8,
};

/// {"articles":[{...}]} —— 对应 WxMpAddDraft{articles:[WxMpDraftArticles]}
/// (WxMpDraftServiceImpl:34-41 的三参数 addDraft 重载)。
fn addBody(gpa: std.mem.Allocator, title: []const u8, content: []const u8, thumb_media_id: []const u8) ![]u8 {
    const articles = [1]Article{.{ .title = title, .content = content, .thumb_media_id = thumb_media_id }};
    return json_util.stringify(gpa, .{ .articles = articles });
}

/// {"media_id":..,"index":..,"articles":{...}} —— 对应 WxMpUpdateDraft
/// (@SerializedName media_id/index/articles;articles 为单对象而非数组)。
fn updateBody(gpa: std.mem.Allocator, media_id: []const u8, index: i64, title: []const u8, content: []const u8, thumb_media_id: []const u8) ![]u8 {
    const Body = struct {
        media_id: []const u8,
        index: i64,
        articles: Article,
    };
    return json_util.stringify(gpa, Body{
        .media_id = media_id,
        .index = index,
        .articles = .{ .title = title, .content = content, .thumb_media_id = thumb_media_id },
    });
}

fn mediaIdBody(gpa: std.mem.Allocator, media_id: []const u8) ![]u8 {
    return json_util.stringify(gpa, .{ .media_id = media_id });
}

/// {"offset":..,"count":..,"no_content":..} —— 对应 WxMpDraftServiceImpl:70-71
/// `GsonHelper.buildJsonObject("offset", offset, "count", count, "no_content", noContent)`。
fn listBody(gpa: std.mem.Allocator, offset: i64, count: i64, no_content: i64) ![]u8 {
    return json_util.stringify(gpa, .{ .offset = offset, .count = count, .no_content = no_content });
}

pub const DraftService = struct {
    svc: *service_mod.Service,

    /// 对应 `addDraft`:响应取 `media_id`(WxMpDraftServiceImpl:46 `get("media_id")`)。
    pub fn addDraft(self: *DraftService, io: std.Io, title: []const u8, content: []const u8, thumb_media_id: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = addBody(gpa, title, content, thumb_media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.draft_add.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.strField(gpa, resp, "media_id");
    }

    /// 对应 `updateDraft`:成功即 errcode==0(服务层已折叠 errcode!=0 为 .err)。
    pub fn updateDraft(self: *DraftService, io: std.Io, media_id: []const u8, index: i64, title: []const u8, content: []const u8, thumb_media_id: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = updateBody(gpa, media_id, index, title, content, thumb_media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.draft_update.asUri(), body);
    }

    /// 对应 `getDraft`:响应 WxMpDraftInfo 的 @SerializedName("news_item")。
    pub fn getDraft(self: *DraftService, io: std.Io, media_id: []const u8) WxResult(h.NewsInfo) {
        const gpa = self.svc.gpa;
        const body = mediaIdBody(gpa, media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.draft_get.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "draft/get not json", .{}),
        };
        defer parsed.deinit();
        const r = h.parseNewsItem(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = r };
    }

    /// 对应 `delDraft`:POST {"media_id":..},errcode==0 即完成。
    pub fn delDraft(self: *DraftService, io: std.Io, media_id: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = mediaIdBody(gpa, media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.draft_delete.asUri(), body);
    }

    /// 对应 `listDraft(offset,count,noContent)` → WxMpDraftList 的
    /// @SerializedName total_count / item_count / item。
    pub fn listDraft(self: *DraftService, io: std.Io, offset: i64, count: i64, no_content: i64) WxResult(h.ListCounts) {
        const gpa = self.svc.gpa;
        const body = listBody(gpa, offset, count, no_content) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.draft_batchget.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "draft/batchget not json", .{}),
        };
        defer parsed.deinit();
        return .{ .ok = h.parseListCounts(parsed.value) };
    }

    /// 对应 `countDraft()`:**GET**(WxMpDraftServiceImpl:81 `mpService.get`),
    /// 响应取 `total_count`(impl:82)。
    pub fn countDraft(self: *DraftService, io: std.Io) WxResult(i64) {
        const gpa = self.svc.gpa;
        const resp = switch (h.apiGet(self.svc, io, service_mod.ApiUrl.draft_count.asUri())) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.intField(gpa, resp, "total_count");
    }
};

// ---------------------------------------------------------------------------
// 契约测试:6 端点 URL/method/请求体/响应字段
// (逐字对照 WxMpApiUrl.Draft + WxMpDraftServiceImpl + 各 bean 的 @SerializedName)
// ---------------------------------------------------------------------------

test "Draft 契约: 6 端点 URL/method/请求体/响应字段 (WxMpApiUrl.Draft)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/draft/add", .response = "{\"media_id\":\"MEDIA1\"}" },
        .{ .match = "cgi-bin/draft/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/draft/get", .response = "{\"news_item\":[{\"title\":\"文章A\",\"content\":\"正文A\"},{\"title\":\"文章B\"}]}" },
        .{ .match = "cgi-bin/draft/delete", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/draft/batchget", .response = "{\"total_count\":7,\"item_count\":2,\"item\":[{},{}]}" },
        .{ .match = "cgi-bin/draft/count", .response = "{\"total_count\":9}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = DraftService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // ADD_DRAFT: POST {"articles":[{title,content,thumb_media_id}]} → media_id
    switch (svc.addDraft(io, "T", "C", "TH")) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expectEqualStrings("MEDIA1", b);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAddDraft;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/add") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"articles\":[") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"title\":\"T\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"content\":\"C\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"thumb_media_id\":\"TH\"") != null);

    // UPDATE_DRAFT: POST {media_id,index,articles:{...}} → errcode==0
    switch (svc.updateDraft(io, "M1", 0, "T2", "C2", "TH2")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedUpdateDraft;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/update") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"M1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"index\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"articles\":{") != null);

    // GET_DRAFT: POST {"media_id":..} → news_item[] 长度 + 首项 title
    switch (svc.getDraft(io, "M1")) {
        .ok => |*r| {
            var n = r.*;
            defer n.deinit();
            try testing.expectEqual(@as(usize, 2), n.count);
            try testing.expectEqualStrings("文章A", n.first_title);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGetDraft;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"M1\"") != null);

    // DEL_DRAFT: POST {"media_id":..} → errcode==0
    switch (svc.delDraft(io, "M1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDelDraft;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/delete") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"M1\"") != null);

    // LIST_DRAFT: POST {"offset","count","no_content"} → total_count/item_count/item[]
    switch (svc.listDraft(io, 0, 20, 1)) {
        .ok => |r| {
            try testing.expectEqual(@as(i64, 7), r.total_count);
            try testing.expectEqual(@as(i64, 2), r.item_count);
            try testing.expectEqual(@as(usize, 2), r.item_len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedListDraft;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/batchget") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"offset\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"count\":20") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"no_content\":1") != null);

    // COUNT_DRAFT: GET(impl 用 mpService.get) → total_count
    switch (svc.countDraft(io)) {
        .ok => |n| try testing.expectEqual(@as(i64, 9), n),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCountDraft;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/draft/count") != null);
}
