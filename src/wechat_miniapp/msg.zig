//! 消息服务 —— 对应 Java `api.WxMaMsgService` + `api.impl.WxMaMsgServiceImpl`。
//!
//! 发送订阅消息/统一消息的面在 `subscribe_msg.zig` / `uniform_msg.zig`
//! (Java `sendSubscribeMsg`/`sendUniformMsg` 已分别实现,勿重复);
//! 本文件补齐其余三面:
//! - sendKefuMsg:POST /cgi-bin/message/custom/send(KefuMessage 标签联合体,
//!   序列化对齐 Gson 默认策略:touser + msgtype(取标签名)+ 载荷内联);
//! - createUpdatableMessageActivityId:GET /cgi-bin/message/wxopen/activityid/create;
//! - setUpdatableMsg:POST /cgi-bin/message/wxopen/updatablemsg/send。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const KEFU_MESSAGE_SEND_URL = "https://api.weixin.qq.com/cgi-bin/message/custom/send";
const ACTIVITY_ID_CREATE_URL = "https://api.weixin.qq.com/cgi-bin/message/wxopen/activityid/create";
const UPDATABLE_MSG_SEND_URL = "https://api.weixin.qq.com/cgi-bin/message/wxopen/updatablemsg/send";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn jsInt(w: *std.Io.Writer, v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try w.writeAll(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxMaKefuMessage` 的载荷变体(text/image/link/miniprogrampage/aimsgcontext)。
pub const KefuPayload = union(enum) {
    text: struct { content: []const u8 },
    image: struct { media_id: []const u8 },
    link: struct { title: []const u8, description: []const u8, url: []const u8, thumb_url: []const u8 },
    miniprogrampage: struct { title: []const u8, pagepath: []const u8, thumb_media_id: []const u8 },
    aimsgcontext: struct { msgid: []const u8 },
};

/// 对应 `WxMaKefuMessage`(touser + msgtype + 内联载荷;borrowed,to_json)。
pub const KefuMessage = struct {
    touser: []const u8,
    payload: KefuPayload,

    /// 对应 Gson 默认序列化:msgtype 取载荷标签名,载荷字段内联在顶层。
    pub fn to_json(self: KefuMessage, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"touser\":");
        try js(w, self.touser);
        try w.writeAll(",\"msgtype\":");
        try js(w, @tagName(self.payload));
        switch (self.payload) {
            .text => |p| {
                try w.writeAll(",\"text\":{\"content\":");
                try js(w, p.content);
                try w.writeAll("}");
            },
            .image => |p| {
                try w.writeAll(",\"image\":{\"media_id\":");
                try js(w, p.media_id);
                try w.writeAll("}");
            },
            .link => |p| {
                try w.writeAll(",\"link\":{\"title\":");
                try js(w, p.title);
                try w.writeAll(",\"description\":");
                try js(w, p.description);
                try w.writeAll(",\"url\":");
                try js(w, p.url);
                try w.writeAll(",\"thumb_url\":");
                try js(w, p.thumb_url);
                try w.writeAll("}");
            },
            .miniprogrampage => |p| {
                try w.writeAll(",\"miniprogrampage\":{\"title\":");
                try js(w, p.title);
                try w.writeAll(",\"pagepath\":");
                try js(w, p.pagepath);
                try w.writeAll(",\"thumb_media_id\":");
                try js(w, p.thumb_media_id);
                try w.writeAll("}");
            },
            .aimsgcontext => |p| {
                try w.writeAll(",\"aimsgcontext\":{\"msgid\":");
                try js(w, p.msgid);
                try w.writeAll("}");
            },
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `createUpdatableMessageActivityId` 响应(activity_id/expiration_time)。gpa 拥有。
pub const ActivityId = struct {
    gpa: std.mem.Allocator,
    activity_id: ?[]const u8,
    expiration_time: ?[]const u8,

    pub fn deinit(self: *ActivityId) void {
        const g = self.gpa;
        if (self.activity_id) |s| g.free(@constCast(s));
        if (self.expiration_time) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const ActivityId) void {
        const g = self.gpa;
        if (self.activity_id) |s| g.free(s);
        if (self.expiration_time) |s| g.free(s);
    }
};

/// 对应 `WxMaUpdatableMsg.TemplateInfo.Parameter`(name/value)。
pub const UpdatableMsgParam = struct { name: []const u8, value: []const u8 };

/// 对应 `WxMaUpdatableMsg`(activity_id/target_state/template_info.parameter_list)。
pub const UpdatableMsg = struct {
    activity_id: []const u8,
    target_state: i64,
    parameter_list: []const UpdatableMsgParam = &.{},

    pub fn to_json(self: UpdatableMsg, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"activity_id\":");
        try js(w, self.activity_id);
        try w.writeAll(",\"target_state\":");
        try jsInt(w, self.target_state);
        try w.writeAll(",\"template_info\":{\"parameter_list\":[");
        for (self.parameter_list, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try js(w, p.name);
            try w.writeAll(",\"value\":");
            try js(w, p.value);
            try w.writeAll("}");
        }
        try w.writeAll("]}}");
        return out.toOwnedSlice();
    }
};

// --- service -------------------------------------------------------------------

pub const MsgService = struct {
    svc: *mp_service.Service,

    /// 对应 `sendKefuMsg(WxMaKefuMessage)`:POST /cgi-bin/message/custom/send。
    pub fn sendKefuMsg(self: *MsgService, io: std.Io, msg: KefuMessage) Done {
        const gpa = self.svc.gpa;
        const body = msg.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, KEFU_MESSAGE_SEND_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `createUpdatableMessageActivityId()`:
    /// GET /cgi-bin/message/wxopen/activityid/create(Java 返回原始 JsonObject,
    /// 此处解析为 activity_id/expiration_time)。
    pub fn createUpdatableMessageActivityId(self: *MsgService, io: std.Io) WxResult(ActivityId) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, ACTIVITY_ID_CREATE_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "activityid/create not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .activity_id = if (json_util.getStr(parsed.value, "activity_id")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
            .expiration_time = if (json_util.getStr(parsed.value, "expiration_time")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
        } };
    }

    /// 对应 `setUpdatableMsg(WxMaUpdatableMsg)`:
    /// POST /cgi-bin/message/wxopen/updatablemsg/send。
    pub fn setUpdatableMsg(self: *MsgService, io: std.Io, msg: UpdatableMsg) Done {
        const gpa = self.svc.gpa;
        const body = msg.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATABLE_MSG_SEND_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "msg sendKefuMsg: tagged-union payload serialization" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "message/custom/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = MsgService{ .svc = &base };

    // text
    try std.testing.expect(!s.sendKefuMsg(io, .{ .touser = "oX", .payload = .{ .text = .{ .content = "hi" } } }).failed());
    try std.testing.expectEqualStrings("{\"touser\":\"oX\",\"msgtype\":\"text\",\"text\":{\"content\":\"hi\"}}", m.last_body);

    // image
    try std.testing.expect(!s.sendKefuMsg(io, .{ .touser = "oX", .payload = .{ .image = .{ .media_id = "M1" } } }).failed());
    try std.testing.expectEqualStrings("{\"touser\":\"oX\",\"msgtype\":\"image\",\"image\":{\"media_id\":\"M1\"}}", m.last_body);

    // link
    try std.testing.expect(!s.sendKefuMsg(io, .{ .touser = "oX", .payload = .{ .link = .{
        .title = "t",
        .description = "d",
        .url = "https://u",
        .thumb_url = "https://thumb",
    } } }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"msgtype\":\"link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"thumb_url\":\"https://thumb\"") != null);

    // miniprogrampage
    try std.testing.expect(!s.sendKefuMsg(io, .{ .touser = "oX", .payload = .{ .miniprogrampage = .{
        .title = "t",
        .pagepath = "pages/index/index",
        .thumb_media_id = "T1",
    } } }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"msgtype\":\"miniprogrampage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"pagepath\":\"pages/index/index\"") != null);

    // aimsgcontext
    try std.testing.expect(!s.sendKefuMsg(io, .{ .touser = "oX", .payload = .{ .aimsgcontext = .{ .msgid = "MSG1" } } }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"aimsgcontext\":{\"msgid\":\"MSG1\"}") != null);
}

test "msg activityid create + setUpdatableMsg" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "activityid/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"activity_id\":\"ACT1\",\"expiration_time\":\"2026-01-01 00:00:00\"}" },
        .{ .match = "updatablemsg/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = MsgService{ .svc = &base };

    // create:GET,响应解析 activity_id/expiration_time
    const r = switch (s.createUpdatableMessageActivityId(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var act = r;
    defer act.deinit();
    try std.testing.expectEqualStrings("ACT1", act.activity_id.?);
    try std.testing.expectEqualStrings("2026-01-01 00:00:00", act.expiration_time.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "activityid/create") != null);

    // setUpdatableMsg:template_info.parameter_list 嵌套结构
    try std.testing.expect(!s.setUpdatableMsg(io, .{
        .activity_id = "ACT1",
        .target_state = 0,
        .parameter_list = &.{
            .{ .name = "member_count", .value = "1" },
            .{ .name = "name", .value = "群名" },
        },
    }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"target_state\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"template_info\":{\"parameter_list\":[{\"name\":\"member_count\",\"value\":\"1\"},{\"name\":\"name\",\"value\":\"群名\"}]}") != null);
}
