//! 临时素材 + 新增永久图文素材服务 —— 对应微信公众平台「素材管理」接口。
//!
//! 收录:临时素材(media/upload | media/get | media/uploadimg)与新增永久图文
//! 素材(material/add_news)。multipart 组包复用 `material.zig` 的公开纯函数
//! `buildMultipartBody` / `multipartContentType`(字段名 `media`、Content-Type、
//! 边界格式逐字一致),不重复实现,与永久素材上传走同一条链路。
//!
//! URL 以微信公众平台官方文档为准(路径由 `api_host_url` 拼前缀):
//! - 新增临时素材   POST cgi-bin/media/upload?type=<type>  (multipart 字段 media)
//! - 获取临时素材   GET  cgi-bin/media/get?media_id=<id>   (二进制流 或 JSON 错误)
//! - 上传图文正文图 POST cgi-bin/media/uploadimg            (multipart,返回 url)
//! - 新增永久图文   POST cgi-bin/material/add_news          (JSON: articles[])
//! 注:`get_materialcount` / `batchget_material` 已在 `material.zig` 实现
//! (`count` / `batchget`),本文件不重复收录。
const std = @import("std");
const testing = std.testing;

const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const random_mod = @import("common").random;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const token_mod = @import("common").token;

const config_mod = @import("../config.zig");
const http_mod = @import("../http.zig");
const service_mod = @import("../service.zig");
const material = @import("material.zig");

/// URL 常量表(路径部分;由 `api_host_url` 拼前缀)。
pub const Path = struct {
    pub const media_upload = "cgi-bin/media/upload";
    pub const media_get = "cgi-bin/media/get";
    pub const media_uploadimg = "cgi-bin/media/uploadimg";
    pub const add_news = "cgi-bin/material/add_news";
};

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 新增临时素材结果 —— {type, media_id, created_at}。
pub const MediaUploadResult = struct {
    gpa: std.mem.Allocator,
    mtype: []u8,
    media_id: []u8,
    created_at: i64 = 0,

    pub fn deinit(self: *MediaUploadResult) void {
        self.gpa.free(self.mtype);
        self.gpa.free(self.media_id);
        self.* = undefined;
    }
};

/// 图文正文图片上传结果 —— {url}(不是 media_id)。
pub const UploadImgResult = struct {
    gpa: std.mem.Allocator,
    url: []u8,

    pub fn deinit(self: *UploadImgResult) void {
        self.gpa.free(self.url);
        self.* = undefined;
    }
};

/// 新增永久图文素材结果 —— {media_id}。
pub const AddNewsResult = struct {
    gpa: std.mem.Allocator,
    media_id: []u8,

    pub fn deinit(self: *AddNewsResult) void {
        self.gpa.free(self.media_id);
        self.* = undefined;
    }
};

/// 新增永久图文素材的单篇文章 —— 对应 add_news 的 articles[] 元素。
/// 必填:title / thumb_media_id / content;其余按官方文档可选(null 省略)。
pub const NewsArticle = struct {
    title: []const u8,
    thumb_media_id: []const u8,
    content: []const u8,
    author: ?[]const u8 = null,
    digest: ?[]const u8 = null,
    content_source_url: ?[]const u8 = null,
    show_cover_pic: ?i64 = null,
    need_open_comment: ?i64 = null,
    only_fans_can_comment: ?i64 = null,
};

// ---------------------------------------------------------------------------
// 手写 JSON 转义(与 material.zig 的 jw 同法)
// ---------------------------------------------------------------------------

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// 拼 add_news 请求体:{"articles":[{title,thumb_media_id,content,...},...]}。
fn newsBody(gpa: std.mem.Allocator, articles: []const NewsArticle) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"articles\":[");
    for (articles, 0..) |a, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"title\":");
        try jw.str(w, a.title);
        try w.writeAll(",\"thumb_media_id\":");
        try jw.str(w, a.thumb_media_id);
        try w.writeAll(",\"content\":");
        try jw.str(w, a.content);
        if (a.author) |v| {
            try w.writeAll(",\"author\":");
            try jw.str(w, v);
        }
        if (a.digest) |v| {
            try w.writeAll(",\"digest\":");
            try jw.str(w, v);
        }
        if (a.content_source_url) |v| {
            try w.writeAll(",\"content_source_url\":");
            try jw.str(w, v);
        }
        if (a.show_cover_pic) |v| try w.print(",\"show_cover_pic\":{d}", .{v});
        if (a.need_open_comment) |v| try w.print(",\"need_open_comment\":{d}", .{v});
        if (a.only_fans_can_comment) |v| try w.print(",\"only_fans_can_comment\":{d}", .{v});
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig / material.zig 同构)
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

