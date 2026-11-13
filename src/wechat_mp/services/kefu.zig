//! 客服服务 —— 全量重写,逐字对齐 Java `api.WxMpKefuService`(17 方法)+
//! `api.impl.WxMpKefuServiceImpl`。
//!
//! 命名(rule 2):17 个方法全部采用 Java 的 camelCase 名。Java 的两个 `kfMsgList`
//! 重载用 Zig 惯用法(rule 1)合并为单函数 `kfMsgList(io, start, end, page: ?MsgListParams)`:
//!   - `page == null` → Java `kfMsgList(startTime, endTime)`(:248 / impl :140-156)的
//!     **全量翻页 while 循环**,本轮用 `common.mp_helpers.Paginator` 复刻;
//!   - `page != null` → Java `kfMsgList(startTime, endTime, msgId, number)`(:233 /
//!     impl :119-137)的单页查询。
//! `sendKefuMessageWithResponse` 保留「返回原始响应串」语义(Java :49),故返回
//! `WxResult([]u8)` 而非 Done。
//!
//! 底座(rule 3):
//!   - 所有 URL 路径来自 `../api_url.zig:Kefu`,经 `api()`(= `api_url.url(Host.api, path)`)
//!     拼成绝对 URL;不再用旧 `service.zig:ApiUrl.*` 或本地 `Path` 常量。
//!   - 带 `?key=%s` 字面模板的 4 个路径(del / uploadheadimg / getsession /
//!     getsessionlist)走 `apiQuery()`:`buildUrl`/`urlEncode` 手工拼 query。buildUrl 无
//!     `%s` 替换能力 → 以「截取 '?' 前 path + buildUrl 追加编码 query」最小绕过(见下)。
//!   - `kfMsgList` 全量翻页用 `mp_helpers.Paginator`(ctx: *anyopaque + vtable)。
//!   - `kfAccountUploadHeadImg` multipart 用 `mp_helpers.buildMultipartBody` /
//!     `multipartContentType` + `Service.postWithHeaders`(与 `material.zig` 字节级兼容)。
//!
//! Java↔Zig 差异(rule 1,逐条):
//!   - `Date startTime/endTime` → unix **秒** `i64`(Java `getTime()/1000` 即秒)。
//!   - `File imgFile` → `(filename, content)` 字节对(Zig 侧无 java.io.File 抽象)。
//!   - Java `String.format(url, kfAccount)` 不编码;本轮 `buildUrl` 对值做百分号编码
//!     (openid / kf_account 含 '@' 等字符更安全,与 phase-2 `user.zig` 口径一致)。
//!   - Java `boolean`/`WxMediaUploadResult!=null` → `Done`(`.ok` 即 true,`.err` 即抛出);
//!     仅 `sendKefuMessageWithResponse` 需把响应串交还调用方才返回 `WxResult([]u8)`。
//!   - `number>10000` / `start>end` 的 `WxErrorException(String)` → `.err`(WxError.internal)。
//!   - `Service.execute*` 已统一折叠 errcode→`.err` 并注入 access_token,本文件不重复实现。
//!
//! `kf_session.zig` 重叠说明:Java `WxMpKefuService` 本身含 5 个会话方法
//! (kfSessionCreate/Close/Get/List/GetWaitCase)。本仓库另有一个 **独立文件**
//! `kf_session.zig` 用不同名字(kfsessionCreate/getSession/...)、且路径带
//! `cgi-bin/`(与 Java 枚举不符)实现了同类功能。按分工 **不改动/不合并** 该文件;
//! 本文件仍按 rule 2 完整实现这 5 个 Java-exact 名的方法(走 api_url 的正确路径)。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `[]u8` 裸结果:`gpa.free()`;
//!   - 结果结构体:`KfList`/`KfOnlineList`/`KfSessionGetResult`/`KfSessionList`/
//!     `KfSessionWaitCaseList`/`KfMsgList` 用各自的 `deinit()`(内部逐元素 deinit +
//!     free 切片);
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const mp_helpers = @import("common").mp_helpers;
const random_mod = @import("common").random;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;
const u_token = @import("common").token;

const api_url = @import("../api_url.zig");
const u_config = @import("../config.zig");
const u_http = @import("../http.zig");
const service_mod = @import("../service.zig");

/// host+path 绝对 URL(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// 带 `?key=%s` 字面模板路径 → 编码后的绝对 URL。
/// buildUrl/urlEncode 在 `common/mp_helpers.zig`:65/38;它们没有 `%s` 替换能力,
/// 故取模板 '?' 前的 path 作 base,再用 buildUrl 追加 `key=<urlEncode(value)>`。
/// 对应 Java `String.format(KFACCOUNT_DEL.getUrl(...), kfAccount)` 的占位符语义,
/// 但值走百分号编码(见文件头 Java↔Zig 差异)。返回 gpa 拥有的 []u8,调用方 free。
fn apiQuery(gpa: std.mem.Allocator, comptime path: []const u8, key: []const u8, value: []const u8) ![]u8 {
    const qmark = comptime (std.mem.indexOfScalar(u8, path, '?') orelse path.len);
    const base = api(path[0..qmark]);
    const q = [_]mp_helpers.Query{.{ .key = key, .value = value }};
    return mp_helpers.buildUrl(gpa, base, &q, null);
}

/// 取 JSON 字符串字段并 dupe 成 gpa 拥有(缺失返回 null)。对应 Java `GsonHelper.getString`。
fn dupeStr(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    const s = json_util.getStr(v, key) orelse return null;
    return try gpa.dupe(u8, s);
}

