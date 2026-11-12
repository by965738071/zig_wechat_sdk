//! 图文消息留言(评论)管理服务 —— 对应 Java `api.WxMpCommentService` +
//! `api.impl.WxMpCommentServiceImpl`,端点常量取自 `enums.WxMpApiUrl.Comment`。
//!
//! 样板见 `services/user.zig`。逐字对照 Java impl(共 8 个端点,全部 POST):
//!   open        /cgi-bin/comment/open          {"msg_data_id","index"?}
//!   close       /cgi-bin/comment/close         {"msg_data_id","index"?}
//!   list        /cgi-bin/comment/list          {"msg_data_id","begin","count","type","index"?}
//!               → WxMpCommentListVo{total,comment:[{user_comment_id,openid,content,comment_type,...}]}
//!   markElect   /cgi-bin/comment/markelect     {"msg_data_id","user_comment_id","index"?}
//!   unmarkElect /cgi-bin/comment/unmarkelect   {"msg_data_id","user_comment_id","index"?}
//!   delete      /cgi-bin/comment/delete        {"msg_data_id","user_comment_id","index"?}
//!   replyAdd    /cgi-bin/comment/reply/add     {"msg_data_id","user_comment_id","index"?,"content"}
//!   replyDelete /cgi-bin/comment/reply/delete  {"msg_data_id","user_comment_id","index"?}
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// WxMpCommentListVo.WxMpComment 的一条评论 —— @SerializedName 明确的字段:
/// user_comment_id / openid / content / comment_type(此处收录前三者)。全部 gpa 拥有。
pub const CommentItem = struct {
    user_comment_id: i64 = 0,
    openid: []u8,
    content: []u8,

    pub fn deinit(self: *CommentItem, gpa: std.mem.Allocator) void {
        gpa.free(self.openid);
        gpa.free(self.content);
        self.* = undefined;
    }
};

/// WxMpCommentListVo{total,comment:[...]}(顶层 total 为 bean 字段名)。
pub const CommentList = struct {
    gpa: std.mem.Allocator,
    total: i64 = 0,
    items: []CommentItem = &.{},

    pub fn deinit(self: *CommentList) void {
        for (self.items) |*it| it.deinit(self.gpa);
        if (self.items.len > 0) self.gpa.free(self.items);
        self.* = undefined;
    }

    fn itemFromJson(gpa: std.mem.Allocator, v: json_util.Value) !CommentItem {
        const o = try gpa.dupe(u8, json_util.getStrOr(v, "openid", ""));
        errdefer gpa.free(o);
        const c = try gpa.dupe(u8, json_util.getStrOr(v, "content", ""));
        errdefer gpa.free(c);
        return .{
            .user_comment_id = json_util.getIntOr(v, "user_comment_id", 0),
            .openid = o,
            .content = c,
        };
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !CommentList {
        var r = CommentList{ .gpa = gpa };
        errdefer r.deinit();
        r.total = json_util.getIntOr(v, "total", 0);
        var list: std.ArrayList(CommentItem) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit(gpa);
            list.deinit(gpa);
        }
        if (json_util.getArray(v, "comment")) |arr| {
            for (arr.items) |item| try list.append(gpa, try itemFromJson(gpa, item));
        }
        r.items = try list.toOwnedSlice(gpa);
        return r;
    }
};

// ---------------------------------------------------------------------------
// 请求体构造(字段名逐字对照 WxMpCommentServiceImpl 的 addProperty 调用)
// ---------------------------------------------------------------------------

/// {"msg_data_id":..,"index"?:..} —— open / close 共用。
fn ocBody(gpa: std.mem.Allocator, msg_data_id: []const u8, index: ?i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("msg_data_id", msg_data_id);
    if (index) |i| try ob.putInt("index", i);
    return ob.toJson();
}

/// {"msg_data_id":..,"begin":..,"count":..,"type":..,"index"?:..} —— list。
fn listBody(gpa: std.mem.Allocator, msg_data_id: []const u8, index: ?i64, begin: i64, count: i64, typ: i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("msg_data_id", msg_data_id);
    try ob.putInt("begin", begin);
    try ob.putInt("count", count);
    try ob.putInt("type", typ);
    if (index) |i| try ob.putInt("index", i);
    return ob.toJson();
}

/// buildJson(msgDataId,index,userCommentId) [+ "content"] —— markElect/
/// unmarkElect/delete/replyAdd/replyDelete 共用(Java impl:90-98)。
fn actionBody(gpa: std.mem.Allocator, msg_data_id: []const u8, index: ?i64, user_comment_id: i64, content: ?[]const u8) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("msg_data_id", msg_data_id);
    try ob.putInt("user_comment_id", user_comment_id);
    if (index) |i| try ob.putInt("index", i);
    if (content) |c| try ob.putStr("content", c);
    return ob.toJson();
}

