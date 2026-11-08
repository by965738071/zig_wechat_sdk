//! 客服服务 —— 对应 Java `api.WxMpKefuService` + `api.impl.WxMpKefuServiceImpl`。
//!
//! 子服务样板(见 `user.zig`/`template_msg.zig`):结构体持有 parent service 引用,
//! 方法 = 拼 uri → service.get/post → 解析 JSON。
//! URL 以 Java `enums.WxMpApiUrl.Kefu` 常量为准。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// URL 常量表 —— 对应 Java `WxMpApiUrl.Kefu` 枚举常量(去掉前导 '/',
/// 由 `api_host_url`("https://api.weixin.qq.com/")拼前缀)。
pub const Path = struct {
    /// `MESSAGE_CUSTOM_SEND`:发送客服消息。
    pub const custom_send = "cgi-bin/message/custom/send";
    /// `GET_KF_LIST`:全部客服列表(Java 常量为 /cgi-bin/customservice/getkflist,
    /// 注意不是任务单里写的 /customservice/kfaccount/getkflist —— URL 以 Java 为准)。
    pub const get_kf_list = "cgi-bin/customservice/getkflist";
    /// `GET_ONLINE_KF_LIST`:在线客服列表(任务单提到的 customservice.kfonline.get
    /// 并非本仓库 Java 常量,以 Java `GET_ONLINE_KF_LIST` 为准)。
    pub const get_online_kf_list = "cgi-bin/customservice/getonlinekflist";
    /// `KFACCOUNT_ADD`:添加客服账号。
    pub const kfaccount_add = "customservice/kfaccount/add";
    /// `KFACCOUNT_DEL`:删除客服账号(Java 为 GET + `?kf_account=%s`,此处用 Query 参数)。
    pub const kfaccount_del = "customservice/kfaccount/del";
    /// 设置客服昵称(update_kf_nickname)。
    /// 注意:本 checkout 的 Java `WxMpApiUrl.Kefu` 无此常量(仅有 `KFACCOUNT_UPDATE`),
    /// 此处按任务清单/微信官方文档收录 `/customservice/kfaccount/updnkfnickname`。
    pub const kfaccount_updnickname = "customservice/kfaccount/updnkfnickname";
};

// ---------------------------------------------------------------------------
// 客服消息 —— 对应 Java `bean.kefu.WxMpKefuMessage` +
// `util.json.WxMpKefuMessageGsonAdapter`(msgtype 用 tagged union 表达)。
// ---------------------------------------------------------------------------

/// 图文消息文章 —— 对应 `WxMpKefuMessage#WxMpKefuArticle` 的 news 子字段。
pub const Article = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",
    picurl: []const u8 = "",
};

/// 视频消息载荷 —— 对应 Java video 分支(media_id/thumb_media_id/title/description)。
pub const VideoMsg = struct {
    media_id: []const u8 = "",
    thumb_media_id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
};

/// 消息载荷:tagged union,tag 名即微信 msgtype(text/image/voice/video/news)。
pub const Msg = union(enum) {
    /// 文本消息,载荷为 content。
    text: []const u8,
    /// 图片消息,载荷为 media_id。
    image: []const u8,
    /// 语音消息,载荷为 media_id。
    voice: []const u8,
    /// 视频消息。
    video: VideoMsg,
    /// 图文消息,载荷为 articles 数组(Java news 分支)。
    news: []const Article,

    /// msgtype 字符串(tag 名与微信协议一致)。
    pub fn msgType(self: Msg) []const u8 {
        return @tagName(self);
    }
};

/// 完整客服消息 —— 对应 `WxMpKefuMessage`(toUser + msgType + 类型载荷)。
pub const KefuMessage = struct {
    to_user: []const u8,
    content: Msg,
};

/// 手写 JSON 转义写串(与 `user_tag.zig` 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// 序列化为微信 `message/custom/send` 请求体,形状对齐
/// `WxMpKefuMessageGsonAdapter#serialize`:{"touser":..,"msgtype":..,<type>:{..}}。
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

/// 客服账号请求 —— 对应 `bean.kefu.request.WxMpKfAccountRequest`
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

// ---------------------------------------------------------------------------
// 客服信息结果 —— 对应 `bean.kefu.result.WxMpKfInfo`
/// (getkflist 与 getonlinekflist 共用,在线列表额外带 status/accepted_case)。
// ---------------------------------------------------------------------------

