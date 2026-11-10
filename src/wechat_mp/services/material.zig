//! 永久素材服务 —— 对应 Java `api.WxMpMaterialService` + `api.impl.WxMpMaterialServiceImpl`。
//!
//! URL 以 Java `enums.WxMpApiUrl.Material` 常量为准。
//! 上传类接口(`materialFileUpload` 等)在 Java 走 `MaterialUploadRequestExecutor`
//! 的 multipart/form-data;本骨架用**纯本地组包**(boundary + parts 拼 body)+
//! 现有 RequestExecutor 字节流通道实现,组包是纯逻辑、可离线单测,不引入 HTTP 栈。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const random_mod = @import("common").random;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// URL 常量表 —— 对应 Java `WxMpApiUrl.Material`。
pub const Path = struct {
    /// `MATERIAL_GET_COUNT_URL`:素材总数。
    pub const get_materialcount = "cgi-bin/material/get_materialcount";
    /// `MATERIAL_BATCHGET_URL`:素材列表。
    pub const batchget_material = "cgi-bin/material/batchget_material";
    /// `MATERIAL_GET_URL`:获取永久素材。
    pub const get_material = "cgi-bin/material/get_material";
    /// `MATERIAL_DEL_URL`:删除永久素材。
    pub const del_material = "cgi-bin/material/del_material";
    /// `MATERIAL_ADD_URL`:新增永久素材(multipart,`?type=%s`,未实现)。
    pub const add_material = "cgi-bin/material/add_material";
};

// ---------------------------------------------------------------------------
// 结果结构 —— 对应 `bean.material.WxMpMaterialCountResult` /
// `WxMpMaterialFileBatchGetResult`(item 取 name/update_time/url/media_id)。
// ---------------------------------------------------------------------------

/// 素材总数 —— 对应 `WxMpMaterialCountResult`。
pub const MaterialCount = struct {
    /// video_count
    video_count: i64 = 0,
    /// voice_count
    voice_count: i64 = 0,
    /// image_count
    image_count: i64 = 0,
    /// news_count
    news_count: i64 = 0,

    fn fromJson(v: json_util.Value) MaterialCount {
        return .{
            .video_count = json_util.getIntOr(v, "video_count", 0),
            .voice_count = json_util.getIntOr(v, "voice_count", 0),
            .image_count = json_util.getIntOr(v, "image_count", 0),
            .news_count = json_util.getIntOr(v, "news_count", 0),
        };
    }
};