pub const CommentService = struct {
    svc: *service_mod.Service,

    fn postDone(self: *CommentService, io: std.Io, which: service_mod.ApiUrl, body: []const u8) Done {
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    pub fn open(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64) Done {
        const gpa = self.svc.gpa;
        const body = ocBody(gpa, msg_data_id, index) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_open, body);
    }

    pub fn close(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64) Done {
        const gpa = self.svc.gpa;
        const body = ocBody(gpa, msg_data_id, index) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_close, body);
    }

    /// 对应 `WxMpCommentServiceImpl#list`:POST → WxMpCommentListVo.fromJson。
    pub fn list(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, begin: i64, count: i64, typ: i64) WxResult(CommentList) {
        const gpa = self.svc.gpa;
        const body = listBody(gpa, msg_data_id, index, begin, count, typ) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, service_mod.ApiUrl.comment_list.asUri(), body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "comment/list not json", .{}),
        };
        defer parsed.deinit();
        const r = CommentList.fromJson(gpa, parsed.value) catch return .{
            .err = result_mod.WxError.transport(gpa, "comment/list parse failed", .{}),
        };
        return .{ .ok = r };
    }

    pub fn markElect(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, user_comment_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = actionBody(gpa, msg_data_id, index, user_comment_id, null) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_mark_elect, body);
    }

    pub fn unmarkElect(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, user_comment_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = actionBody(gpa, msg_data_id, index, user_comment_id, null) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_unmark_elect, body);
    }

    pub fn delete(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, user_comment_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = actionBody(gpa, msg_data_id, index, user_comment_id, null) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_delete, body);
    }

    pub fn replyAdd(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, user_comment_id: i64, content: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = actionBody(gpa, msg_data_id, index, user_comment_id, content) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_reply_add, body);
    }

    pub fn replyDelete(self: *CommentService, io: std.Io, msg_data_id: []const u8, index: ?i64, user_comment_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = actionBody(gpa, msg_data_id, index, user_comment_id, null) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.postDone(io, .comment_reply_delete, body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:8 端点 URL/method/请求体 + list 响应字段
// (逐字对照 WxMpApiUrl.Comment + WxMpCommentServiceImpl + WxMpCommentListVo)
// ---------------------------------------------------------------------------

test "Comment 契约: 8 端点 URL/method/请求体 + list 响应字段 (WxMpApiUrl.Comment)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/comment/open", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/comment/close", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/comment/list", .response = "{\"total\":5,\"comment\":[{\"user_comment_id\":11,\"openid\":\"oA\",\"content\":\"好评\",\"comment_type\":1},{\"user_comment_id\":12,\"openid\":\"oB\",\"content\":\"不错\"}]}" },
        .{ .match = "cgi-bin/comment/markelect", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/comment/unmarkelect", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/comment/delete", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/comment/reply/add", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/comment/reply/delete", .response = "{\"errcode\":0}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = CommentService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // open: 带可选 index(Java impl:24-26)
    switch (svc.open(io, "M1", 2)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCommentOpen;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/open") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"msg_data_id\":\"M1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"index\":2") != null);

    // close: 不带 index —— 请求体不应出现 "index"(Java impl:33-37 可选字段)
    switch (svc.close(io, "M1", null)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCommentClose;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/close") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"index\"") == null);

    // list: 请求体 begin/count/type + 响应 WxMpCommentListVo{total,comment[]}
    switch (svc.list(io, "M1", 0, 0, 10, 1)) {
        .ok => |*r| {
            var l = r.*;
            defer l.deinit();
            try testing.expectEqual(@as(i64, 5), l.total);
            try testing.expectEqual(@as(usize, 2), l.items.len);
            try testing.expectEqual(@as(i64, 11), l.items[0].user_comment_id);
            try testing.expectEqualStrings("oA", l.items[0].openid);
            try testing.expectEqualStrings("好评", l.items[0].content);
            try testing.expectEqual(@as(i64, 12), l.items[1].user_comment_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCommentList;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/list") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"begin\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"count\":10") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":1") != null);

    // markElect / unmarkElect / delete: buildJson 带 user_comment_id
    switch (svc.markElect(io, "M1", null, 11)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMarkElect;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/markelect") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"user_comment_id\":11") != null);

    switch (svc.unmarkElect(io, "M1", null, 11)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedUnmarkElect;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/unmarkelect") != null);

    switch (svc.delete(io, "M1", null, 11)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCommentDelete;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/delete") != null);

    // replyAdd: 额外 content 字段(Java impl:79)
    switch (svc.replyAdd(io, "M1", null, 11, "感谢支持")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedReplyAdd;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/reply/add") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"content\":\"感谢支持\"") != null);

    // replyDelete
    switch (svc.replyDelete(io, "M1", null, 11)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedReplyDelete;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/comment/reply/delete") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"content\"") == null);
}