/// 仅当 body 是带非零 errcode 的 JSON 报文时折叠为 WxError;否则返回 null
/// (即二进制媒体流 / 成功的 JSON,按原始字节透传)。
fn wxErrorFromBody(gpa: std.mem.Allocator, body: []const u8) ?result_mod.WxError {
    const parsed = json_util.parse(gpa, body) catch return null;
    defer parsed.deinit();
    const code = json_util.getInt(parsed.value, "errcode") orelse return null;
    if (code == 0) return null;
    return result_mod.WxError.fromJson(gpa, body, .mp) catch return null;
}

pub const MediaService = struct {
    svc: *service_mod.Service,

    /// 对应「新增临时素材」:POST cgi-bin/media/upload?type=<mtype> + multipart,
    /// 表单字段 `media`。组包/Content-Type 复用 `material.zig`,与永久素材
    /// `add` 完全一致。成功返回 {type,media_id,created_at}(gpa 拥有,deinit)。
    pub fn mediaUpload(self: *MediaService, io: std.Io, mtype: []const u8, filename: []const u8, content: []const u8) WxResult(MediaUploadResult) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?type={s}", .{ service_mod.api_host_url, Path.media_upload, mtype }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const resp = switch (uploadMultipart(self, io, uri, filename, content)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "media/upload response not json", .{}) };
        defer parsed.deinit();
        const mid = json_util.getStr(parsed.value, "media_id") orelse
            return .{ .err = result_mod.WxError.transport(gpa, "media/upload response missing media_id", .{}) };
        const mid_c = gpa.dupe(u8, mid) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        errdefer gpa.free(mid_c);
        const typ_c = gpa.dupe(u8, json_util.getStrOr(parsed.value, "type", mtype)) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .mtype = typ_c,
            .media_id = mid_c,
            .created_at = json_util.getIntOr(parsed.value, "created_at", 0),
        } };
    }

    /// 对应「获取临时素材」:GET cgi-bin/media/get?media_id=<id>。
    /// 响应**可能是二进制媒体流,也可能是 JSON 错误报文**:
    ///  - errcode!=0 的 JSON 错误已在 `Service.executeInternal` 折叠为 `.err`;
    ///  - 此处再兜底一次(`wxErrorFromBody`),避免个别执行器未折叠;
    ///  - 其余(二进制流)按**原始字节透传**。
    /// 所有权:`.ok` 切片由 gpa 分配,调用方用毕 `free`。
    pub fn mediaGet(self: *MediaService, io: std.Io, media_id: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const qs = [_]service_mod.Query{.{ .key = "media_id", .value = media_id }};
        const resp = switch (apiGet(self.svc, io, Path.media_get, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        if (wxErrorFromBody(gpa, resp)) |we| {
            gpa.free(resp);
            return .{ .err = we };
        }
        return .{ .ok = resp };
    }

    /// 对应「上传图文消息内的图片」:POST cgi-bin/media/uploadimg + multipart,
    /// 返回 `url`(用于图文正文,不是 media_id)。
    pub fn mediaUploadImg(self: *MediaService, io: std.Io, filename: []const u8, content: []const u8) WxResult(UploadImgResult) {
        const gpa = self.svc.gpa;
        const uri = switch (apiUri(gpa, Path.media_uploadimg)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(uri);

        const resp = switch (uploadMultipart(self, io, uri, filename, content)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "media/uploadimg response not json", .{}) };
        defer parsed.deinit();
        const url = json_util.getStrOr(parsed.value, "url", "");
        const url_c = gpa.dupe(u8, url) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .url = url_c } };
    }

    /// 对应「新增永久图文素材」:POST cgi-bin/material/add_news
    /// {"articles":[...]} → {media_id}。
    pub fn addNews(self: *MediaService, io: std.Io, articles: []const NewsArticle) WxResult(AddNewsResult) {
        const gpa = self.svc.gpa;
        const body = newsBody(gpa, articles) catch |e| return .{
            .err = result_mod.WxError.internal(gpa, "build add_news body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (apiPost(self.svc, io, Path.add_news, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "add_news response not json", .{}) };
        defer parsed.deinit();
        const mid = json_util.getStr(parsed.value, "media_id") orelse
            return .{ .err = result_mod.WxError.transport(gpa, "add_news response missing media_id", .{}) };
        return .{ .ok = .{ .gpa = gpa, .media_id = gpa.dupe(u8, mid) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } } };
    }

    /// multipart POST 的公共部分:随机 boundary → 组包 → Content-Type 请求头 →
    /// `Service.postWithHeaders`(与 `material.zig#addParts` 逐字同构)。
    fn uploadMultipart(self: *MediaService, io: std.Io, uri: []const u8, filename: []const u8, content: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = result_mod.WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(boundary);

        const body = material.buildMultipartBody(gpa, boundary, filename, content, null) catch |e|
            return .{ .err = result_mod.WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);

        const ct = material.multipartContentType(gpa, boundary) catch
            return .{ .err = result_mod.WxError.internal(gpa, "multipart content-type", .{}) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{
            .{ .name = "Content-Type", .value = ct },
        };
        return self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers);
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 material.zig / template_msg.zig 的 Recorder)
// ---------------------------------------------------------------------------

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

test "media upload: multipart 组包 + type/media_id/created_at 解析" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "media/upload?type=", .response = "{\"type\":\"image\",\"media_id\":\"MEDIA1\",\"created_at\":1700000000}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MediaService{ .svc = &base };

    switch (svc.mediaUpload(threaded.io(), "image", "a.png", "PNGDATA")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("image", res.mtype);
            try testing.expectEqualStrings("MEDIA1", res.media_id);
            try testing.expectEqual(@as(i64, 1700000000), res.created_at);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/upload?type=image") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    // multipart 结构(字段名 media / octet-stream / 文件名 / 内容 / 结束边界)
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "Content-Disposition: form-data; name=\"media\"; filename=\"a.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "Content-Type: application/octet-stream") != null);
    try testing.expect(std.mem.indexOf(u8, b, "PNGDATA") != null);
    try testing.expect(std.mem.endsWith(u8, b, "--\r\n"));
}

test "media get: 二进制透传 + JSON 错误折叠为 .err" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "media/get", .response = "FAKE_BINARY_BYTES" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MediaService{ .svc = &base };
    const io = threaded.io();

    // 二进制流:原样透传(调用方 free)
    switch (svc.mediaGet(io, "MID123")) {
        .ok => |bytes| {
            defer gpa.free(bytes);
            try testing.expectEqualStrings("FAKE_BINARY_BYTES", bytes);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "media_id=MID123") != null);

    // JSON 错误报文(errcode!=0) -> 折叠为 .err,不当二进制交付
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "media/get", .response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = MediaService{ .svc = &base2 };
    switch (svc2.mediaGet(th2.io(), "BAD")) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40007), err.error_code);
        },
    }
}