/// batchget 单条素材 —— 对应 `WxMaterialFileBatchGetNewsItem`
/// (mediaId/updateTime/name/url;news 类型的 content 不在此收录,见 get)。
pub const BatchItem = struct {
    gpa: std.mem.Allocator,
    media_id: []const u8 = "",
    name: []const u8 = "",
    url: ?[]const u8 = null,
    update_time: i64 = 0,

    pub fn deinit(self: *BatchItem) void {
        const g = self.gpa;
        if (self.media_id.len != 0) g.free(@constCast(self.media_id));
        if (self.name.len != 0) g.free(@constCast(self.name));
        if (self.url) |u| g.free(@constCast(u));
    }

    fn dupe(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
        const s = json_util.getStr(v, key) orelse return null;
        return try gpa.dupe(u8, s);
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !BatchItem {
        return .{
            .gpa = gpa,
            .media_id = (try dupe(gpa, v, "media_id")) orelse "",
            .name = (try dupe(gpa, v, "name")) orelse "",
            .url = try dupe(gpa, v, "url"),
            .update_time = json_util.getInt(v, "update_time") orelse 0,
        };
    }
};

/// batchget 结果 —— 对应 `WxMpMaterialFileBatchGetResult`
/// (totalCount/itemCount/items ← total_count/item_count/item[])。
pub const BatchGetResult = struct {
    gpa: std.mem.Allocator,
    total_count: i64 = 0,
    item_count: i64 = 0,
    items: []BatchItem = &.{},

    /// 所有权:逐元素 deinit;`items.len != 0` 时由调用方 `free` 切片本身。
    pub fn deinit(self: *BatchGetResult) void {
        for (self.items) |*it| {
            var tmp = it.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
    }
};

/// 手写 JSON 转义写串(与 `user_tag.zig` 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

fn mediaIdBody(gpa: std.mem.Allocator, media_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("{\"media_id\":");
    try jw.str(&out.writer, media_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// api 辅助(与 template_msg.zig 同构)
// ---------------------------------------------------------------------------

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

fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

pub const MaterialService = struct {
    svc: *service_mod.Service,

    /// 对应 `WxMpMaterialServiceImpl#materialCount`:
    /// GET cgi-bin/material/get_materialcount → {video_count,voice_count,image_count,news_count}。
    pub fn count(self: *MaterialService, io: std.Io) WxResult(MaterialCount) {
        const gpa = self.svc.gpa;
        const resp = switch (apiGet(self.svc, io, Path.get_materialcount)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "get_materialcount not json", .{}),
        };
        defer parsed.deinit();
        return .{ .ok = MaterialCount.fromJson(parsed.value) };
    }

    /// 对应 `WxMpMaterialServiceImpl#materialFileBatchGet`(news 走同参数,Java 的
    /// `materialNewsBatchGet` 只是 type="news" 的特化):
    /// POST cgi-bin/material/batchget_material {type,offset,count}
    /// → {total_count,item_count,item[]}。
    pub fn batchget(self: *MaterialService, io: std.Io, mtype: []const u8, offset: i64, cnt: i64) WxResult(BatchGetResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        const body = build: {
            ob.putStr("type", mtype) catch break :build null;
            ob.putInt("offset", offset) catch break :build null;
            ob.putInt("count", cnt) catch break :build null;
            break :build ob.toJson() catch null;
        } orelse return .{ .err = result_mod.WxError.internal(gpa, "build batchget body", .{}) };
        defer gpa.free(body);

        const resp = switch (apiPost(self.svc, io, Path.batchget_material, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "batchget_material not json", .{}),
        };
        defer parsed.deinit();

        var res = BatchGetResult{ .gpa = gpa };
        errdefer res.deinit();
        res.total_count = json_util.getIntOr(parsed.value, "total_count", 0);
        res.item_count = json_util.getIntOr(parsed.value, "item_count", 0);
        var list: std.ArrayList(BatchItem) = .empty;
        errdefer list.deinit(gpa);
        if (json_util.getArray(parsed.value, "item")) |arr| {
            for (arr.items) |item| list.append(gpa, BatchItem.fromJson(gpa, item) catch
                return .{ .err = result_mod.WxError.transport(gpa, "batchget item parse failed", .{}) }) catch
                return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        }
        res.items = list.toOwnedSlice(gpa) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = res };
    }

    /// 对应 `WxMpMaterialServiceImpl#materialImageOrVoiceDownload` /
    /// `materialVideoInfo` / `materialNewsInfo`(三者同打 MATERIAL_GET_URL):
    /// POST cgi-bin/material/get_material {media_id}。
    /// Java 按类型分派 executor:新闻(news)返回 JSON、图片/语音返回二进制流,
    /// 这里统一**原样透传响应字节**,由调用方按内容判断(JSON 或媒体流)。
    /// errcode!=0 的错误 JSON 已在 `Service.executeInternal` 折叠为 .err。
    /// 所有权:返回切片由 gpa 分配,调用方用毕 `free`。
    pub fn get(self: *MaterialService, io: std.Io, media_id: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = mediaIdBody(gpa, media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return apiPost(self.svc, io, Path.get_material, body);
    }

    /// 对应 `WxMpMaterialServiceImpl#materialDelete`:
    /// POST cgi-bin/material/del_material {media_id}。
    pub fn delete(self: *MaterialService, io: std.Io, media_id: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = mediaIdBody(gpa, media_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self.svc, io, Path.del_material, body);
    }

    /// 新增永久素材结果 —— 对应 `WxMpMaterialUploadResult`(mediaId / url)。
    pub const AddResult = struct {
        gpa: std.mem.Allocator,
        media_id: []u8,
        url: []u8,

        pub fn deinit(self: *AddResult) void {
            self.gpa.free(self.media_id);
            self.gpa.free(self.url);
            self.* = undefined;
        }
    };

    /// 对应 `WxMpMaterialServiceImpl#materialFileUpload`:
    /// POST `cgi-bin/material/add_material?type=<mtype>` + multipart/form-data。
    /// 纯本地组包(`buildMultipartBody`)+ 现有 RequestExecutor 字节流通道(svc.post),
    /// 不引入 HTTP 栈。视频素材用 `addVideo` 附带 description 表单字段。
    ///
    /// `Content-Type: multipart/form-data; boundary=...` 现经
    /// `Service.postWithHeaders` 交给 `execute_with_headers` 槽(真实 std.http
    /// 执行器会作为 `extra_headers` 发出);未实现该槽的 mock 由 wrapper 回退、
    /// 忽略请求头,离线单测照常。body 组包与头值均离线可测,真网络上传仍需真凭证。
    pub fn add(self: *MaterialService, io: std.Io, mtype: []const u8, filename: []const u8, content: []const u8) WxResult(AddResult) {
        return self.addParts(io, mtype, filename, content, null);
    }

    /// 视频素材上传(对应 `WxMpMaterial` 的 getForm() -> description 表单 JSON)。
    pub fn addVideo(self: *MaterialService, io: std.Io, filename: []const u8, content: []const u8, description_json: []const u8) WxResult(AddResult) {
        return self.addParts(io, "video", filename, content, description_json);
    }

    fn addParts(self: *MaterialService, io: std.Io, mtype: []const u8, filename: []const u8, content: []const u8, description: ?[]const u8) WxResult(AddResult) {
        const gpa = self.svc.gpa;
        // boundary:随机字母数字(Java MultipartBody / MultipartEntityBuilder 同用随机串)
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = result_mod.WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(boundary);

        const body = buildMultipartBody(gpa, boundary, filename, content, description) catch |e|
            return .{ .err = result_mod.WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);

        // WxMpApiUrl.Material.MATERIAL_ADD_URL = "/cgi-bin/material/add_material?type=%s"
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?type={s}", .{ service_mod.api_host_url, Path.add_material, mtype }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        // multipart 的 Content-Type 请求头(对应 Java MaterialUploadRequestExecutor)。
        // 经 Service.postWithHeaders -> execute_with_headers 槽发出;mock 回退时忽略。
        const ct = multipartContentType(gpa, boundary) catch |e|
            return .{ .err = result_mod.WxError.internal(gpa, "multipart content-type: {s}", .{@errorName(e)}) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{
            .{ .name = "Content-Type", .value = ct },
        };

        const resp = switch (self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "add_material response not json", .{}) };
        defer parsed.deinit();
        const mid = json_util.getStr(parsed.value, "media_id") orelse
            return .{ .err = result_mod.WxError.transport(gpa, "add_material response missing media_id", .{}) };
        const url = json_util.getStr(parsed.value, "url") orelse "";
        const mid_c = gpa.dupe(u8, mid) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        errdefer gpa.free(mid_c);
        const url_c = gpa.dupe(u8, url) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .media_id = mid_c, .url = url_c } };
    }
};

// ---------------------------------------------------------------------------
// multipart/form-data 纯本地组包(对应 Java `MaterialUploadRequestExecutor` /
// `MaterialUploadApacheHttpRequestExecutor` 的字段名与组包格式)。
// ---------------------------------------------------------------------------

/// multipart 请求头 Content-Type 值(header-capable 执行器使用)。纯函数、离线可测。
pub fn multipartContentType(gpa: std.mem.Allocator, boundary: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "multipart/form-data; boundary={s}", .{boundary});
}