/// POST 且只关心 errcode(Java boolean/void 方法;errcode!=0 已在 Service 折叠为 .err)。
fn postVoid(self: *KefuService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (self.svc.post(io, api(path), &.{}, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// 客服消息 —— 对应 Java `bean.kefu.WxMpKefuMessage` +
// `util.json.WxMpKefuMessageGsonAdapter`(msgtype 用 tagged union 表达)。
// 保留旧 kefu.zig 的序列化意图(离线契约测试逐分支校验)。
// ---------------------------------------------------------------------------

/// 图文消息文章 —— `WxMpKefuMessage#WxMpKefuArticle` 的 news 子字段。
pub const Article = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",
    picurl: []const u8 = "",
};

/// 视频消息载荷(media_id/thumb_media_id/title/description)。
pub const VideoMsg = struct {
    media_id: []const u8 = "",
    thumb_media_id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
};

/// 消息载荷:tagged union,tag 名即微信 msgtype(text/image/voice/video/news)。
pub const Msg = union(enum) {
    text: []const u8,
    image: []const u8,
    voice: []const u8,
    video: VideoMsg,
    news: []const Article,

    pub fn msgType(self: Msg) []const u8 {
        return @tagName(self);
    }
};

/// 完整客服消息(toUser + msgType + 类型载荷)。
pub const KefuMessage = struct {
    to_user: []const u8,
    content: Msg,
};

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// `{"touser":..,"msgtype":..,<type>:{..}}` —— 对齐 `WxMpKefuMessageGsonAdapter#serialize`。
pub fn messageToJson(gpa: std.mem.Allocator, m: KefuMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"touser\":");
    try jw.str(w, m.to_user);

    switch (m.content) {
        .text => |c| {
            try w.writeAll(",\"msgtype\":\"text\",\"text\":{\"content\":");
            try jw.str(w, c);
            try w.writeByte('}');
        },
        .image => |mid| {
            try w.writeAll(",\"msgtype\":\"image\",\"image\":{\"media_id\":");
            try jw.str(w, mid);
            try w.writeByte('}');
        },
        .voice => |mid| {
            try w.writeAll(",\"msgtype\":\"voice\",\"voice\":{\"media_id\":");
            try jw.str(w, mid);
            try w.writeByte('}');
        },
        .video => |v| {
            try w.writeAll(",\"msgtype\":\"video\",\"video\":{\"media_id\":");
            try jw.str(w, v.media_id);
            try w.writeAll(",\"thumb_media_id\":");
            try jw.str(w, v.thumb_media_id);
            try w.writeAll(",\"title\":");
            try jw.str(w, v.title);
            try w.writeAll(",\"description\":");
            try jw.str(w, v.description);
            try w.writeByte('}');
        },
        .news => |arts| {
            try w.writeAll(",\"msgtype\":\"news\",\"news\":{\"articles\":[");
            for (arts, 0..) |a, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll("{\"title\":");
                try jw.str(w, a.title);
                try w.writeAll(",\"description\":");
                try jw.str(w, a.description);
                try w.writeAll(",\"url\":");
                try jw.str(w, a.url);
                try w.writeAll(",\"picurl\":");
                try jw.str(w, a.picurl);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        },
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// 客服账号请求 —— `bean.kefu.request.WxMpKfAccountRequest`
/// (Gson 省略 null 字段,故 invite_wx 仅在非 null 时写入)。
pub const KfAccountRequest = struct {
    kf_account: []const u8,
    nickname: []const u8 = "",
    invite_wx: ?[]const u8 = null,
};

fn accountReqToJson(gpa: std.mem.Allocator, r: KfAccountRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"kf_account\":");
    try jw.str(w, r.kf_account);
    try w.writeAll(",\"nickname\":");
    try jw.str(w, r.nickname);
    if (r.invite_wx) |iw| {
        try w.writeAll(",\"invite_wx\":");
        try jw.str(w, iw);
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// `{"kf_account":..,"openid":..}` —— `WxMpKfSessionRequest.toJson()`(字段声明顺序
/// kf_account → openid,Gson 保序)。kfSessionCreate/Close 共用。
fn sessionBody(gpa: std.mem.Allocator, kf_account: []const u8, openid: []const u8) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("kf_account", kf_account);
    try ob.putStr("openid", openid);
    return ob.toJson();
}

/// `{"touser":..,"command":..}` —— sendKfTypingState(impl :160-163)。
fn typingBody(gpa: std.mem.Allocator, touser: []const u8, command: []const u8) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putStr("touser", touser);
    try ob.putStr("command", command);
    return ob.toJson();
}

/// `{"starttime":..,"endtime":..,"msgid":..,"number":..}` —— 单页 kfMsgList
/// (impl :128-134;Java JsonObject 保序)。
fn msgListBody(gpa: std.mem.Allocator, start_time: i64, end_time: i64, msg_id: i64, number: i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    try ob.putInt("starttime", start_time);
    try ob.putInt("endtime", end_time);
    try ob.putInt("msgid", msg_id);
    try ob.putInt("number", number);
    return ob.toJson();
}

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 单条客服信息/在线状态 —— Java `bean.kefu.result.WxMpKfInfo`。
pub const KfInfo = struct {
    gpa: std.mem.Allocator,
    /// kf_account(始终 gpa 拥有:缺失 dupe 空串,保证 deinit 的 free 合法)
    account: []const u8,
    /// kf_nick
    nick: ?[]const u8 = null,
    /// kf_id
    id: ?[]const u8 = null,
    /// kf_headimgurl
    head_img_url: ?[]const u8 = null,
    /// kf_wx
    wx_account: ?[]const u8 = null,
    /// invite_wx
    invite_wx: ?[]const u8 = null,
    /// invite_expire_time
    invite_expire_time: ?i64 = null,
    /// invite_status
    invite_status: ?[]const u8 = null,
    /// status
    status: ?i64 = null,
    /// accepted_case
    accepted_case: ?i64 = null,

    pub fn deinit(self: *KfInfo) void {
        const g = self.gpa;
        g.free(@constCast(self.account));
        for ([_]?[]const u8{
            self.nick,      self.id,            self.head_img_url, self.wx_account,
            self.invite_wx, self.invite_status,
        }) |s| if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfInfo {
        var r = KfInfo{
            .gpa = gpa,
            .account = (try dupeStr(gpa, v, "kf_account")) orelse try gpa.dupe(u8, ""),
        };
        errdefer r.deinit();
        r.nick = try dupeStr(gpa, v, "kf_nick");
        r.id = try dupeStr(gpa, v, "kf_id");
        r.head_img_url = try dupeStr(gpa, v, "kf_headimgurl");
        r.wx_account = try dupeStr(gpa, v, "kf_wx");
        r.invite_wx = try dupeStr(gpa, v, "invite_wx");
        r.invite_status = try dupeStr(gpa, v, "invite_status");
        r.invite_expire_time = json_util.getInt(v, "invite_expire_time");
        r.status = json_util.getInt(v, "status");
        r.accepted_case = json_util.getInt(v, "accepted_case");
        return r;
    }
};

/// `{"kf_list":[..]}` —— Java `WxMpKfList`。
pub const KfList = struct {
    gpa: std.mem.Allocator,
    items: []KfInfo = &.{},

    pub fn deinit(self: *KfList) void {
        for (self.items) |*k| {
            var tmp = k.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

/// `{"kf_online_list":[..]}` —— Java `WxMpKfOnlineList`(与 KfList 结构相同,独立 bean)。
pub const KfOnlineList = struct {
    gpa: std.mem.Allocator,
    items: []KfInfo = &.{},

    pub fn deinit(self: *KfOnlineList) void {
        for (self.items) |*k| {
            var tmp = k.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

/// `{"kf_account":..,"createtime":..}` —— Java `WxMpKfSessionGetResult`。
pub const KfSessionGetResult = struct {
    gpa: std.mem.Allocator,
    kf_account: ?[]const u8 = null,
    createtime: i64 = 0,

    pub fn deinit(self: *KfSessionGetResult) void {
        if (self.kf_account) |v| self.gpa.free(@constCast(v));
        self.* = undefined;
    }
};

/// 一条会话 —— Java `WxMpKfSession`(getsessionlist / waitcaselist 元素)。
pub const KfSession = struct {
    gpa: std.mem.Allocator,
    kf_account: ?[]const u8 = null,
    createtime: i64 = 0,
    latest_time: i64 = 0,
    openid: ?[]const u8 = null,

    pub fn deinit(self: *KfSession) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.kf_account, self.openid }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfSession {
        var r = KfSession{ .gpa = gpa };
        errdefer r.deinit();
        r.kf_account = try dupeStr(gpa, v, "kf_account");
        r.openid = try dupeStr(gpa, v, "openid");
        r.createtime = json_util.getIntOr(v, "createtime", 0);
        r.latest_time = json_util.getIntOr(v, "latest_time", 0);
        return r;
    }
};

/// `{"sessionlist":[..]}` —— Java `WxMpKfSessionList`。
pub const KfSessionList = struct {
    gpa: std.mem.Allocator,
    items: []KfSession = &.{},

    pub fn deinit(self: *KfSessionList) void {
        for (self.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

/// `{"count":..,"waitcaselist":[..]}` —— Java `WxMpKfSessionWaitCaseList`。
pub const KfSessionWaitCaseList = struct {
    gpa: std.mem.Allocator,
    count: i64 = 0,
    items: []KfSession = &.{},

    pub fn deinit(self: *KfSessionWaitCaseList) void {
        for (self.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

/// 一条聊天记录 —— Java `WxMpKfMsgRecord`(worker/openid/opercode/text/time)。
pub const KfMsgRecord = struct {
    gpa: std.mem.Allocator,
    worker: ?[]const u8 = null,
    openid: ?[]const u8 = null,
    opercode: ?i64 = null,
    text: ?[]const u8 = null,
    time: i64 = 0,

    pub fn deinit(self: *KfMsgRecord) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.worker, self.openid, self.text }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfMsgRecord {
        var r = KfMsgRecord{ .gpa = gpa };
        errdefer r.deinit();
        r.worker = try dupeStr(gpa, v, "worker");
        r.openid = try dupeStr(gpa, v, "openid");
        r.text = try dupeStr(gpa, v, "text");
        r.opercode = json_util.getInt(v, "opercode");
        r.time = json_util.getIntOr(v, "time", 0);
        return r;
    }

    /// Paginator.merge 需要把页数据拷进累加器 → 深拷贝(字符串 dupe)。
    fn clone(self: KfMsgRecord, gpa: std.mem.Allocator) !KfMsgRecord {
        var r = KfMsgRecord{ .gpa = gpa, .opercode = self.opercode, .time = self.time };
        errdefer r.deinit();
        if (self.worker) |s| r.worker = try gpa.dupe(u8, s);
        if (self.openid) |s| r.openid = try gpa.dupe(u8, s);
        if (self.text) |s| r.text = try gpa.dupe(u8, s);
        return r;
    }
};

/// `{"recordlist":[..],"number":..,"msgid":..}` —— Java `WxMpKfMsgList`。
pub const KfMsgList = struct {
    gpa: std.mem.Allocator,
    records: []KfMsgRecord = &.{},
    number: i64 = 0,
    msg_id: i64 = 0,

    pub fn deinit(self: *KfMsgList) void {
        for (self.records) |*r| {
            var tmp = r.*;
            tmp.deinit();
        }
        if (self.records.len != 0) self.gpa.free(self.records);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfMsgList {
        var r = KfMsgList{ .gpa = gpa };
        errdefer r.deinit();
        r.number = json_util.getIntOr(v, "number", 0);
        r.msg_id = json_util.getIntOr(v, "msgid", 0);
        var list: std.ArrayList(KfMsgRecord) = .empty;
        errdefer {
            for (list.items) |*rec| {
                var tmp = rec.*;
                tmp.deinit();
            }
            list.deinit(gpa);
        }
        if (json_util.getArray(v, "recordlist")) |arr| {
            for (arr.items) |item| try list.append(gpa, try KfMsgRecord.fromJson(gpa, item));
        }
        r.records = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// 解析 `kf_list` / `kf_online_list` 的 `[]KfInfo`(逐元素 deinit + 切片 free 由上层
/// 结果结构 deinit 负责;此处 errdefer 负责失败回退)。
fn parseKfInfoList(gpa: std.mem.Allocator, root: json_util.Value, key: []const u8) ![]KfInfo {
    var list: std.ArrayList(KfInfo) = .empty;
    errdefer {
        for (list.items) |*k| {
            var tmp = k.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    if (json_util.getArray(root, key)) |arr| {
        for (arr.items) |item| try list.append(gpa, try KfInfo.fromJson(gpa, item));
    }
    return list.toOwnedSlice(gpa);
}

/// 解析 `sessionlist` / `waitcaselist` 的 `[]KfSession`。
fn parseSessionList(gpa: std.mem.Allocator, root: json_util.Value, key: []const u8) ![]KfSession {
    var list: std.ArrayList(KfSession) = .empty;
    errdefer {
        for (list.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    if (json_util.getArray(root, key)) |arr| {
        for (arr.items) |item| try list.append(gpa, try KfSession.fromJson(gpa, item));
    }
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// kfMsgList 全量翻页的 Paginator 夹具
// ---------------------------------------------------------------------------
//
// Java impl :140-156 精确语义:
//   page1 = kfMsgList(start,end, 1, 10000);
//   if (page1.number == 10000) {           // 首页满页才进入
//     p2 = kfMsgList(start,end, page1.msgid, 10000);
//     while (p2.records 非空) {            // 空页终止,且空页不并入 result
//       result.records.addAll(p2.records); result.number += p2.number;
//       result.msgid = p2.msgid;
//       p2 = kfMsgList(start,end, p2.msgid, 10000);
//     }
//   }
//   return result;                         // result 初值即 page1
//
// Paginator(见 mp_helpers.zig:213)的 while 守卫全部由 next_cursor 表达;
// 「首页满页」与「后续非空页」两种条件由 cursor.first 区分;空页由 merge 跳过
// (Java 也不并入空终止页)。Page 是借用视图,其内存由 ctx.current 持有/释放。

/// Java `kfMsgList(start,end,msgId,number)` 的单页参数;传 null 走全量翻页循环。
pub const MsgListParams = struct {
    msg_id: i64,
    number: i64,
};

const MsgCursor = struct {
    msg_id: i64,
    first: bool,
};

const MsgPage = struct {
    records: []KfMsgRecord,
    number: i64,
    msg_id: i64,
};

const KfMsgListAcc = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(KfMsgRecord) = .empty,
    number: i64 = 0,
    msg_id: i64 = 0,

    fn deinit(self: *KfMsgListAcc) void {
        for (self.records.items) |*r| {
            var tmp = r.*;
            tmp.deinit();
        }
        self.records.deinit(self.gpa);
        self.* = undefined;
    }
};

const MsgListCtx = struct {
    svc: *KefuService,
    io: std.Io,
    start_time: i64,
    end_time: i64,
    number: i64,
    current: ?KfMsgList = null,
    wx_err: ?WxError = null,
    is_first: bool = true,

    fn deinit(self: *MsgListCtx) void {
        if (self.current) |m| {
            var tmp = m;
            tmp.deinit();
            self.current = null;
        }
        if (self.wx_err) |e| {
            var tmp = e;
            tmp.deinit();
            self.wx_err = null;
        }
    }

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, cursor: MsgCursor) anyerror!MsgPage {
        _ = gpa;
        const self: *MsgListCtx = @ptrCast(@alignCast(ctx));
        self.is_first = cursor.first;
        // cursor 是值类型(i64/bool),不借用上一页内存,可立即释放上一页。
        if (self.current) |old| {
            var tmp = old;
            tmp.deinit();
            self.current = null;
        }
        const r = self.svc.msgListPage(self.io, self.start_time, self.end_time, cursor.msg_id, self.number);
        switch (r) {
            .err => |e| {
                self.wx_err = e;
                return error.MsgListPageFailed;
            },
            .ok => |m| self.current = m,
        }
        const p = &self.current.?;
        return .{ .records = p.records, .number = p.number, .msg_id = p.msg_id };
    }

    fn merge(ctx: *anyopaque, gpa: std.mem.Allocator, acc: *KfMsgListAcc, page: MsgPage) anyerror!void {
        const self: *MsgListCtx = @ptrCast(@alignCast(ctx));
        for (page.records) |rec| {
            const c = try rec.clone(gpa);
            acc.records.append(gpa, c) catch {
                var tmp = c;
                tmp.deinit();
                return error.OutOfMemory;
            };
        }
        acc.number += page.number;
        // Java:result 初值即 page1(msgId=page1.msgid);后续仅在并入非空页时更新
        // msgId;空终止页不并入 → 不更新。
        if (self.is_first or page.records.len > 0) acc.msg_id = page.msg_id;
    }

    fn nextCursor(ctx: *anyopaque, page: MsgPage, cursor: MsgCursor) ?MsgCursor {
        const self: *MsgListCtx = @ptrCast(@alignCast(ctx));
        if (cursor.first) {
            // Java:if (result.number == number) 进入循环,游标 = result.msgid
            if (page.number == self.number) return .{ .msg_id = page.msg_id, .first = false };
            return null;
        }
        // Java:while (followingResult != null && !followingResult.records.isEmpty())
        if (page.records.len > 0) return .{ .msg_id = page.msg_id, .first = false };
        return null;
    }
};

const msg_list_vtable = mp_helpers.Paginator(KfMsgListAcc, MsgPage, MsgCursor).VTable{
    .fetch = MsgListCtx.fetch,
    .merge = MsgListCtx.merge,
    .next_cursor = MsgListCtx.nextCursor,
};

// ---------------------------------------------------------------------------
// KefuService —— 对应 Java `WxMpKefuService`(17 方法)+ `WxMpKefuServiceImpl`
// ---------------------------------------------------------------------------

pub const KefuService = struct {
    svc: *service_mod.Service,

    /// `WxMpKefuService.sendKefuMessage` (接口 :36 / impl :30-32)。
    /// Java `return sendKefuMessageWithResponse(message) != null;` → Done。
    pub fn sendKefuMessage(self: *KefuService, io: std.Io, msg: KefuMessage) Done {
        switch (self.sendKefuMessageWithResponse(io, msg)) {
            .err => |e| return .{ .err = e },
            .ok => |b| {
                self.svc.gpa.free(b);
                return .{ .ok = {} };
            },
        }
    }

    /// `WxMpKefuService.sendKefuMessageWithResponse` (接口 :49 / impl :35-37)。
    /// POST `MESSAGE_CUSTOM_SEND`,body = `message.toJson()`;**返回原始响应串**。
    /// 所有权:`.ok` 为 gpa 拥有的 body,调用方 `gpa.free()`。
    pub fn sendKefuMessageWithResponse(self: *KefuService, io: std.Io, msg: KefuMessage) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = messageToJson(gpa, msg) catch
            return .{ .err = WxError.internal(gpa, "build kefu send body", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, api(api_url.Kefu.message_custom_send), &.{}, body);
    }

    /// `WxMpKefuService.kfList` (接口 :63 / impl :40-43)。
    /// GET `GET_KF_LIST`,解析 `kf_list` → `WxMpKfList.fromJson`。
    pub fn kfList(self: *KefuService, io: std.Io) WxResult(KfList) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, api(api_url.Kefu.get_kf_list), &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getkflist not json", .{}),
        };
        defer parsed.deinit();
        const items = parseKfInfoList(gpa, parsed.value, "kf_list") catch return .{
            .err = WxError.transport(gpa, "kf_list parse failed", .{}),
        };
        return .{ .ok = .{ .gpa = gpa, .items = items } };
    }

    /// `WxMpKefuService.kfOnlineList` (接口 :75 / impl :46-49)。
    /// GET `GET_ONLINE_KF_LIST`,解析 `kf_online_list` → `WxMpKfOnlineList.fromJson`。
    pub fn kfOnlineList(self: *KefuService, io: std.Io) WxResult(KfOnlineList) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, api(api_url.Kefu.get_online_kf_list), &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getonlinekflist not json", .{}),
        };
        defer parsed.deinit();
        const items = parseKfInfoList(gpa, parsed.value, "kf_online_list") catch return .{
            .err = WxError.transport(gpa, "kf_online_list parse failed", .{}),
        };
        return .{ .ok = .{ .gpa = gpa, .items = items } };
    }

    /// `WxMpKefuService.kfAccountAdd` (接口 :88 / impl :52-55)。
    /// POST `KFACCOUNT_ADD`,body = `request.toJson()`;成功即完成。
    pub fn kfAccountAdd(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = accountReqToJson(gpa, req) catch
            return .{ .err = WxError.internal(gpa, "build kfaccount add body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.kfaccount_add, body);
    }

    /// `WxMpKefuService.kfAccountUpdate` (接口 :101 / impl :58-61)。
    /// POST `KFACCOUNT_UPDATE`,body = `request.toJson()`;成功即完成。
    /// (旧 kefu.zig 的 `updateKfNickname` 用了一个本仓库 Java 没有的
    /// `/updnkfnickname` 路径,本轮改用 Java 枚举 `KFACCOUNT_UPDATE`。)
    pub fn kfAccountUpdate(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = accountReqToJson(gpa, req) catch
            return .{ .err = WxError.internal(gpa, "build kfaccount update body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.kfaccount_update, body);
    }

    /// `WxMpKefuService.kfAccountInviteWorker` (接口 :114 / impl :64-67)。
    /// POST `KFACCOUNT_INVITE_WORKER`,body = `request.toJson()`;成功即完成。
    pub fn kfAccountInviteWorker(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = accountReqToJson(gpa, req) catch
            return .{ .err = WxError.internal(gpa, "build kfaccount invite body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.kfaccount_invite_worker, body);
    }

    /// `WxMpKefuService.kfAccountUploadHeadImg` (接口 :128 / impl :70-75)。
    /// Java `execute(MediaUploadRequestExecutor, String.format(KFACCOUNT_UPLOAD_HEAD_IMG, kfAccount), imgFile)`
    /// 返回 `WxMediaUploadResult != null` → Done。
    /// Zig:`Service.postWithHeaders` + `mp_helpers.buildMultipartBody/multipartContentType`
    /// (字段名 `media`、application/octet-stream、无 description,与 `material.zig` 字节级兼容)。
    /// `imgFile` → `(filename, content)` 字节对;boundary 走随机串(同 material.zig addParts)。
    pub fn kfAccountUploadHeadImg(self: *KefuService, io: std.Io, kf_account: []const u8, filename: []const u8, content: []const u8) Done {
        const gpa = self.svc.gpa;
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(boundary);

        const body = mp_helpers.buildMultipartBody(gpa, boundary, filename, content, null) catch |e|
            return .{ .err = WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);

        const uri = apiQuery(gpa, api_url.Kefu.kfaccount_upload_head_img, "kf_account", kf_account) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);

        const ct = mp_helpers.multipartContentType(gpa, boundary) catch |e|
            return .{ .err = WxError.internal(gpa, "multipart content-type: {s}", .{@errorName(e)}) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{.{ .name = "Content-Type", .value = ct }};

        const resp = switch (self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// `WxMpKefuService.kfAccountDel` (接口 :141 / impl :78-82)。
    /// GET `String.format(KFACCOUNT_DEL, kfAccount)` → `responseContent != null`。
    pub fn kfAccountDel(self: *KefuService, io: std.Io, kf_account: []const u8) Done {
        const gpa = self.svc.gpa;
        const uri = apiQuery(gpa, api_url.Kefu.kfaccount_del, "kf_account", kf_account) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// `WxMpKefuService.kfSessionCreate` (接口 :158 / impl :85-89)。
    /// POST `KFSESSION_CREATE`,body = `new WxMpKfSessionRequest(kfAccount, openid).toJson()`。
    pub fn kfSessionCreate(self: *KefuService, io: std.Io, openid: []const u8, kf_account: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = sessionBody(gpa, kf_account, openid) catch
            return .{ .err = WxError.internal(gpa, "build kfsession create body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.kfsession_create, body);
    }

    /// `WxMpKefuService.kfSessionClose` (接口 :173 / impl :92-96)。
    /// POST `KFSESSION_CLOSE`,body 同 create。
    pub fn kfSessionClose(self: *KefuService, io: std.Io, openid: []const u8, kf_account: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = sessionBody(gpa, kf_account, openid) catch
            return .{ .err = WxError.internal(gpa, "build kfsession close body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.kfsession_close, body);
    }

    /// `WxMpKefuService.kfSessionGet` (接口 :187 / impl :99-103)。
    /// GET `String.format(KFSESSION_GET_SESSION, openid)` → `WxMpKfSessionGetResult.fromJson`。
    pub fn kfSessionGet(self: *KefuService, io: std.Io, openid: []const u8) WxResult(KfSessionGetResult) {
        const gpa = self.svc.gpa;
        const uri = apiQuery(gpa, api_url.Kefu.kfsession_get_session, "openid", openid) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getsession not json", .{}),
        };
        defer parsed.deinit();
        var r = KfSessionGetResult{ .gpa = gpa };
        errdefer r.deinit();
        r.kf_account = dupeStr(gpa, parsed.value, "kf_account") catch return .{
            .err = WxError.transport(gpa, "getsession parse failed", .{}),
        };
        r.createtime = json_util.getIntOr(parsed.value, "createtime", 0);
        return .{ .ok = r };
    }

    /// `WxMpKefuService.kfSessionList` (接口 :201 / impl :106-110)。
    /// GET `String.format(KFSESSION_GET_SESSION_LIST, kfAccount)` → `WxMpKfSessionList.fromJson`。
    pub fn kfSessionList(self: *KefuService, io: std.Io, kf_account: []const u8) WxResult(KfSessionList) {
        const gpa = self.svc.gpa;
        const uri = apiQuery(gpa, api_url.Kefu.kfsession_get_session_list, "kf_account", kf_account) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getsessionlist not json", .{}),
        };
        defer parsed.deinit();
        const items = parseSessionList(gpa, parsed.value, "sessionlist") catch return .{
            .err = WxError.transport(gpa, "sessionlist parse failed", .{}),
        };
        return .{ .ok = .{ .gpa = gpa, .items = items } };
    }

    /// `WxMpKefuService.kfSessionGetWaitCase` (接口 :214 / impl :113-116)。
    /// 注:Java 接口方法名是 `kfSessionGetWaitCase`(非 `kfSessionWaitCase`)。
    /// GET `KFSESSION_GET_WAIT_CASE` → `WxMpKfSessionWaitCaseList.fromJson`。
    pub fn kfSessionGetWaitCase(self: *KefuService, io: std.Io) WxResult(KfSessionWaitCaseList) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, api(api_url.Kefu.kfsession_get_wait_case), &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getwaitcase not json", .{}),
        };
        defer parsed.deinit();
        const items = parseSessionList(gpa, parsed.value, "waitcaselist") catch return .{
            .err = WxError.transport(gpa, "waitcaselist parse failed", .{}),
        };
        return .{ .ok = .{
            .gpa = gpa,
            .count = json_util.getIntOr(parsed.value, "count", 0),
            .items = items,
        } };
    }

    /// 单页查询 —— Java `kfMsgList(startTime, endTime, msgId, number)` (:233 / impl :119-137)。
    /// 校验 `number>10000` / `start>end`(Java `WxErrorException(String)` → .err);
    /// POST `MSG_RECORD_LIST`,body `{starttime,endtime,msgid,number}`(时间单位秒);
    /// 解析 `WxMpKfMsgList.fromJson`(recordlist/number/msgid)。
    fn msgListPage(self: *KefuService, io: std.Io, start_time: i64, end_time: i64, msg_id: i64, number: i64) WxResult(KfMsgList) {
        const gpa = self.svc.gpa;
        if (number > 10000) return .{ .err = WxError.internal(gpa, "非法参数请求，每次最多查询10000条记录！", .{}) };
        if (start_time > end_time) return .{ .err = WxError.internal(gpa, "起始时间不能晚于结束时间！", .{}) };
        const body = msgListBody(gpa, start_time, end_time, msg_id, number) catch
            return .{ .err = WxError.internal(gpa, "build getmsglist body", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.Kefu.msg_record_list), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "getmsglist not json", .{}),
        };
        defer parsed.deinit();
        const m = KfMsgList.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.transport(gpa, "getmsglist parse failed", .{}),
        };
        return .{ .ok = m };
    }

    /// `WxMpKefuService.kfMsgList` (接口 :233 与 :248 两个重载 / impl :119-156)。
    /// `page == null` → 无参全量翻页循环(impl :140-156),用 `mp_helpers.Paginator`
    /// 复刻;首页 msgId=1、number=10000,首页满页才继续,空页终止。
    /// `page != null` → 委托 `msgListPage` 取单页。
    /// 所有权:`.ok` 的 `KfMsgList` 用毕 `deinit()`。
    pub fn kfMsgList(self: *KefuService, io: std.Io, start_time: i64, end_time: i64, page: ?MsgListParams) WxResult(KfMsgList) {
        const gpa = self.svc.gpa;
        if (page) |p| {
            return self.msgListPage(io, start_time, end_time, p.msg_id, p.number);
        }

        var ctx = MsgListCtx{
            .svc = self,
            .io = io,
            .start_time = start_time,
            .end_time = end_time,
            .number = 10000,
        };
        defer ctx.deinit();
        var acc = KfMsgListAcc{ .gpa = gpa };
        defer acc.deinit();
        var p = mp_helpers.Paginator(KfMsgListAcc, MsgPage, MsgCursor){
            .ctx = &ctx,
            .vtable = &msg_list_vtable,
        };
        p.run(gpa, &acc, .{ .msg_id = 1, .first = true }) catch |e| {
            if (ctx.wx_err) |we| {
                const err = we;
                ctx.wx_err = null; // 转移所有权,避免 ctx.deinit 二次释放
                return .{ .err = err };
            }
            return .{ .err = WxError.internal(gpa, "kfMsgList: {s}", .{@errorName(e)}) };
        };

        // 累加器 → KfMsgList(toOwnedSlice 后 acc.records 为空,acc.deinit 安全)。
        const records = acc.records.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .records = records,
            .number = acc.number,
            .msg_id = acc.msg_id,
        } };
    }

    /// `WxMpKefuService.sendKfTypingState` (接口 :269 / impl :159-165)。
    /// POST `CUSTOM_TYPING`,body `{"touser":openid,"command":command}`;成功即完成。
    pub fn sendKfTypingState(self: *KefuService, io: std.Io, openid: []const u8, command: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = typingBody(gpa, openid, command) catch
            return .{ .err = WxError.internal(gpa, "build typing body", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.Kefu.custom_typing, body);
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试(URL / method / 请求体 / 响应字段 / 所有权)
// ---------------------------------------------------------------------------

/// 记录型 executor:捕获 method/uri/body/Content-Type,按**首个命中**路由。
/// `Entry.in_body=false`(默认)按 uri 子串匹配(对齐 `http.zig:StubExecutor`);
/// `in_body=true` 按 POST body 子串匹配(kfMsgList 的 msgid 在 body 里,见 Java impl)。
/// 同时实现 `execute` 与 `execute_with_headers` 两个 vtable 槽:Service.executeInternal
/// 统一走 executeWithHeaders,故 multipart 的自定义请求头也能被捕获断言。
const Recorder = struct {
    const Entry = struct { match: []const u8, response: []const u8, in_body: bool = false };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [2048]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [16384]u8 = undefined,
    last_body_len: usize = 0,
    last_content_type: [512]u8 = undefined,
    last_content_type_len: usize = 0,

    fn uri(self: *const Recorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const Recorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
    fn contentType(self: *const Recorder) []const u8 {
        return self.last_content_type[0..self.last_content_type_len];
    }

    fn executor(self: *Recorder) u_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn capture(self: *Recorder, method: u_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8, req_headers: []const result_mod.Header) void {
        self.calls += 1;
        self.last_method = @tagName(method);
        self.last_uri_len = @min(target.len, self.last_uri.len);
        @memcpy(self.last_uri[0..self.last_uri_len], target[0..self.last_uri_len]);
        const b = payload orelse "";
        self.last_body_len = @min(b.len, self.last_body.len);
        @memcpy(self.last_body[0..self.last_body_len], b[0..self.last_body_len]);
        self.last_content_type_len = 0;
        for (req_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                self.last_content_type_len = @min(h.value.len, self.last_content_type.len);
                @memcpy(self.last_content_type[0..self.last_content_type_len], h.value[0..self.last_content_type_len]);
                break;
            }
        }
    }

    fn route(self: *Recorder, gpa: std.mem.Allocator, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        const b = payload orelse "";
        for (self.entries) |e| {
            const hay = if (e.in_body) b else target;
            if (std.mem.indexOf(u8, hay, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{
                    .err = WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: u_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.capture(method, target, payload, &.{});
        return self.route(gpa, target, payload);
    }

    fn executeWithHeadersImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: u_http.RequestExecutor.Method, target: []const u8, req_headers: []const result_mod.Header, payload: ?[]const u8) WxResult(result_mod.Response) {
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.capture(method, target, payload, req_headers);
        return switch (self.route(gpa, target, payload)) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{ .body = b, .headers = &.{} } },
        };
    }

    const vtable = u_http.RequestExecutor.VTable{
        .execute = executeImpl,
        .execute_with_headers = executeWithHeadersImpl,
    };
};

const FakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) u_token.FetchOutcome {
        _ = c;
        _ = i;
        const tok = g.dupe(u8, "TOK") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = tok, .expires_in = 7200 } };
    }
};

/// 通用装配:注入任意 RequestExecutor,token 固定 "TOK"(与 user.zig:setupExec 同)。
fn setupExec(
    gpa: std.mem.Allocator,
    exec: u_http.RequestExecutor,
    threaded: *std.Io.Threaded,
    cfg: *u_config.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try u_config.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), exec);
}

test "sendKefuMessage / WithResponse: POST /custom/send, 返回响应, 消息体各分支, errcode" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/custom/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    // sendKefuMessageWithResponse:返回原始响应 body(gpa 拥有)
    switch (svc.sendKefuMessageWithResponse(io, .{ .to_user = "oABC", .content = .{ .text = "你好" } })) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expect(std.mem.indexOf(u8, b, "\"errcode\":0") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/custom/send") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"touser\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"msgtype\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"text\":{\"content\":\"你好\"}") != null);

    // sendKefuMessage:Java `WithResponse != null` → Done
    switch (svc.sendKefuMessage(io, .{ .to_user = "oABC", .content = .{ .text = "x" } })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // messageToJson 各分支形状(保留旧契约测试意图)
    const nb = messageToJson(gpa, .{ .to_user = "oX", .content = .{ .news = &.{
        .{ .title = "t1", .description = "d1", .url = "http://u1", .picurl = "http://p1" },
        .{ .title = "t2", .description = "d2", .url = "http://u2", .picurl = "http://p2" },
    } } }) catch return error.Unexpected;
    defer gpa.free(nb);
    try testing.expect(std.mem.indexOf(u8, nb, "\"msgtype\":\"news\"") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "\"news\":{\"articles\":[") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "{\"title\":\"t1\",\"description\":\"d1\",\"url\":\"http://u1\",\"picurl\":\"http://p1\"}") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "\"picurl\":\"http://p2\"}") != null);

    const ib = messageToJson(gpa, .{ .to_user = "o", .content = .{ .image = "MID" } }) catch return error.Unexpected;
    defer gpa.free(ib);
    try testing.expect(std.mem.indexOf(u8, ib, "\"msgtype\":\"image\",\"image\":{\"media_id\":\"MID\"}") != null);
    const vb = messageToJson(gpa, .{ .to_user = "o", .content = .{ .voice = "MID" } }) catch return error.Unexpected;
    defer gpa.free(vb);
    try testing.expect(std.mem.indexOf(u8, vb, "\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"MID\"}") != null);
    const vdb = messageToJson(gpa, .{ .to_user = "o", .content = .{ .video = .{
        .media_id = "M",
        .thumb_media_id = "T",
        .title = "tt",
        .description = "dd",
    } } }) catch return error.Unexpected;
    defer gpa.free(vdb);
    try testing.expect(std.mem.indexOf(u8, vdb, "\"video\":{\"media_id\":\"M\",\"thumb_media_id\":\"T\",\"title\":\"tt\",\"description\":\"dd\"}") != null);

    // 失败路径:errcode=45015(非 token 类,不触发自动刷新重试)
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/custom/send", .response = "{\"errcode\":45015,\"errmsg\":\"reply out of time limit\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: u_config.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setupExec(gpa, mock2.executor(), &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = KefuService{ .svc = &base2 };
    switch (svc2.sendKefuMessage(th2.io(), .{ .to_user = "o", .content = .{ .text = "x" } })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45015), err.error_code);
        },
    }
}

test "kfAccount* + kfList/kfOnlineList: URL / 请求体 / query 编码 / 解析 / 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getkflist", .response = "{\"errcode\":0,\"kf_list\":[{\"kf_account\":\"a1@test\",\"kf_nick\":\"n1\",\"kf_id\":\"1\",\"kf_headimgurl\":\"http://h1\"},{\"kf_account\":\"a2@test\",\"kf_nick\":\"n2\"}]}" },
        .{ .match = "getonlinekflist", .response = "{\"errcode\":0,\"kf_online_list\":[{\"kf_account\":\"a1@test\",\"kf_id\":\"1\",\"status\":1,\"accepted_case\":2}]}" },
        .{ .match = "kfaccount/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfaccount/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfaccount/inviteworker", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfaccount/del", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    // kfList:GET /cgi-bin/customservice/getkflist → kf_list[] + 所有权
    switch (svc.kfList(io)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 2), res.items.len);
            try testing.expectEqualStrings("a1@test", res.items[0].account);
            try testing.expectEqualStrings("n1", res.items[0].nick.?);
            try testing.expectEqualStrings("1", res.items[0].id.?);
            try testing.expectEqualStrings("http://h1", res.items[0].head_img_url.?);
            try testing.expect(res.items[1].head_img_url == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/customservice/getkflist") != null);

    // kfOnlineList:status/accepted_case
    switch (svc.kfOnlineList(io)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 1), res.items.len);
            try testing.expectEqual(@as(?i64, 1), res.items[0].status);
            try testing.expectEqual(@as(?i64, 2), res.items[0].accepted_case);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/customservice/getonlinekflist") != null);

    // kfAccountAdd {kf_account,nickname,invite_wx}
    switch (svc.kfAccountAdd(io, .{ .kf_account = "new@test", .nickname = "n", .invite_wx = "wxid" })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/add") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"kf_account\":\"new@test\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"nickname\":\"n\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"invite_wx\":\"wxid\"") != null);

    // kfAccountUpdate(Java KFACCOUNT_UPDATE,非旧 updnkfnickname)
    switch (svc.kfAccountUpdate(io, .{ .kf_account = "a1@test", .nickname = "新昵称" })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/update") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"nickname\":\"新昵称\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "invite_wx") == null); // Gson 省略 null

    // kfAccountInviteWorker
    switch (svc.kfAccountInviteWorker(io, .{ .kf_account = "new@test", .invite_wx = "wxid" })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/inviteworker") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"invite_wx\":\"wxid\"") != null);

    // kfAccountDel:GET + 值百分号编码 '@'→%40
    switch (svc.kfAccountDel(io, "a1@test")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/del") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kf_account=a1%40test") != null);

    // 失败路径:errcode=48001
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfaccount/add", .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: u_config.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setupExec(gpa, mock2.executor(), &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = KefuService{ .svc = &base2 };
    switch (svc2.kfAccountAdd(th2.io(), .{ .kf_account = "x", .nickname = "y" })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 48001), err.error_code);
        },
    }
}

test "kfAccountUploadHeadImg: multipart body + Content-Type 头 + kf_account query" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfaccount/uploadheadimg", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    const content = "\x89PNG\r\n\x1a\nFAKE_IMG_BYTES";
    switch (svc.kfAccountUploadHeadImg(io, "kf1@test", "head.png", content)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/uploadheadimg") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kf_account=kf1%40test") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

    // Content-Type 头:multipart/form-data; boundary=<随机串>
    const ct = mock.contentType();
    const prefix = "multipart/form-data; boundary=";
    try testing.expect(std.mem.startsWith(u8, ct, prefix));
    const boundary = ct[prefix.len..];
    try testing.expect(boundary.len > 0);

    // body 与 mp_helpers.buildMultipartBody(boundary, ...) 字节级一致
    const expected = mp_helpers.buildMultipartBody(gpa, boundary, "head.png", content, null) catch return error.Unexpected;
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, mock.body());
    try testing.expect(std.mem.indexOf(u8, mock.body(), "Content-Disposition: form-data; name=\"media\"; filename=\"head.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "Content-Type: application/octet-stream") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), content) != null);
    // 无 description 部分
    try testing.expect(std.mem.indexOf(u8, mock.body(), "name=\"description\"") == null);
}

test "kfSessionCreate/Close: POST {kf_account,openid} + URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfsession/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfsession/close", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    switch (svc.kfSessionCreate(io, "oABC", "kf1@test")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfsession/create") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"kf_account\":\"kf1@test\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"oABC\"") != null);

    switch (svc.kfSessionClose(io, "oABC", "kf1@test")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfsession/close") != null);
}

test "kfSessionGet/List/GetWaitCase: GET + 模板 query 编码 + 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = Recorder{
        .gpa = gpa,
        .entries = &.{
            // 更具体匹配优先(getsessionlist 先于 getsession;getwaitcase 独立)
            .{ .match = "kfsession/getsessionlist", .response = "{\"sessionlist\":[{\"openid\":\"o1\",\"createtime\":1700000001},{\"openid\":\"o2\",\"kf_account\":\"kf1@test\",\"createtime\":1700000002}]}" },
            .{ .match = "kfsession/getsession?", .response = "{\"kf_account\":\"kf1@test\",\"createtime\":1700000000}" },
            .{ .match = "kfsession/getwaitcase", .response = "{\"count\":2,\"waitcaselist\":[{\"openid\":\"o3\",\"latest_time\":1700000003}]}" },
        },
    };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    switch (svc.kfSessionGet(io, "oABC")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("kf1@test", res.kf_account.?);
            try testing.expectEqual(@as(i64, 1700000000), res.createtime);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/getsession?openid=oABC") != null);

    switch (svc.kfSessionList(io, "kf1@test")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 2), res.items.len);
            try testing.expectEqualStrings("o1", res.items[0].openid.?);
            try testing.expectEqualStrings("kf1@test", res.items[1].kf_account.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/getsessionlist?kf_account=kf1%40test") != null);

    switch (svc.kfSessionGetWaitCase(io)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(i64, 2), res.count);
            try testing.expectEqual(@as(usize, 1), res.items.len);
            try testing.expectEqualStrings("o3", res.items[0].openid.?);
            try testing.expectEqual(@as(i64, 1700000003), res.items[0].latest_time);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "kfsession/getwaitcase") != null);
}

test "StubExecutor URI 子串路由: 更具体匹配优先(getsessionlist 先于 getsession)" {
    const gpa = testing.allocator;
    // 真正使用 http.zig:StubExecutor(按 uri 子串,首个命中优先)。
    // 若把泛化的 "getsession" 放前面,getsessionlist 请求会被错误命中。
    var stub = u_http.StubExecutor.init(gpa, &.{
        .{ .match = "getsessionlist", .response = "{\"sessionlist\":[{\"openid\":\"o1\"},{\"openid\":\"o2\"}]}" },
        .{ .match = "getsession", .response = "{\"kf_account\":\"kf1@test\",\"createtime\":1700000000}" },
    });
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, stub.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    switch (svc.kfSessionList(io, "kf1@test")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 2), res.items.len); // 证明命中的是 getsessionlist 页
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    switch (svc.kfSessionGet(io, "oABC")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("kf1@test", res.kf_account.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 2), stub.calls);
}