pub const KfInfo = struct {
    gpa: std.mem.Allocator,
    /// kf_account
    account: []const u8,
    /// kf_nick
    nick: ?[]const u8 = null,
    /// kf_id
    id: ?[]const u8 = null,
    /// kf_headimgurl
    head_img_url: ?[]const u8 = null,
    /// 在线状态(getonlinekflist)
    status: ?i64 = null,
    /// 已接入会话数(getonlinekflist)
    accepted_case: ?i64 = null,

    pub fn deinit(self: *KfInfo) void {
        const g = self.gpa;
        if (self.account.len != 0) g.free(@constCast(self.account));
        for ([_]?[]const u8{ self.nick, self.id, self.head_img_url }) |s| {
            if (s) |v| g.free(@constCast(v));
        }
    }

    fn dupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        const s = json_util.getStr(v, key) orelse return null;
        return try gpa.dupe(u8, s);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !KfInfo {
        return .{
            .gpa = gpa,
            .account = (try dupe(gpa, v, "kf_account")) orelse "",
            .nick = try dupe(gpa, v, "kf_nick"),
            .id = try dupe(gpa, v, "kf_id"),
            .head_img_url = try dupe(gpa, v, "kf_headimgurl"),
            .status = json_util.getInt(v, "status"),
            .accepted_case = json_util.getInt(v, "accepted_case"),
        };
    }
};

/// 解析 `{"kf_list":[..]}` / `{"kf_online_list":[..]}` —— 对应
/// `WxMpKfList.fromJson` / `WxMpKfOnlineList.fromJson`。
fn parseKfList(gpa: std.mem.Allocator, root: json_util.Value, key: []const u8) ![]KfInfo {
    const arr = json_util.getArray(root, key) orelse return &[_]KfInfo{};
    var list: std.ArrayList(KfInfo) = .empty;
    errdefer {
        for (list.items) |*k| {
            var tmp = k.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    for (arr.items) |item| try list.append(gpa, try KfInfo.fromJson(gpa, item));
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig 同构)
// ---------------------------------------------------------------------------

fn apiUri(gpa: std.mem.Allocator, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

fn apiGet(svc: *service_mod.Service, io: std.Io, path: []const u8, qs: []const service_mod.Query) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.get(io, uri, qs);
}

fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc.gpa, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode(errcode!=0 已在 `Service.executeInternal` 折叠为 .err)。
fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

pub const KefuService = struct {
    svc: *service_mod.Service,

    /// 对应 `WxMpKefuServiceImpl#sendKefuMessage`:
    /// POST cgi-bin/message/custom/send(响应仅 errcode/errmsg,成功即完成)。
    pub fn send(self: *KefuService, io: std.Io, msg: KefuMessage) Done {
        const gpa = self.svc.gpa;
        const body = messageToJson(gpa, msg) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build kefu send body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.custom_send, body);
    }

    /// 对应 `WxMpKefuServiceImpl#kfAccountAdd`:
    /// POST customservice/kfaccount/add {kf_account,nickname[,invite_wx]}。
    pub fn kfAccountAdd(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = accountReqToJson(gpa, req) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build kfaccount add body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.kfaccount_add, body);
    }

    /// 对应 `WxMpKefuServiceImpl#kfList`:
    /// GET cgi-bin/customservice/getkflist → kf_list[]。
    /// 所有权:切片逐元素 deinit;`len != 0` 时由调用方 `free` 切片本身。
    pub fn kfAccountList(self: *KefuService, io: std.Io) WxResult([]KfInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, Path.get_kf_list, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "getkflist not json", .{}),
        };
        defer parsed.deinit();
        const list = parseKfList(gpa, parsed.value, "kf_list") catch
            return .{ .err = result_mod.WxError.internal(gpa, "parse kf_list failed", .{}) };
        return .{ .ok = list };
    }

    /// 对应 `WxMpKefuServiceImpl#kfOnlineList`:
    /// GET cgi-bin/customservice/getonlinekflist → kf_online_list[]。
    /// 所有权同 `kfAccountList`。
    pub fn getOnlineKfs(self: *KefuService, io: std.Io) WxResult([]KfInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, Path.get_online_kf_list, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "getonlinekflist not json", .{}),
        };
        defer parsed.deinit();
        const list = parseKfList(gpa, parsed.value, "kf_online_list") catch
            return .{ .err = result_mod.WxError.internal(gpa, "parse kf_online_list failed", .{}) };
        return .{ .ok = list };
    }

    /// 对应 `WxMpKefuServiceImpl#kfAccountDel`:
    /// GET customservice/kfaccount/del?kf_account=...(Java 用 String.format 拼 '%s',
    /// 此处用 Query 参数,由 `buildUrl` 百分号编码)。
    pub fn kfAccountDel(self: *KefuService, io: std.Io, kf_account: []const u8) Done {
        const qs = [_]service_mod.Query{.{ .key = "kf_account", .value = kf_account }};
        const resp = switch (apiGet(self.svc, io, Path.kfaccount_del, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        self.svc.gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 设置客服昵称(任务清单 update_kf_nickname)。
    /// 本 checkout Java 无对应 Impl 方法(仅 `KFACCOUNT_UPDATE` 常量),
    /// URL/请求体按微信官方文档:POST customservice/kfaccount/updnkfnickname
    /// {kf_account, nickname}。
    pub fn updateKfNickname(self: *KefuService, io: std.Io, kf_account: []const u8, nickname: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = accountReqToJson(gpa, .{ .kf_account = kf_account, .nickname = nickname }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "build updnickname body", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.kfaccount_updnickname, body);
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

/// 统一搭建测试环境(out 参数写回,避免 `Service` 里保存的 config 指针悬垂)。
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

test "kefu send: text/news 请求体结构 + errcode!=0" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/custom/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };

    // text
    switch (svc.send(threaded.io(), .{ .to_user = "oABC", .content = .{ .text = "你好" } })) {
        .ok => {},
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

    // news(articles 数组)
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/message/custom/send") != null);
    const nb = messageToJson(gpa, .{ .to_user = "oX", .content = .{ .news = &.{
        .{ .title = "t1", .description = "d1", .url = "http://u1", .picurl = "http://p1" },
        .{ .title = "t2", .description = "d2", .url = "http://u2", .picurl = "http://p2" },
    } } }) catch return error.Unexpected;
    defer gpa.free(nb);
    try testing.expect(std.mem.indexOf(u8, nb, "\"msgtype\":\"news\"") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "\"news\":{\"articles\":[") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "{\"title\":\"t1\",\"description\":\"d1\",\"url\":\"http://u1\",\"picurl\":\"http://p1\"}") != null);
    try testing.expect(std.mem.indexOf(u8, nb, "\"picurl\":\"http://p2\"}") != null);

    // image / voice / video 的 toJson 形状(对齐 WxMpKefuMessageGsonAdapter)
    const ib = messageToJson(gpa, .{ .to_user = "o", .content = .{ .image = "MID" } }) catch return error.Unexpected;
    defer gpa.free(ib);
    try testing.expect(std.mem.indexOf(u8, ib, "\"msgtype\":\"image\",\"image\":{\"media_id\":\"MID\"}") != null);
    const vb = messageToJson(gpa, .{ .to_user = "o", .content = .{ .video = .{
        .media_id = "M",
        .thumb_media_id = "T",
        .title = "tt",
        .description = "dd",
    } } }) catch return error.Unexpected;
    defer gpa.free(vb);
    try testing.expect(std.mem.indexOf(u8, vb, "\"video\":{\"media_id\":\"M\",\"thumb_media_id\":\"T\",\"title\":\"tt\",\"description\":\"dd\"}") != null);

    // 失败路径:errcode=45015(非 token 类,不触发自动刷新重试)
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "message/custom/send", .response = "{\"errcode\":45015,\"errmsg\":\"reply out of time limit or subscription is expired\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = KefuService{ .svc = &base2 };
    switch (svc2.send(th2.io(), .{ .to_user = "o", .content = .{ .text = "x" } })) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 45015), err.error_code);
        },
    }
}