/// 禁止 CRLF / 引号,防止头注入(boundary 与 filename 都进头行)。
fn hasHeaderInjection(s: []const u8) bool {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == '"') return true;
    }
    return false;
}

/// 拼 multipart/form-data body(纯逻辑、可离线单测)。字段名/格式逐字对照 Java:
///  - `media` 部分:name="media"; filename="<filename>",Content-Type: application/octet-stream,
///    文件二进制(对应 OkHttp `addFormDataPart("media", name, octet-stream)` /
///    Apache `addBinaryBody("media", file)`)。
///  - `description` 部分(视频,可选):name="description",
///    Content-Type: text/plain; charset=UTF-8,内容 = 表单 JSON
///    (对应 Apache `new StringBody(json, TEXT_PLAIN.withCharset(UTF_8))`)。
///  - 各部分以 `--<boundary>\r\n` 分隔,末行 `--<boundary>--\r\n`。
pub fn buildMultipartBody(
    gpa: std.mem.Allocator,
    boundary: []const u8,
    filename: []const u8,
    content: []const u8,
    description: ?[]const u8,
) ![]u8 {
    if (boundary.len == 0 or hasHeaderInjection(boundary)) return error.InvalidBoundary;
    if (hasHeaderInjection(filename)) return error.InvalidFilename;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // -- media 部分 --
    try out.appendSlice(gpa, "--");
    try out.appendSlice(gpa, boundary);
    try out.appendSlice(gpa, "\r\n");
    try out.appendSlice(gpa, "Content-Disposition: form-data; name=\"media\"; filename=\"");
    try out.appendSlice(gpa, filename);
    try out.appendSlice(gpa, "\"\r\n");
    try out.appendSlice(gpa, "Content-Type: application/octet-stream\r\n\r\n");
    try out.appendSlice(gpa, content);
    try out.appendSlice(gpa, "\r\n");

    // -- description 部分(视频表单,可选)--
    if (description) |d| {
        try out.appendSlice(gpa, "--");
        try out.appendSlice(gpa, boundary);
        try out.appendSlice(gpa, "\r\n");
        try out.appendSlice(gpa, "Content-Disposition: form-data; name=\"description\"\r\n");
        try out.appendSlice(gpa, "Content-Type: text/plain; charset=UTF-8\r\n\r\n");
        try out.appendSlice(gpa, d);
        try out.appendSlice(gpa, "\r\n");
    }

    // -- 结束边界 --
    try out.appendSlice(gpa, "--");
    try out.appendSlice(gpa, boundary);
    try out.appendSlice(gpa, "--\r\n");
    return out.toOwnedSlice(gpa);
}

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