test "kfMsgList 单页: POST {starttime,endtime,msgid,number} + 校验 + 解析" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "msgrecord/getmsglist", .response = "{\"recordlist\":[{\"worker\":\"kf1@test\",\"openid\":\"o1\",\"opercode\":2002,\"text\":\"hi\",\"time\":1700000001},{\"openid\":\"o2\",\"opercode\":2003,\"text\":\"yo\",\"time\":1700000002}],\"number\":2,\"msgid\":42}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    switch (svc.kfMsgList(io, 1700000000, 1700003600, .{ .msg_id = 1, .number = 100 })) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(i64, 2), res.number);
            try testing.expectEqual(@as(i64, 42), res.msg_id);
            try testing.expectEqual(@as(usize, 2), res.records.len);
            try testing.expectEqualStrings("kf1@test", res.records[0].worker.?);
            try testing.expectEqual(@as(?i64, 2002), res.records[0].opercode);
            try testing.expectEqualStrings("hi", res.records[0].text.?);
            try testing.expectEqualStrings("o2", res.records[1].openid.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/msgrecord/getmsglist") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"starttime\":1700000000") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"endtime\":1700003600") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"msgid\":1") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"number\":100") != null);

    // number>10000 → .err(Java WxErrorException)
    switch (svc.kfMsgList(io, 100, 200, .{ .msg_id = 1, .number = 10001 })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, -99), err.error_code);
        },
    }
    // start>end → .err
    switch (svc.kfMsgList(io, 200, 100, .{ .msg_id = 1, .number = 100 })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, -99), err.error_code);
        },
    }
    try testing.expectEqual(@as(usize, 1), mock.calls); // 校验在发请求之前,不发网络
}

