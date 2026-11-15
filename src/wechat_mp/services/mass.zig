//! 群发消息服务 —— 对应 Java `api.WxMpMassMessageService` +
//! `api.impl.WxMpMassMessageServiceImpl`。
//!
//! URL 以 Java `enums.WxMpApiUrl.MassMessage` 常量为准;请求体形状对齐
//! `util.json.WxMpMass*GsonAdapter` 系列序列化器。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// URL 常量表 —— 对应 Java `WxMpApiUrl.MassMessage`。
pub const Path = struct {
    /// `MESSAGE_MASS_SENDALL_URL`:按标签/全体群发。
    pub const sendall = "cgi-bin/message/mass/sendall";
    /// `MESSAGE_MASS_SEND_URL`:按 openid 列表发送(模拟群发)。
    pub const send = "cgi-bin/message/mass/send";
    /// `MESSAGE_MASS_PREVIEW_URL`:预览。
    pub const preview = "cgi-bin/message/mass/preview";
    /// `MESSAGE_MASS_DELETE_URL`:删除群发。
    pub const delete_msg = "cgi-bin/message/mass/delete";
    /// `MESSAGE_MASS_GET_URL`:查询群发发送状态(`messageMassGet`)。
    pub const get = "cgi-bin/message/mass/get";
    /// `MEDIA_UPLOAD_NEWS_URL`:群发图文素材上传(`massNewsUpload`)。
    pub const upload_news = "cgi-bin/media/uploadnews";
    /// `MEDIA_UPLOAD_VIDEO_URL`:群发视频素材上传(`massVideoUpload`)。
    pub const upload_video = "cgi-bin/media/uploadvideo";
    /// `MESSAGE_MASS_SPEED_GET_URL`:获取群发速度(`messageMassSpeedGet`)。
    pub const speed_get = "cgi-bin/message/mass/speed/get";
    /// `MESSAGE_MASS_SPEED_SET_URL`:设置群发速度(`messageMassSpeedSet`)。
    pub const speed_set = "cgi-bin/message/mass/speed/set";
};

/// 群发消息载荷 —— tag 名即 msgtype(对齐 Java `WxConsts.MassMsgType`,
/// 图文为 `mpnews`,载荷为已上传永久素材的 media_id)。
pub const MassContent = union(enum) {
    /// 文本,载荷为 content。
    text: []const u8,
    /// 图文(永久 material),载荷为 media_id。
    mpnews: []const u8,
    /// 图片,载荷为 media_id。
    image: []const u8,
    /// 语音,载荷为 media_id。
    voice: []const u8,
    /// 视频,载荷为 media_id。
    mpvideo: []const u8,

    /// msgtype 字符串(tag 名与微信协议一致)。
    pub fn msgType(self: MassContent) []const u8 {
        return @tagName(self);
    }
};

/// 发送结果 —— 对应 `bean.result.WxMpMassSendResult`
/// (errcode/errmsg 已由 `Service.executeInternal` 折叠,这里只留 msg_id/msg_data_id)。
/// 所有权:两字符串由 gpa 复制,用毕 `deinit`。
pub const MassSendResult = struct {
    gpa: std.mem.Allocator,
    msg_id: []const u8 = "",
    msg_data_id: []const u8 = "",

    pub fn deinit(self: *MassSendResult) void {
        const g = self.gpa;
        if (self.msg_id.len != 0) g.free(@constCast(self.msg_id));
        if (self.msg_data_id.len != 0) g.free(@constCast(self.msg_data_id));
    }

    /// msgid 可能是数字或字符串(Java 全用 String 承接),统一转字符串。
    fn numOrStrDupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        if (json_util.getStr(v, key)) |s| return try gpa.dupe(u8, s);
        if (json_util.getInt(v, key)) |n| return try std.fmt.allocPrint(gpa, "{d}", .{n});
        return null;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !MassSendResult {
        var r = MassSendResult{ .gpa = gpa };
        errdefer r.deinit();
        r.msg_id = (try numOrStrDupe(gpa, v, "msg_id")) orelse "";
        r.msg_data_id = (try numOrStrDupe(gpa, v, "msg_data_id")) orelse "";
        return r;
    }
};