test "material count / batchget: 请求体 + 解析" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "get_materialcount", .response = "{\"video_count\":2,\"voice_count\":1,\"image_count\":5,\"news_count\":3}" },
        .{ .match = "batchget_material", .response = "{\"total_count\":4,\"item_count\":2,\"item\":[{\"media_id\":\"M1\",\"update_time\":1700000000,\"name\":\"图片一\",\"url\":\"http://u1\"},{\"media_id\":\"M2\",\"update_time\":1700000001,\"name\":\"图片二\"}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MaterialService{ .svc = &base };
    const io = threaded.io();

    // count
    switch (svc.count(io)) {
        .ok => |c| {
            try testing.expectEqual(@as(i64, 2), c.video_count);
            try testing.expectEqual(@as(i64, 1), c.voice_count);
            try testing.expectEqual(@as(i64, 5), c.image_count);
            try testing.expectEqual(@as(i64, 3), c.news_count);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/material/get_materialcount") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

    // batchget
    switch (svc.batchget(io, "image", 0, 2)) {
        .ok => |*v| {
            var res = v.*;
            defer res.deinit();
            try testing.expectEqual(@as(i64, 4), res.total_count);
            try testing.expectEqual(@as(i64, 2), res.item_count);
            try testing.expectEqual(@as(usize, 2), res.items.len);
            try testing.expectEqualStrings("M1", res.items[0].media_id);
            try testing.expectEqualStrings("图片一", res.items[0].name);
            try testing.expectEqualStrings("http://u1", res.items[0].url.?);
            try testing.expectEqual(@as(i64, 1700000000), res.items[0].update_time);
            try testing.expect(res.items[1].url == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/material/batchget_material") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"type\":\"image\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"offset\":0") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"count\":2") != null);
}

test "material get / delete / add 未实现 / errcode!=0" {
    const gpa = testing.allocator;
    var mock = Recorder{
        .gpa = gpa,
        .entries = &.{
            // 图片/语音素材:微信返回原始二进制流(非 JSON),按透传处理
            .{ .match = "get_material", .response = "FAKE_BINARY_BYTES" },
            .{ .match = "del_material", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        },
    };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = MaterialService{ .svc = &base };
    const io = threaded.io();

    // get:非 JSON 流透传(Java 对新闻返回 json / 其他返回流,此处统一原始字节)
    switch (svc.get(io, "MID123")) {
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
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/material/get_material") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"MID123\"") != null);

    // delete
    switch (svc.delete(io, "MID123")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/material/del_material") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"MID123\"") != null);

    // add:multipart 组包后走现有字节流通道(单独 mock,返回 add_material 应答)
    var mockAdd = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "add_material", .response = "{\"media_id\":\"MEDIA1\",\"url\":\"http://u\"}" },
    } };
    var thAdd: std.Io.Threaded = undefined;
    var cfgAdd: config_mod.InMemoryConfigStorage = undefined;
    var baseAdd: service_mod.Service = undefined;
    try setup(gpa, &mockAdd, &thAdd, &cfgAdd, &baseAdd);
    defer thAdd.deinit();
    defer cfgAdd.deinit();
    var svcAdd = MaterialService{ .svc = &baseAdd };
    switch (svcAdd.add(thAdd.io(), "image", "a.png", "PNGDATA")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("MEDIA1", res.media_id);
            try testing.expectEqualStrings("http://u", res.url);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAddError;
        },
    }
    // URL:add_material?type=image + access_token
    try testing.expect(std.mem.indexOf(u8, mockAdd.uri(), "cgi-bin/material/add_material?type=image") != null);
    try testing.expect(std.mem.indexOf(u8, mockAdd.uri(), "access_token=TOK") != null);
    // body:multipart 结构(字段名 media / filename / octet-stream / 内容 / 结束边界)
    const mp = mockAdd.body();
    try testing.expect(std.mem.indexOf(u8, mp, "Content-Disposition: form-data; name=\"media\"; filename=\"a.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, mp, "Content-Type: application/octet-stream") != null);
    try testing.expect(std.mem.indexOf(u8, mp, "PNGDATA") != null);
    try testing.expect(std.mem.indexOf(u8, mp, "--\r\n") != null); // 结束边界后缀

    // 失败路径:del errcode=40007(不合法的媒体文件 id)
    var mock2 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "del_material", .response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}" },
    } };
    var th2: std.Io.Threaded = undefined;
    var cfg2: config_mod.InMemoryConfigStorage = undefined;
    var base2: service_mod.Service = undefined;
    try setup(gpa, &mock2, &th2, &cfg2, &base2);
    defer th2.deinit();
    defer cfg2.deinit();
    var svc2 = MaterialService{ .svc = &base2 };
    switch (svc2.delete(th2.io(), "BAD")) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40007), err.error_code);
        },
    }

    // 失败路径:count errcode=48001
    var mock3 = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "get_materialcount", .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" },
    } };
    var th3: std.Io.Threaded = undefined;
    var cfg3: config_mod.InMemoryConfigStorage = undefined;
    var base3: service_mod.Service = undefined;
    try setup(gpa, &mock3, &th3, &cfg3, &base3);
    defer th3.deinit();
    defer cfg3.deinit();
    var svc3 = MaterialService{ .svc = &base3 };
    switch (svc3.count(th3.io())) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 48001), err.error_code);
        },
    }
}

