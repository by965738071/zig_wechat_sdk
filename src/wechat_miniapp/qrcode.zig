//! 小程序码服务 —— 对应 Java `api.WxMaQrcodeService` + `api.impl.WxMaQrcodeServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Qrcode`(以 Java 为准;任务书口述的
//! `/wxacode/getunlimited`、`/wxacode/get` 为转写误差,实际是
//! `/wxa/getwxacodeunlimit`、`/wxa/getwxacode`)。
//!
//! 请求线格式对齐 `bean.WxaCodeUnlimit` / `bean.WxaCode` / `bean.WxMaQrcode`
//! (Gson `@SerializedName` → snake_case;Java 还有 auto_color/is_hyaline/line_color
//! 与 File 落盘变体,本实现只覆盖任务书范围,默认值取 Java 字段默认值)。
//!
//! 成功/失败判定对应 Java `executor.QrcodeBytesRequestExecutor`:响应 Content-Type
//! 为 JSON 即抛 WxErrorException。Zig 端 RequestExecutor 只透传字节(拿不到响应头),
//! 故用「首字节是否为 '{'」做等价检测;errcode≠0 的 JSON 通常已在服务基座
//! (`mp_service.Service`)折叠为 `.err`,这里的检测兜底 errcode==0 的异常 JSON。
//!
//! 返回值所有权:成功时 `[]u8` 为 gpa 分配的拥有副本,调用方 `gpa.free`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
const WxError = error_mod.WxError;

// --- URL(对应 WxMaApiUrlConstants.Qrcode) -------------------------------------

const CREATE_QRCODE_URL = "https://api.weixin.qq.com/cgi-bin/wxaapp/createwxaqrcode";
const GET_WXACODE_URL = "https://api.weixin.qq.com/wxa/getwxacode";
const GET_WXACODE_UNLIMIT_URL = "https://api.weixin.qq.com/wxa/getwxacodeunlimit";

/// 对应 `WxMaConstants.DEFAULT_ENV_VERSION`("release")。
pub const DEFAULT_ENV_VERSION = "release";
/// 对应 Java bean 的 `width` 字段默认值 430。
pub const DEFAULT_WIDTH = 430;

/// 写一个 JSON 字符串字面量(带引号与转义;对应 Gson 的 addProperty)。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn fold(gpa: std.mem.Allocator, ctx: []const u8, e: anyerror) WxError {
    return WxError.transport(gpa, "{s}: {s}", .{ ctx, @errorName(e) });
}

// --- bean(请求) ----------------------------------------------------------------

/// 对应 `bean.WxaCodeUnlimit`(无限制小程序码;默认值与 Java 字段默认一致:
/// check_path=true、env_version="release"、width=430,原始类型 Gson 恒输出)。
pub const WxaCodeUnlimit = struct {
    scene: []const u8,
    /// 扫码进入的小程序页面路径,不填 = 首页(Java 里 String null → Gson 省略)。
    page: ?[]const u8 = null,
    check_path: bool = true,
    env_version: []const u8 = DEFAULT_ENV_VERSION,
    width: i64 = DEFAULT_WIDTH,

    pub fn to_json(self: WxaCodeUnlimit, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"scene\":");
        try js(w, self.scene);
        if (self.page) |p| {
            try w.writeAll(",\"page\":");
            try js(w, p);
        }
        try w.print(",\"check_path\":{s}", .{if (self.check_path) "true" else "false"});
        try w.writeAll(",\"env_version\":");
        try js(w, self.env_version);
        try w.print(",\"width\":{d}}}", .{self.width});
        return out.toOwnedSlice();
    }
};

/// 对应 `bean.WxaCode`(有限制小程序码)。
pub const WxaCode = struct {
    path: []const u8,
    env_version: []const u8 = DEFAULT_ENV_VERSION,
    width: i64 = DEFAULT_WIDTH,

    pub fn to_json(self: WxaCode, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"path\":");
        try js(w, self.path);
        try w.writeAll(",\"env_version\":");
        try js(w, self.env_version);
        try w.print(",\"width\":{d}}}", .{self.width});
        return out.toOwnedSlice();
    }
};

/// 对应 `bean.WxMaQrcode`(小程序二维码,非小程序码)。
pub const Qrcode = struct {
    path: []const u8,
    width: i64 = DEFAULT_WIDTH,

    pub fn to_json(self: Qrcode, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"path\":");
        try js(w, self.path);
        try w.print(",\"width\":{d}}}", .{self.width});
        return out.toOwnedSlice();
    }
};

// --- service ------------------------------------------------------------------