test "kefu kf account: list / online / add / del / updnickname" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getkflist", .response = "{\"errcode\":0,\"kf_list\":[{\"kf_account\":\"a1@test\",\"kf_nick\":\"n1\",\"kf_id\":\"1\",\"kf_headimgurl\":\"http://h1\"},{\"kf_account\":\"a2@test\",\"kf_nick\":\"n2\"}]}" },
        .{ .match = "getonlinekflist", .response = "{\"errcode\":0,\"kf_online_list\":[{\"kf_account\":\"a1@test\",\"kf_id\":\"1\",\"status\":1,\"accepted_case\":2}]}" },
        .{ .match = "kfaccount/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfaccount/del", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "kfaccount/updnkfnickname", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = KefuService{ .svc = &base };
    const io = threaded.io();

    // kfAccountList
    switch (svc.kfAccountList(io)) {
        .ok => |list| {
            defer if (list.len != 0) gpa.free(list);
            try testing.expectEqual(@as(usize, 2), list.len);
            var k0 = list[0];
            defer k0.deinit();
            try testing.expectEqualStrings("a1@test", k0.account);
            try testing.expectEqualStrings("n1", k0.nick.?);
            try testing.expectEqualStrings("1", k0.id.?);
            try testing.expectEqualStrings("http://h1", k0.head_img_url.?);
            var k1 = list[1];
            defer k1.deinit();
            try testing.expect(k1.head_img_url == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/customservice/getkflist") != null);

    // getOnlineKfs(status/accepted_case)
    switch (svc.getOnlineKfs(io)) {
        .ok => |list| {
            defer if (list.len != 0) gpa.free(list);
            try testing.expectEqual(@as(usize, 1), list.len);
            var k = list[0];
            defer k.deinit();
            try testing.expectEqual(@as(?i64, 1), k.status);
            try testing.expectEqual(@as(?i64, 2), k.accepted_case);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/customservice/getonlinekflist") != null);

    // kfAccountAdd(带 invite_wx)
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

    // kfAccountDel(GET + query,值百分号编码 '@'→%40)
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

    // updateKfNickname
    switch (svc.updateKfNickname(io, "a1@test", "新昵称")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "customservice/kfaccount/updnkfnickname") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"nickname\":\"新昵称\"") != null);
    // 不带 invite_wx(Gson null 省略)
    try testing.expect(std.mem.indexOf(u8, mock.body(), "invite_wx") == null);

    // 失败路径:errcode=48001
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "kfaccount/add", .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
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