// ---------------------------------------------------------------------------
// multipart 纯本地组包离线单测(字段名/格式逐字对照 Java 执行器)
// ---------------------------------------------------------------------------

test "buildMultipartBody: exact bytes, media + description, boundary; header injection rejected" {
    const gpa = testing.allocator;
    const body = try buildMultipartBody(gpa, "BOUND123", "pic.png", "\x89PNG\r\n", "{\"title\":\"t\"}");
    defer gpa.free(body);
    const expect =
        "--BOUND123\r\n" ++
        "Content-Disposition: form-data; name=\"media\"; filename=\"pic.png\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n" ++ // 原始二进制(故意含 \r\n,验证二进制按字节透传)
        "\r\n" ++
        "--BOUND123\r\n" ++
        "Content-Disposition: form-data; name=\"description\"\r\n" ++
        "Content-Type: text/plain; charset=UTF-8\r\n" ++
        "\r\n" ++
        "{\"title\":\"t\"}" ++
        "\r\n" ++
        "--BOUND123--\r\n";
    try testing.expectEqualStrings(expect, body);

    // 无 description 时不应出现该部分
    const body2 = try buildMultipartBody(gpa, "B", "f.bin", "XYZ", null);
    defer gpa.free(body2);
    try testing.expect(std.mem.indexOf(u8, body2, "name=\"description\"") == null);
    try testing.expect(std.mem.endsWith(u8, body2, "--B--\r\n"));

    // multipartContentType(供 header-capable 执行器使用)
    const ct = try multipartContentType(gpa, "BOUND123");
    defer gpa.free(ct);
    try testing.expectEqualStrings("multipart/form-data; boundary=BOUND123", ct);

    // 头注入防护:filename / boundary 含 CRLF 或引号 -> 拒绝(不生成非法头)
    try testing.expectError(error.InvalidFilename, buildMultipartBody(gpa, "B", "a\r\nb", "x", null));
    try testing.expectError(error.InvalidFilename, buildMultipartBody(gpa, "B", "a\"b", "x", null));
    try testing.expectError(error.InvalidBoundary, buildMultipartBody(gpa, "B\r\nX", "f", "x", null));
    try testing.expectError(error.InvalidBoundary, buildMultipartBody(gpa, "", "f", "x", null));
}