/// 素材上传结果 —— 对应 `bean.result.WxMpMassUploadResult`,解析键取自
/// `util.json.WxMpMassUploadResultAdapter`(type/media_id/created_at 逐字)。
/// 所有权:两字符串由 gpa 复制,用毕 `deinit`。
pub const MassUploadResult = struct {
    gpa: std.mem.Allocator,
    type: []const u8 = "",
    media_id: []const u8 = "",
    created_at: i64 = 0,

    pub fn deinit(self: *MassUploadResult) void {
        const g = self.gpa;
        if (self.type.len != 0) g.free(@constCast(self.type));
        if (self.media_id.len != 0) g.free(@constCast(self.media_id));
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !MassUploadResult {
        var r = MassUploadResult{ .gpa = gpa };
        errdefer r.deinit();
        r.type = if (json_util.getStr(v, "type")) |s| try gpa.dupe(u8, s) else "";
        r.media_id = if (json_util.getStr(v, "media_id")) |s| try gpa.dupe(u8, s) else "";
        r.created_at = json_util.getInt(v, "created_at") orelse 0;
        return r;
    }
};

/// 群发速度 —— 对应 `bean.result.WxMpMassSpeedGetResult`(speed/realspeed,
/// Java Integer;缺失按 0 承接)。
pub const SpeedGetResult = struct {
    speed: i64 = 0,
    realspeed: i64 = 0,
};

/// 群发状态 —— 对应 `bean.result.WxMpMassGetResult`(msg_id/msg_status,
/// @SerializedName 逐字)。所有权:msg_status 由 gpa 复制,用毕 `deinit`。
pub const MassGetResult = struct {
    gpa: std.mem.Allocator,
    msg_id: i64 = 0,
    msg_status: []const u8 = "",

    pub fn deinit(self: *MassGetResult) void {
        const g = self.gpa;
        if (self.msg_status.len != 0) g.free(@constCast(self.msg_status));
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !MassGetResult {
        var r = MassGetResult{ .gpa = gpa };
        errdefer r.deinit();
        r.msg_id = json_util.getInt(v, "msg_id") orelse 0;
        r.msg_status = if (json_util.getStr(v, "msg_status")) |s| try gpa.dupe(u8, s) else "";
        return r;
    }
};

/// 手写 JSON 转义写串(与 `user_tag.zig` 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// 写 `"<msgtype>":{...},"msgtype":"<msgtype>"` 中段 —— 对齐
/// `WxMpMassTagMessageGsonAdapter`:text 用 {content},其余用 {media_id}。
fn writeContent(w: *std.Io.Writer, c: MassContent) std.Io.Writer.Error!void {
    switch (c) {
        .text => |content| {
            try w.writeAll("\"text\":{\"content\":");
            try jw.str(w, content);
            try w.writeAll("},\"msgtype\":\"text\"");
        },
        // 其余类型载荷都是 media_id;msgtype 名用 c.msgType()(0.18 的 else
        // 捕获拿不到 tag,故逐 tag 列出)。
        .mpnews, .image, .voice, .mpvideo => |media_id| {
            const name = c.msgType();
            try w.writeByte('"');
            try w.writeAll(name);
            try w.writeAll("\":{\"media_id\":");
            try jw.str(w, media_id);
            try w.writeAll("},\"msgtype\":\"");
            try w.writeAll(name);
            try w.writeByte('"');
        },
    }
}

/// sendall 请求体 —— 对齐 `WxMpMassTagMessageGsonAdapter`:
/// `{"filter":{"is_to_all":bool[,tag_id]},<type>:{..},"msgtype":..,
/// "send_ignore_reprint":0|1[,"clientmsgid":..]}`。
/// tag_id 为 null 即全体群发(is_to_all=true,不带 tag_id,对应 Java setSendAll)。
fn sendallBody(gpa: std.mem.Allocator, tag_id: ?i64, c: MassContent, send_ignore_reprint: bool, client_msg_id: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"filter\":{\"is_to_all\":");
    if (tag_id) |tid| {
        try w.writeAll("false,\"tag_id\":");
        try w.print("{d}", .{tid});
        try w.writeAll("},");
    } else {
        try w.writeAll("true},");
    }
    try writeContent(w, c);
    try w.writeAll(",\"send_ignore_reprint\":");
    try w.writeAll(if (send_ignore_reprint) "1" else "0");
    if (client_msg_id) |cid| {
        try w.writeAll(",\"clientmsgid\":");
        try jw.str(w, cid);
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// openid 列表请求体 —— 对齐 `WxMpMassOpenIdsMessageGsonAdapter`:
/// `{"touser":[openid..],<type>:{..},"msgtype":..}`(该适配器不带
/// send_ignore_reprint/clientmsgid,Java 源码里被注释掉了)。
fn openidsBody(gpa: std.mem.Allocator, touser: []const []const u8, c: MassContent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"touser\":[");
    for (touser, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try jw.str(w, o);
    }
    try w.writeAll("],");
    try writeContent(w, c);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// 预览请求体 —— 对齐 `WxMpMassPreviewMessageGsonAdapter`:
/// `{"towxname":..,"touser":..,<type>:{..},"msgtype":..}`(两收件人字段
/// 取其一即可,Gson 的 null 字段这里直接省略)。
fn previewBody(gpa: std.mem.Allocator, touser: ?[]const u8, towxname: ?[]const u8, c: MassContent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeByte('{');
    if (towxname) |n| {
        try w.writeAll("\"towxname\":");
        try jw.str(w, n);
        try w.writeByte(',');
    }
    if (touser) |o| {
        try w.writeAll("\"touser\":");
        try jw.str(w, o);
        try w.writeByte(',');
    }
    try writeContent(w, c);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// 群发图文文章 —— 对应 `bean.material.WxMpNewsArticle`,序列化逐字对齐
/// `util.json.WxMpNewsArticleGsonAdapter`:thumb_media_id/thumb_url/title/content
/// 恒发(thumb_url 为 null 时发 JSON null,同 adapter 的 addProperty 语义);
/// author/content_source_url/digest/url/need_open_comment/only_fans_can_comment
/// 为 null 时省略;show_cover_pic 恒发且为**字符串** "1"/"0"。
pub const NewsArticle = struct {
    thumb_media_id: []const u8,
    thumb_url: ?[]const u8 = null,
    title: []const u8,
    content: []const u8,
    author: ?[]const u8 = null,
    content_source_url: ?[]const u8 = null,
    digest: ?[]const u8 = null,
    show_cover_pic: bool = false,
    url: ?[]const u8 = null,
    need_open_comment: ?bool = null,
    only_fans_can_comment: ?bool = null,
};

/// 单篇文章 → JSON(字段序与 WxMpNewsArticleGsonAdapter.serialize 一致)。
fn writeArticle(w: *std.Io.Writer, a: NewsArticle) std.Io.Writer.Error!void {
    try w.writeAll("{\"thumb_media_id\":");
    try jw.str(w, a.thumb_media_id);
    try w.writeAll(",\"thumb_url\":");
    if (a.thumb_url) |u| {
        try jw.str(w, u);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"title\":");
    try jw.str(w, a.title);
    try w.writeAll(",\"content\":");
    try jw.str(w, a.content);
    if (a.author) |v| {
        try w.writeAll(",\"author\":");
        try jw.str(w, v);
    }
    if (a.content_source_url) |v| {
        try w.writeAll(",\"content_source_url\":");
        try jw.str(w, v);
    }
    if (a.digest) |v| {
        try w.writeAll(",\"digest\":");
        try jw.str(w, v);
    }
    try w.writeAll(",\"show_cover_pic\":");
    try w.writeAll(if (a.show_cover_pic) "\"1\"" else "\"0\"");
    if (a.url) |v| {
        try w.writeAll(",\"url\":");
        try jw.str(w, v);
    }
    if (a.need_open_comment) |b| {
        try w.print(",\"need_open_comment\":{d}", .{@as(i64, if (b) 1 else 0)});
    }
    if (a.only_fans_can_comment) |b| {
        try w.print(",\"only_fans_can_comment\":{d}", .{@as(i64, if (b) 1 else 0)});
    }
    try w.writeByte('}');
}

/// massNewsUpload 请求体 —— 对齐 `WxMpMassNewsGsonAdapter`:
/// `{"articles":[<WxMpNewsArticle>...]}`。
fn newsBody(gpa: std.mem.Allocator, articles: []const NewsArticle) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"articles\":[");
    for (articles, 0..) |a, i| {
        if (i != 0) try w.writeByte(',');
        try writeArticle(w, a);
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

/// massVideoUpload 请求体 —— 对齐 `WxMpMassVideoAdapter`:
/// `{"media_id":..,"description":..,"title":..}`(字段序同 adapter)。
fn videoBody(gpa: std.mem.Allocator, media_id: []const u8, title: []const u8, description: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"media_id\":");
    try jw.str(w, media_id);
    try w.writeAll(",\"description\":");
    try jw.str(w, description);
    try w.writeAll(",\"title\":");
    try jw.str(w, title);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig 同构)
// ---------------------------------------------------------------------------

fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

/// POST 并解析 `MassSendResult`(sendall/send/preview 三接口共用)。
fn postForResult(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult(MassSendResult) {
    const gpa = svc.gpa;
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    defer gpa.free(resp);
    const parsed = json_util.parse(gpa, resp) catch return .{
        .err = result_mod.WxError.transport(gpa, "mass response not json", .{}),
    };
    defer parsed.deinit();
    const res = MassSendResult.fromJson(gpa, parsed.value) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
    return .{ .ok = res };
}

pub const MassService = struct {
    svc: *service_mod.Service,

    /// 对应 `WxMpMassMessageServiceImpl#massGroupMessageSend`(`isSendAll=false` 分支):
    /// POST cgi-bin/message/mass/sendall,filter={is_to_all:false,tag_id}。
    pub fn sendAllByTag(self: *MassService, io: std.Io, tag_id: i64, content: MassContent, send_ignore_reprint: bool, client_msg_id: ?[]const u8) WxResult(MassSendResult) {
        const gpa = self.svc.gpa;
        const body = sendallBody(gpa, tag_id, content, send_ignore_reprint, client_msg_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build sendall body", .{}) };
        defer gpa.free(body);
        return postForResult(self.svc, io, Path.sendall, body);
    }

    /// 对应 `massGroupMessageSend`(`setSendAll(true)` 分支):
    /// filter={is_to_all:true},不带 tag_id。
    pub fn sendAll(self: *MassService, io: std.Io, content: MassContent, send_ignore_reprint: bool, client_msg_id: ?[]const u8) WxResult(MassSendResult) {
        const gpa = self.svc.gpa;
        const body = sendallBody(gpa, null, content, send_ignore_reprint, client_msg_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build sendall body", .{}) };
        defer gpa.free(body);
        return postForResult(self.svc, io, Path.sendall, body);
    }

    /// 对应 `WxMpMassMessageServiceImpl#massOpenIdsMessageSend`:
    /// POST cgi-bin/message/mass/send {touser:[openid,...],...}(最多 10000 个)。
    pub fn sendToOpenids(self: *MassService, io: std.Io, touser: []const []const u8, content: MassContent) WxResult(MassSendResult) {
        const gpa = self.svc.gpa;
        const body = openidsBody(gpa, touser, content) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build mass send body", .{}) };
        defer gpa.free(body);
        return postForResult(self.svc, io, Path.send, body);
    }

    /// 对应 `WxMpMassMessageServiceImpl#massMessagePreview`:
    /// POST cgi-bin/message/mass/preview;touser(openid)与 towxname(微信号)取其一。
    pub fn preview(self: *MassService, io: std.Io, touser: ?[]const u8, towxname: ?[]const u8, content: MassContent) WxResult(MassSendResult) {
        const gpa = self.svc.gpa;
        const body = previewBody(gpa, touser, towxname, content) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build mass preview body", .{}) };
        defer gpa.free(body);
        return postForResult(self.svc, io, Path.preview, body);
    }

    /// 对应 `WxMpMassMessageServiceImpl#delete(msgId, articleIndex)`:
    /// POST cgi-bin/message/mass/delete {msg_id, article_idx}
    /// (Java 键名就是 `msg_id`/`article_idx`,非任务单存疑的 `msgmedi_id`)。
    pub fn delete(self: *MassService, io: std.Io, msg_id: i64, article_idx: i64) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putInt("msg_id", msg_id) catch break :build null;
            ob.putInt("article_idx", article_idx) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build mass delete body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.delete_msg, body);
    }

    /// 扩展方法(Java 无对应;Java 的 messageMassGet 见 massGet):
    /// POST cgi-bin/message/mass/get {msg_id} → 群发进度 `current_rate`
    /// (官方响应形如 {"is_progress_exist":1,"progress":{"current_rate":100}},
    /// 顶层/嵌套两种位置都兼容取值;缺失时按宽松语义返回 0)。
    pub fn getUploadRate(self: *MassService, io: std.Io, msg_id: i64) WxResult(i64) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putInt("msg_id", msg_id) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build mass get body", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, Path.get, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "mass get not json", .{}),
        };
        defer parsed.deinit();
        if (json_util.getInt(parsed.value, "current_rate")) |r| return .{ .ok = r };
        if (json_util.objectOf(parsed.value, "progress")) |p| {
            const v: json_util.Value = .{ .object = p };
            if (json_util.getInt(v, "current_rate")) |r| return .{ .ok = r };
        }
        return .{ .ok = 0 };
    }

    /// 对应 `massNewsUpload(WxMpMassNews)`(impl:36-39):
    /// POST cgi-bin/media/uploadnews,body 由 WxMpMassNewsGsonAdapter 序列化
    /// `{"articles":[...]}`,文章字段序见 NewsArticle。
    pub fn newsUpload(self: *MassService, io: std.Io, articles: []const NewsArticle) WxResult(MassUploadResult) {
        const gpa = self.svc.gpa;
        const body = newsBody(gpa, articles) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build mass uploadnews body", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, Path.upload_news, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "mass uploadnews not json", .{}),
        };
        defer parsed.deinit();
        const r = MassUploadResult.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `massVideoUpload(WxMpMassVideo)`(impl:41-44):
    /// POST cgi-bin/media/uploadvideo,body 见 videoBody(WxMpMassVideoAdapter)。
    pub fn videoUpload(self: *MassService, io: std.Io, media_id: []const u8, title: []const u8, description: []const u8) WxResult(MassUploadResult) {
        const gpa = self.svc.gpa;
        const body = videoBody(gpa, media_id, title, description) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build mass uploadvideo body", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, Path.upload_video, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "mass uploadvideo not json", .{}),
        };
        defer parsed.deinit();
        const r = MassUploadResult.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `messageMassSpeedGet()`(impl:70-76):建空 JsonObject 后 POST
    /// speed/get(即 body "{}")→ WxMpMassSpeedGetResult{speed,realspeed}。
    pub fn speedGet(self: *MassService, io: std.Io) WxResult(SpeedGetResult) {
        const gpa = self.svc.gpa;
        const resp = switch (apiPost(self.svc, io, Path.speed_get, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "mass speed get not json", .{}),
        };
        defer parsed.deinit();
        return .{ .ok = .{
            .speed = json_util.getInt(parsed.value, "speed") orelse 0,
            .realspeed = json_util.getInt(parsed.value, "realspeed") orelse 0,
        } };
    }

    /// 对应 `messageMassSpeedSet(speed)`(impl:78-83):
    /// POST speed/set,body `{"speed":N}`。
    pub fn speedSet(self: *MassService, io: std.Io, speed: i64) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putInt("speed", speed) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build mass speed set body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.speed_set, body);
    }

    /// 对应 `messageMassGet(msgId)`(impl:95-102):POST mass/get `{"msg_id":N}`
    /// → WxMpMassGetResult{msg_id,msg_status}。
    pub fn massGet(self: *MassService, io: std.Io, msg_id: i64) WxResult(MassGetResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putInt("msg_id", msg_id) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build mass get body", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, Path.get, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "mass get not json", .{}),
        };
        defer parsed.deinit();
        const r = MassGetResult.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = r };
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 `template_msg.zig` 的 Recorder 方式)。
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