test "media uploadimg / add_news: url 与 media_id 解析 + 请求体" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "media/uploadimg", .response = "{\"url\":\"http://mmbiz.qpic.cn/x\"}" },
        .{ .match = "material/add_news", .response = "{\"media_id\":\"NEWS_MEDIA1\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MediaService{ .svc = &base };
    const io = threaded.io();

    // uploadimg:返回 url,不是 media_id
    switch (svc.mediaUploadImg(io, "in.png", "PNGDATA")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("http://mmbiz.qpic.cn/x", res.url);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/uploadimg") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "name=\"media\"") != null);

    // add_news:{"articles":[...]} + media_id
    switch (svc.addNews(io, &.{
        .{
            .title = "标题",
            .thumb_media_id = "THUMB1",
            .content = "<p>正文</p>",
            .author = "作者",
            .show_cover_pic = 1,
        },
    })) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("NEWS_MEDIA1", res.media_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/material/add_news") != null);
    const body = mock.body();
    try testing.expect(std.mem.indexOf(u8, body, "\"articles\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"title\":\"标题\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"thumb_media_id\":\"THUMB1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"<p>正文</p>\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"author\":\"作者\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"show_cover_pic\":1") != null);
}

test "media errcode!=0 折叠为 .err(media/upload)" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "media/upload?type=", .response = "{\"errcode\":40004,\"errmsg\":\"invalid media type\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MediaService{ .svc = &base };
    switch (svc.mediaUpload(threaded.io(), "image", "a.png", "X")) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40004), err.error_code);
        },
    }
}