// ---------------------------------------------------------------------------
// multipart Content-Type 经 execute_with_headers 槽传递(离线单测)
// ---------------------------------------------------------------------------

/// 实现了 `execute_with_headers` 槽的 mock:捕获请求头,证明 multipart 的
/// Content-Type 真的从 Service 传到了 header-capable 执行器(而非被丢弃)。
const HeaderCapture = struct {
    gpa: std.mem.Allocator,
    response: []const u8,
    calls: usize = 0,
    captured_ct: []u8 = &.{},
    captured_body: []u8 = &.{},

    fn deinit(self: *HeaderCapture) void {
        if (self.captured_ct.len > 0) self.gpa.free(self.captured_ct);
        if (self.captured_body.len > 0) self.gpa.free(self.captured_body);
    }

    fn executor(self: *HeaderCapture) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn route(ctx: *anyopaque, gpa: std.mem.Allocator, body: ?[]const u8) WxResult([]u8) {
        const self: *HeaderCapture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const b = body orelse "";
        if (self.captured_body.len > 0) self.gpa.free(self.captured_body);
        self.captured_body = gpa.dupe(u8, b) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = gpa.dupe(u8, self.response) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) } };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        _ = method;
        _ = uri;
        return route(ctx, gpa, body);
    }

    fn executeWithHeadersImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, uri: []const u8, req_headers: []const result_mod.Header, body: ?[]const u8) WxResult(result_mod.Response) {
        _ = io;
        _ = method;
        _ = uri;
        const self: *HeaderCapture = @ptrCast(@alignCast(ctx));
        if (result_mod.headerValue(req_headers, "Content-Type")) |ct| {
            if (self.captured_ct.len > 0) self.gpa.free(self.captured_ct);
            self.captured_ct = gpa.dupe(u8, ct) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        }
        return switch (route(ctx, gpa, body)) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{ .body = b, .headers = &.{} } },
        };
    }

    const vtable = http_mod.RequestExecutor.VTable{
        .execute = executeImpl,
        .execute_with_headers = executeWithHeadersImpl,
    };
};

test "material add sends multipart Content-Type through execute_with_headers" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cap = HeaderCapture{ .gpa = gpa, .response = "{\"media_id\":\"MEDIA1\",\"url\":\"http://u\"}" };
    defer cap.deinit();
    var cfg = try config_mod.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    defer cfg.deinit();
    var base = service_mod.Service.init(gpa, cfg.config(), cap.executor());
    var svc = MaterialService{ .svc = &base };

    switch (svc.add(io, "image", "a.png", "PNGDATA")) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqualStrings("MEDIA1", res.media_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAddError;
        },
    }
    try testing.expectEqual(@as(usize, 1), cap.calls);
    // Content-Type 确实到达执行器,且带 multipart/form-data + boundary
    try testing.expect(std.mem.startsWith(u8, cap.captured_ct, "multipart/form-data; boundary=WxZig"));
    // multipart body 也确实发出(含 boundary + 文件名)
    try testing.expect(std.mem.indexOf(u8, cap.captured_body, "name=\"media\"") != null);
    try testing.expect(std.mem.indexOf(u8, cap.captured_body, "a.png") != null);
}