/// 小程序码服务 —— 组合在服务基座上(对应 `WxMaQrcodeServiceImpl` 持有
/// `WxMaService` 引用的组合方式;Java 的 File 落盘变体由调用方自行写文件)。
pub const QrcodeService = struct {
    svc: *mp_service.Service,

    /// 对应 `createWxaCodeUnlimitBytes(scene, page, ...)`(POST /wxa/getwxacodeunlimit):
    /// 成功返回二维码图片二进制(拥有所有权,调用方 `gpa.free`);
    /// 失败(JSON 响应)按 errcode 折叠为 `.err`(对应 Java 抛 WxErrorException)。
    pub fn get_wxacode_unlimit(self: *QrcodeService, io: std.Io, req: WxaCodeUnlimit) WxResult([]u8) {
        return self.postBytes(io, GET_WXACODE_UNLIMIT_URL, req);
    }

    /// 对应 `createWxaCodeBytes(path, ...)`(POST /wxa/getwxacode)。
    /// 所有权同 `get_wxacode_unlimit`。
    pub fn get_wxacode(self: *QrcodeService, io: std.Io, req: WxaCode) WxResult([]u8) {
        return self.postBytes(io, GET_WXACODE_URL, req);
    }

    /// 对应 `createQrcodeBytes(path, width)`(POST /cgi-bin/wxaapp/createwxaqrcode)。
    /// 所有权同 `get_wxacode_unlimit`。
    pub fn create_wxa_qrcode(self: *QrcodeService, io: std.Io, req: Qrcode) WxResult([]u8) {
        return self.postBytes(io, CREATE_QRCODE_URL, req);
    }

    /// POST 并做「图片字节 or JSON 错误」分流。
    fn postBytes(self: *QrcodeService, io: std.Io, url: []const u8, msg: anytype) WxResult([]u8) {
        const g = self.svc.gpa;
        const body = msg.to_json(g) catch |e| return .{ .err = fold(g, "qrcode build body", e) };
        defer g.free(body);
        return switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| rejectJson(g, b),
            .err => |e| .{ .err = e },
        };
    }
};

/// JSON 兜底检测:首字节 '{' → 按响应里的 errcode 转 WxError(对应 Java
/// `QrcodeBytesRequestExecutor` 对 Content-Type=JSON 的分支);否则原样返回拥有字节。
fn rejectJson(gpa: std.mem.Allocator, b: []u8) WxResult([]u8) {
    if (b.len > 0 and b[0] == '{') {
        const err = WxError.fromJson(gpa, b, .mini_app) catch {
            const e = WxError.transport(gpa, "qrcode error response not json", .{});
            gpa.free(b);
            return .{ .err = e };
        };
        gpa.free(b);
        return .{ .err = err };
    }
    return .{ .ok = b };
}

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + body + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

/// 8 字节假 PNG 头(够用来区分 JSON 与二进制)。
const FAKE_PNG = "\x89PNG\r\n\x1a\nFAKE";

test "get_wxacode_unlimit: binary success returns owned png bytes" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "getwxacodeunlimit", .response = FAKE_PNG }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeService{ .svc = &base };

    const img = switch (s.get_wxacode_unlimit(io, .{ .scene = "a=1&b=2", .page = "pages/index" })) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(img);
    try std.testing.expectEqualStrings(FAKE_PNG, img);

    try std.testing.expectEqual(mp_service.RequestExecutor.Method.post, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/getwxacodeunlimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=TOK") != null);

    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a=1&b=2", json_util.getStr(parsed.value, "scene").?);
    try std.testing.expectEqualStrings("pages/index", json_util.getStr(parsed.value, "page").?);
    try std.testing.expectEqual(@as(?bool, true), json_util.getBool(parsed.value, "check_path"));
    try std.testing.expectEqualStrings("release", json_util.getStr(parsed.value, "env_version").?);
    try std.testing.expectEqual(@as(i64, 430), json_util.getInt(parsed.value, "width").?);
}

test "get_wxacode_unlimit: json error -> WxError(errcode)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "getwxacodeunlimit", .response = "{\"errcode\":41030,\"errmsg\":\"invalid page\"}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeService{ .svc = &base };

    switch (s.get_wxacode_unlimit(io, .{ .scene = "s" })) {
        .ok => |b| {
            gpa.free(b);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 41030), err.error_code);
            try std.testing.expectEqualStrings("invalid page", err.error_msg_en);
        },
    }
}

test "get_wxacode_unlimit: errcode==0 json still rejected by '{' guard" {
    // 基座对 errcode==0 透传字节,服务层的 '{' 检测(对应 Java Content-Type=JSON
    // 即抛错)仍须把它转为错误,不能把 JSON 当图片返回。
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{.{ .match = "getwxacodeunlimit", .response = "{\"errcode\":0}" }});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeService{ .svc = &base };

    switch (s.get_wxacode_unlimit(io, .{ .scene = "s" })) {
        .ok => |b| {
            gpa.free(b);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expect(err.raw != null and err.raw.?.len > 0);
        },
    }
}

test "get_wxacode + create_wxa_qrcode: body shape + errcode" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "wxa/getwxacode", .response = FAKE_PNG },
        .{ .match = "createwxaqrcode", .response = "{\"errcode\":65302,\"errmsg\":\"invalid page\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = QrcodeService{ .svc = &base };

    const img = switch (s.get_wxacode(io, .{ .path = "pages/a", .width = 280 })) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(img);
    try std.testing.expectEqualStrings(FAKE_PNG, img);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxa/getwxacode") != null);
    const p1 = try json_util.parse(gpa, m.last_body);
    defer p1.deinit();
    try std.testing.expectEqualStrings("pages/a", json_util.getStr(p1.value, "path").?);
    try std.testing.expectEqual(@as(i64, 280), json_util.getInt(p1.value, "width").?);
    try std.testing.expectEqualStrings("release", json_util.getStr(p1.value, "env_version").?);

    // createwxaqrcode errcode!=0 → WxError(每服务 errcode!=0 用例)
    switch (s.create_wxa_qrcode(io, .{ .path = "pages/b" })) {
        .ok => |b| {
            gpa.free(b);
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 65302), err.error_code);
        },
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/cgi-bin/wxaapp/createwxaqrcode") != null);
    const p2 = try json_util.parse(gpa, m.last_body);
    defer p2.deinit();
    try std.testing.expectEqualStrings("pages/b", json_util.getStr(p2.value, "path").?);
    try std.testing.expectEqual(@as(i64, 430), json_util.getInt(p2.value, "width").?);
}