test "kfMsgList 全量翻页: Paginator 跨 ≥2 页累加,msgid 游标推进,空页终止" {
    const gpa = testing.allocator;
    // msgid 在 POST body(Java impl :128-134),故按 body 子串路由。
    // 更具体匹配优先:泛化的 "\"msgid\":1" 是 "\"msgid\":100" 的前缀,必须放最后,
    // 否则第 2 页会被错误命中首页 → 死循环。对齐 user.zig:userListAll 的顺序敏感性。
    const p1 = "{\"recordlist\":[{\"worker\":\"kf1\",\"openid\":\"o1\",\"opercode\":2002,\"text\":\"hi\",\"time\":1700000001},{\"worker\":\"kf1\",\"openid\":\"o2\",\"opercode\":2003,\"text\":\"yo\",\"time\":1700000002}],\"number\":10000,\"msgid\":100}";
    const p2 = "{\"recordlist\":[{\"worker\":\"kf2\",\"openid\":\"o3\",\"opercode\":2002,\"text\":\"last\",\"time\":1700000003}],\"number\":1,\"msgid\":200}";
    const p3 = "{\"recordlist\":[],\"number\":0,\"msgid\":300}";
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "\"msgid\":200", .response = p3, .in_body = true },
        .{ .match = "\"msgid\":100", .response = p2, .in_body = true },
        .{ .match = "\"msgid\":1", .response = p1, .in_body = true },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };

    switch (svc.kfMsgList(threaded.io(), 1700000000, 1700003600, null)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            // 3 条记录:r1,r2(首页)+r3(第 2 页);空终止页不并入
            try testing.expectEqual(@as(usize, 3), res.records.len);
            try testing.expectEqualStrings("kf1", res.records[0].worker.?);
            try testing.expectEqualStrings("o1", res.records[0].openid.?);
            try testing.expectEqualStrings("o2", res.records[1].openid.?);
            try testing.expectEqualStrings("o3", res.records[2].openid.?);
            try testing.expectEqual(@as(i64, 10001), res.number); // 10000 + 1 + 0
            try testing.expectEqual(@as(i64, 200), res.msg_id); // 最后非空页的 msgid
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 3), mock.calls); // 首页 + 第 2 页 + 空终止页
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/msgrecord/getmsglist") != null);
    // 最后一次请求游标推进到 200(空终止页)
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"msgid\":200") != null);
}

test "sendKfTypingState: POST {touser,command} + URL" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/custom/typing", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };

    switch (svc.sendKfTypingState(threaded.io(), "oABC", "Typing")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/custom/typing") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"touser\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"command\":\"Typing\"") != null);
}