const Recorder = struct {
    const Entry = struct { match: []const u8, response: []const u8 };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    fn uri(self: *const Recorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const Recorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }

    fn executor(self: *Recorder) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = @tagName(method);
        self.last_uri_len = @min(target.len, self.last_uri.len);
        @memcpy(self.last_uri[0..self.last_uri_len], target[0..self.last_uri_len]);
        const b = payload orelse "";
        self.last_body_len = @min(b.len, self.last_body.len);
        @memcpy(self.last_body[0..self.last_body_len], b[0..self.last_body_len]);
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, target, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{
                    .err = error_mod.WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = error_mod.WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }

    const vtable = http_mod.RequestExecutor.VTable{ .execute = executeImpl };
};

const FakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = c;
        _ = i;
        const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = t, .expires_in = 7200 } };
    }
};

fn setup(
    gpa: std.mem.Allocator,
    mock: *Recorder,
    threaded: *std.Io.Threaded,
    cfg: *config_mod.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try config_mod.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), mock.executor());
}

test "mass sendall: 按标签 / 全体 + msg_id 解析" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "mass/sendall", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":2000000006,\"msg_data_id\":2000000007}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MassService{ .svc = &base };
    const io = threaded.io();

    // 按标签 + text + clientmsgid
    switch (svc.sendAllByTag(io, 100, .{ .text = "群发文本" }, false, "cid-1")) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqualStrings("2000000006", res.msg_id);
            try testing.expectEqualStrings("2000000007", res.msg_data_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/sendall") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"filter\":{\"is_to_all\":false,\"tag_id\":100}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"text\":{\"content\":\"群发文本\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"msgtype\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"send_ignore_reprint\":0") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"clientmsgid\":\"cid-1\"") != null);

    // 全体 + mpnews(media_id)
    switch (svc.sendAll(io, .{ .mpnews = "NEWS_MID" }, true, null)) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqualStrings("2000000006", res.msg_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    const b2 = mock.body();
    try testing.expect(std.mem.indexOf(u8, b2, "\"filter\":{\"is_to_all\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, b2, "tag_id") == null);
    try testing.expect(std.mem.indexOf(u8, b2, "\"mpnews\":{\"media_id\":\"NEWS_MID\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b2, "\"msgtype\":\"mpnews\"") != null);
    try testing.expect(std.mem.indexOf(u8, b2, "\"send_ignore_reprint\":1") != null);
    try testing.expect(std.mem.indexOf(u8, b2, "clientmsgid") == null);
}

test "mass send / preview / delete: 请求体形状" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "mass/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":123}" },
        .{ .match = "mass/preview", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "mass/delete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MassService{ .svc = &base };
    const io = threaded.io();

    // send to openids(touser 数组;注意 mass/send 与 sendall 的 match 前缀区分)
    switch (svc.sendToOpenids(io, &.{ "o1", "o2" }, .{ .text = "hi" })) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqualStrings("123", res.msg_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/send") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"touser\":[\"o1\",\"o2\"]") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"text\":{\"content\":\"hi\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"msgtype\":\"text\"") != null);

    // preview(touser 收件)
    switch (svc.preview(io, "o1", null, .{ .image = "IMG_MID" })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/preview") != null);
    const b2 = mock.body();
    try testing.expect(std.mem.indexOf(u8, b2, "\"touser\":\"o1\"") != null);
    try testing.expect(std.mem.indexOf(u8, b2, "towxname") == null);
    try testing.expect(std.mem.indexOf(u8, b2, "\"image\":{\"media_id\":\"IMG_MID\"}") != null);

    // delete {msg_id, article_idx}(Java 键名)
    switch (svc.delete(io, 2000000006, 0)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/delete") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"msg_id\":2000000006") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"article_idx\":0") != null);
}

test "mass get_upload_rate 解析 + errcode!=0" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "mass/get", .response = "{\"is_progress_exist\":1,\"progress\":{\"current_rate\":88}}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MassService{ .svc = &base };

    switch (svc.getUploadRate(threaded.io(), 12345)) {
        .ok => |rate| try testing.expectEqual(@as(i64, 88), rate),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"msg_id\":12345") != null);

    // 失败路径:errcode=45009
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "mass/sendall", .response = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = MassService{ .svc = &base2 };
    switch (svc2.sendAllByTag(th2.io(), 1, .{ .text = "x" }, false, null)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45009), err.error_code);
        },
    }
}

test "mass newsUpload/videoUpload/speedGet/speedSet/massGet 契约" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "uploadnews", .response = "{\"errcode\":0,\"type\":\"news\",\"media_id\":\"CSN1\",\"created_at\":1395462616}" },
        .{ .match = "uploadvideo", .response = "{\"errcode\":0,\"type\":\"video\",\"media_id\":\"CSV1\",\"created_at\":1395462617}" },
        .{ .match = "speed/get", .response = "{\"errcode\":0,\"speed\":30,\"realspeed\":25}" },
        .{ .match = "speed/set", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "mass/get", .response = "{\"errcode\":0,\"msg_id\":12345,\"msg_status\":\"SEND_SUCCESS\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MassService{ .svc = &base };
    const io = threaded.io();

    // 1 massNewsUpload:字段序/恒发与可选省略对齐 WxMpNewsArticleGsonAdapter
    switch (svc.newsUpload(io, &.{
        .{
            .thumb_media_id = "T1",
            .thumb_url = "https://t/1",
            .title = "标题",
            .content = "内容",
            .author = "作者",
            .content_source_url = "https://s",
            .digest = "摘要",
            .show_cover_pic = true,
            .url = "https://u",
            .need_open_comment = true,
            .only_fans_can_comment = false,
        },
        .{ .thumb_media_id = "T2", .title = "T", .content = "C" },
    })) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqualStrings("news", res.type);
            try testing.expectEqualStrings("CSN1", res.media_id);
            try testing.expectEqual(@as(i64, 1395462616), res.created_at);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/uploadnews") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    {
        const b = mock.body();
        try testing.expect(std.mem.startsWith(u8, b, "{\"articles\":["));
        try testing.expect(std.mem.indexOf(u8, b, "\"thumb_media_id\":\"T1\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"thumb_url\":\"https://t/1\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"title\":\"标题\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"content\":\"内容\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"author\":\"作者\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"content_source_url\":\"https://s\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"digest\":\"摘要\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"show_cover_pic\":\"1\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"url\":\"https://u\"") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"need_open_comment\":1") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"only_fans_can_comment\":0") != null);
        // 第二篇:最小字段 —— thumb_url 恒发为 null,show_cover_pic 恒发 "0",可选项全省略
        try testing.expect(std.mem.indexOf(u8, b, "\"thumb_url\":null") != null);
        try testing.expect(std.mem.indexOf(u8, b, "\"show_cover_pic\":\"0\"") != null);
        try testing.expect(std.mem.endsWith(u8, b, "]}"));
    }

    // 2 massVideoUpload:字段序 media_id/description/title(WxMpMassVideoAdapter)
    switch (svc.videoUpload(io, "MID", "标题D", "描述")) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqualStrings("CSV1", res.media_id);
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/uploadvideo") != null);
    try testing.expectEqualStrings("{\"media_id\":\"MID\",\"description\":\"描述\",\"title\":\"标题D\"}", mock.body());

    // 3 messageMassSpeedGet:body "{}" → speed/realspeed
    switch (svc.speedGet(io)) {
        .ok => |r| {
            try testing.expectEqual(@as(i64, 30), r.speed);
            try testing.expectEqual(@as(i64, 25), r.realspeed);
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/speed/get") != null);
    try testing.expectEqualStrings("{}", mock.body());

    // 4 messageMassSpeedSet:{"speed":N}
    switch (svc.speedSet(io, 30)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/speed/set") != null);
    try testing.expectEqualStrings("{\"speed\":30}", mock.body());

    // 5 messageMassGet:{"msg_id":N} → msg_id/msg_status
    switch (svc.massGet(io, 12345)) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqual(@as(i64, 12345), res.msg_id);
            try testing.expectEqualStrings("SEND_SUCCESS", res.msg_status);
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/mass/get") != null);
    try testing.expectEqualStrings("{\"msg_id\":12345}", mock.body());

    try testing.expectEqual(@as(usize, 5), mock.calls);
}
