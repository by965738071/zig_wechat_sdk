//! 二维码服务 —— 逐字对齐 Java `api.WxMpQrcodeService`(7 个方法)+ `api.impl.WxMpQrcodeServiceImpl`。
//! 方法名沿用 Java 的 camelCase(rule 2)。
//!
//! Java 接口 7 个方法:
//!   qrCodeCreateTmpTicket(int, Integer)    :28 / impl :29-35 —— sceneId==0 报错,QR_SCENE
//!   qrCodeCreateTmpTicket(String, Integer) :42 / impl :38-44 —— isBlank 报错,QR_STR_SCENE
//!   qrCodeCreateLastTicket(int)            :54 / impl :83-89 —— 1..100000 校验,QR_LIMIT_SCENE
//!   qrCodeCreateLastTicket(String)         :66 / impl :92-94 —— QR_LIMIT_STR_SCENE
//!   qrCodePicture(ticket)                 :78 / impl :97-99 —— execute(QrCodeRequestExecutor,...)
//!   qrCodePictureUrl(String, boolean)     :93 / impl :102-114 —— URL-encode + 可选 shortUrl
//!   qrCodePictureUrl(String)              :105 / impl :117-119 —— 委托 needShortUrl=false
//!
//! Java 重载 → Zig 惯用法(rule 1):
//!   - 两对 `int`/`String` 场景值重载 → distinct names(对齐 phase-2 `user.zig`):
//!     `qrCodeCreateTmpTicket` / `qrCodeCreateTmpTicketBySceneStr`,
//!     `qrCodeCreateLastTicket` / `qrCodeCreateLastTicketBySceneStr`;
//!   - 两个 `qrCodePictureUrl` 重载 → 单函数 `qrCodePictureUrl(ticket, need_short_url: ?bool)`
//!     (one fn with optional param):`null`/`false` 返回长链(Java 无参重载 & false),
//!     `true` 走 `Service.shortUrl` 压缩(Java needShortUrl=true)。两种行为都保留。
//!
//! 底座(rule 3):所有 URL 路径来自 `../api_url.zig:Qrcode`,经 `api()`/`mp()` 拼绝对 URL
//! (`api()` = `api_url.url(Host.api, path)` 用于 QRCODE_CREATE;`mp()` = `Host.mp` 用于
//! SHOW_QRCODE*/MP host)。移除旧 `mp_host_url`/`api_host_url` 本地常量与
//! `service.zig:ApiUrl.*`。手工 query(showqrcode 的 ticket)由 `mp_helpers.buildUrl`
//! 生成(内含 `urlEncode`,对齐 Java `URLEncoder.encode(ticket, UTF-8)`);
//! access_token 注入 / errcode→.err 折叠由 `Service.execute*` 统一完成。
//!
//! Java↔Zig 差异(逐条按 Java 逻辑取舍):
//!   - `qrCodePicture`:Java `execute(QrCodeRequestExecutor, SHOW_QRCODE, ticket)` —— 走
//!     `BaseWxMpServiceImpl.executeInternal`(会向 uri 追加 access_token,见 :473),
//!     `QrCodeJoddHttpRequestExecutor` 再追加 URL-encoded `?ticket=` 并返回图片原始字节。
//!     Zig 侧 showqrcode 是 MP host 的公开取图端点,凭 ticket 即可、无需 token,故经
//!     `Service.executeNoToken`(同样贯穿 RequestExecutor)GET,保留旧「无 token」契约;
//!     返回图片原始字节 `[]u8`(Java 返回 File)。本调用是**图片下载而非上传**,无 multipart
//!     请求体,故 `mp_helpers.multipart*` 在此不适用(见交付报告)。
//!   - `qrCodePictureUrl`:Java `String.format(SHOW_QRCODE_WITH_TICKET.getUrl(), encode(ticket))`;
//!     Zig 以 `SHOW_QRCODE`(无 `%s` 模板)+ `mp_helpers.buildUrl` 产出**同一** URL,
//!     避免本地 `String.format` 组包(遵守「不在本地重造 URL 拼装」)。
//!   - `expireSeconds`:Java `createQrCode`(impl :46-58)只在 `>2592000` 时报错、null 默认
//!     30 秒(`<=0` **不**拦截);旧 Zig `clampExpire` 额外拒绝 `<=0`,本轮改回忠实 Java。
//!     永久二维码直接走 `getQrCodeTicket(..., expireSeconds=null)`,请求体**不带**
//!     `expire_seconds`(Java impl :88/:93)。
//!   - `WxMpQrCodeTicket.expireSeconds` bean 默认 `-1`(永久);Zig `QrCodeTicket` 缺失该
//!     字段时同取 `-1`(旧版为 0)。
//!   - `qrCodePicture(WxMpQrCodeTicket)`:Java 从对象取 `.getTicket()`;Zig 直接接收
//!     ticket 字符串(调用方可传 `result.ticket`),与 `qrCodePictureUrl(String)` 一致。
//!   - `StringUtils.isBlank`:Zig 以 `trim(ASCII 空白).len==0` 近似(Java 含 Unicode 空白)。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `QrCodeTicket`(ticket/url 字符串)用 `deinit()`;
//!   - `[]u8` 结果(qrCodePicture 图片字节 / qrCodePictureUrl 链接 / getSelfMenuInfo 无):
//!     调用方 `gpa.free()`;
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const mp_helpers = @import("common").mp_helpers;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
const WxError = result_mod.WxError;

const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

/// host+path 绝对 URL(API host),路径取自 `api_url.zig:Qrcode`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// host+path 绝对 URL(MP host),用于 `SHOW_QRCODE`/`SHOW_QRCODE_WITH_TICKET`
/// (Java `WxMpApiUrl.Qrcode` 的 `MP_DEFAULT_HOST_URL`,见 api_url.zig:208-211 注释)。
fn mp(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.mp, path);
}

/// 手写 JSON 字符串转义(零容器生命周期风险,复用 phase-2 `user.zig:jw`)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 二维码 ticket —— 对应 Java `bean.result.WxMpQrCodeTicket`(ticket/url 字段 gpa 拥有)。
/// `expire_seconds`:接口不返回(永久二维码)时取 bean 默认 `-1`(Java :21「-1 说明是永久」)。
pub const QrCodeTicket = struct {
    gpa: std.mem.Allocator,
    ticket: []const u8 = "",
    expire_seconds: i64 = -1,
    url: []const u8 = "",

    /// 释放本结构持有的全部 gpa 字符串。
    pub fn deinit(self: *QrCodeTicket) void {
        self.gpa.free(@constCast(self.ticket));
        self.gpa.free(@constCast(self.url));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !QrCodeTicket {
        // 两处 dupe 都可能失败;失败时由 errdefer 释放已分配的一半,避免泄漏。
        // 即便字段缺失也 dupe 空串,保证 deinit 的 free 合法。
        const ticket = try gpa.dupe(u8, json_util.getStrOr(v, "ticket", ""));
        errdefer gpa.free(ticket);
        const url = try gpa.dupe(u8, json_util.getStrOr(v, "url", ""));
        errdefer gpa.free(url);
        return .{
            .gpa = gpa,
            .ticket = ticket,
            .url = url,
            .expire_seconds = json_util.getInt(v, "expire_seconds") orelse -1,
        };
    }
};

// ---------------------------------------------------------------------------
// 请求体组包 + URL 组包(纯逻辑,离线可测)
// ---------------------------------------------------------------------------

/// `{"action_name":..[, "expire_seconds":N],"action_info":{"scene":{"scene_str"|"scene_id":..}}}`
/// —— 逐字对应 Java `getQrCodeTicket`(impl :62-77)的 `JsonObject` 字段与顺序:
/// `expire_seconds` 仅在非 null 时输出;scene_str 优先于 scene_id;二者皆无则 scene 为 `{}`。
fn qrCodeBody(gpa: std.mem.Allocator, action_name: []const u8, scene_str: ?[]const u8, scene_id: ?i64, expire_seconds: ?i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"action_name\":");
    try jw.str(w, action_name);
    if (expire_seconds) |es| {
        try w.print(",\"expire_seconds\":{d}", .{es});
    }
    try w.writeAll(",\"action_info\":{\"scene\":{");
    if (scene_str) |s| {
        try w.writeAll("\"scene_str\":");
        try jw.str(w, s);
    } else if (scene_id) |sid| {
        try w.print("\"scene_id\":{d}", .{sid});
    }
    try w.writeAll("}}}");
    return out.toOwnedSlice();
}

/// showqrcode 长链 —— 等价 Java `String.format(SHOW_QRCODE_WITH_TICKET.getUrl(),
/// URLEncoder.encode(ticket, UTF-8))`(impl :104-105)。
/// 本轮以 `SHOW_QRCODE`(MP host)+ `mp_helpers.buildUrl`(内含 `urlEncode`)产出同一 URL,
/// 不本地重造 URL 拼装。`SHOW_QRCODE_WITH_TICKET` 的 `%s` 模板在测试中锁死(见下方用例)。
fn showQrcodeUrl(gpa: std.mem.Allocator, ticket: []const u8) ![]u8 {
    const base = mp(api_url.Qrcode.show_qrcode);
    const q = [_]mp_helpers.Query{.{ .key = "ticket", .value = ticket }};
    return mp_helpers.buildUrl(gpa, base, &q, null);
}

/// Java `StringUtils.isBlank(sceneStr)`(impl :39)的 ASCII 近似:空串或仅空白。
fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

// ---------------------------------------------------------------------------
// QrcodeService —— 对应 Java `WxMpQrcodeService`(7 方法) + `WxMpQrcodeServiceImpl`
// ---------------------------------------------------------------------------

pub const QrcodeService = struct {
    svc: *service_mod.Service,

    /// `WxMpQrcodeService.qrCodeCreateTmpTicket(int sceneId, Integer expireSeconds)`
    /// (接口 :28 / impl :29-35):`sceneId==0` → 报错;委托 `createQrCode("QR_SCENE",...)`。
    pub fn qrCodeCreateTmpTicket(self: *QrcodeService, io: std.Io, scene_id: i64, expire_seconds: ?i64) WxResult(QrCodeTicket) {
        if (scene_id == 0) return .{
            .err = WxError.configError(self.svc.gpa, "临时二维码场景值不能为0", .{}),
        };
        return self.createQrCode(io, "QR_SCENE", null, scene_id, expire_seconds);
    }

    /// `WxMpQrcodeService.qrCodeCreateTmpTicket(String sceneStr, Integer expireSeconds)`
    /// (接口 :42 / impl :38-44):`StringUtils.isBlank(sceneStr)` → 报错;
    /// 委托 `createQrCode("QR_STR_SCENE",...)`。
    pub fn qrCodeCreateTmpTicketBySceneStr(self: *QrcodeService, io: std.Io, scene_str: []const u8, expire_seconds: ?i64) WxResult(QrCodeTicket) {
        if (isBlank(scene_str)) return .{
            .err = WxError.configError(self.svc.gpa, "临时二维码场景值不能为空", .{}),
        };
        return self.createQrCode(io, "QR_STR_SCENE", scene_str, null, expire_seconds);
    }

    /// `WxMpQrcodeService.qrCodeCreateLastTicket(int sceneId)` (接口 :54 / impl :83-89):
    /// 场景值必须在 1..100000;直接 `getQrCodeTicket("QR_LIMIT_SCENE",..., expireSeconds=null)`
    /// (不经过 createQrCode,故请求体不带 expire_seconds、也不套用 30 秒默认值)。
    pub fn qrCodeCreateLastTicket(self: *QrcodeService, io: std.Io, scene_id: i64) WxResult(QrCodeTicket) {
        if (scene_id < 1 or scene_id > 100000) return .{
            .err = WxError.configError(self.svc.gpa, "永久二维码的场景值目前只支持1--100000", .{}),
        };
        return self.getQrCodeTicket(io, "QR_LIMIT_SCENE", null, scene_id, null);
    }

    /// `WxMpQrcodeService.qrCodeCreateLastTicket(String sceneStr)` (接口 :66 / impl :92-94):
    /// 直接 `getQrCodeTicket("QR_LIMIT_STR_SCENE",..., expireSeconds=null)`;Java 对此重载
    /// 不做空串校验,本轮同样不拦截。
    pub fn qrCodeCreateLastTicketBySceneStr(self: *QrcodeService, io: std.Io, scene_str: []const u8) WxResult(QrCodeTicket) {
        return self.getQrCodeTicket(io, "QR_LIMIT_STR_SCENE", scene_str, null, null);
    }

    /// `WxMpQrcodeService.qrCodePicture(WxMpQrCodeTicket ticket)` (接口 :78 / impl :97-99)。
    /// GET `mp` host `SHOW_QRCODE?ticket=<URL-encoded>`(无 access_token),经
    /// `Service.executeNoToken` 贯穿 RequestExecutor 返回图片原始字节 `[]u8`(Java 返回 File)。
    /// 所有权:`.ok` 的 `[]u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn qrCodePicture(self: *QrcodeService, io: std.Io, ticket: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const uri = showQrcodeUrl(gpa, ticket) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        // showqrcode 凭 ticket 取图,无需 access_token(与旧契约 / 微信实际接口一致)
        return self.svc.executeNoToken(io, uri, &.{}, null);
    }

    /// `WxMpQrcodeService.qrCodePictureUrl(String, boolean)` (:93 / impl :102-114) 与
    /// `qrCodePictureUrl(String)` (:105 / impl :117-119) 合并:
    /// 先拼 showqrcode 长链(ticket 经 URL 编码),`need_short_url==true` 时再走主接口
    /// `Service.shortUrl`(POST cgi-bin/shorturl,`{"action":"long2short","long_url":..}`)
    /// 压成短链;否则原样返回长链。
    ///   - `null`  = Java 无参重载(委托 needShortUrl=false);
    ///   - `false` = Java (ticket, false);
    ///   - `true`  = Java (ticket, true)。
    /// 所有权:`.ok` 的 `[]u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn qrCodePictureUrl(self: *QrcodeService, io: std.Io, ticket: []const u8, need_short_url: ?bool) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const long_url = showQrcodeUrl(gpa, ticket) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (need_short_url orelse false) {
            defer gpa.free(long_url);
            return self.svc.shortUrl(io, long_url);
        }
        return .{ .ok = long_url };
    }

    // ---- 内部(逐字对应 Java impl 的 private 方法) ----

    /// Java `createQrCode(String actionName, String sceneStr, Integer sceneId, Integer expireSeconds)`
    /// (impl :46-58):`expireSeconds > 2592000` → 报错;`expireSeconds == null` → 默认 30;
    /// 再委托 `getQrCodeTicket`。仅临时二维码两重载经此路径(永久二维码绕过)。
    fn createQrCode(self: *QrcodeService, io: std.Io, action_name: []const u8, scene_str: ?[]const u8, scene_id: ?i64, expire_seconds: ?i64) WxResult(QrCodeTicket) {
        const gpa = self.svc.gpa;
        var es = expire_seconds;
        if (es) |v| {
            if (v > 2592000) return .{
                .err = WxError.configError(gpa, "临时二维码有效时间最大不能超过2592000(即30天)", .{}),
            };
        } else {
            es = 30; // Java impl :53-55:null → 默认 30 秒
        }
        return self.getQrCodeTicket(io, action_name, scene_str, scene_id, es);
    }

    /// Java `getQrCodeTicket(...)` (impl :60-80):组 JSON 请求体 → POST QRCODE_CREATE →
    /// `WxMpQrCodeTicket.fromJson(responseContent)`。
    fn getQrCodeTicket(self: *QrcodeService, io: std.Io, action_name: []const u8, scene_str: ?[]const u8, scene_id: ?i64, expire_seconds: ?i64) WxResult(QrCodeTicket) {
        const gpa = self.svc.gpa;
        const body = qrCodeBody(gpa, action_name, scene_str, scene_id, expire_seconds) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, api(api_url.Qrcode.qrcode_create), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "qrcode/create not json", .{}),
        };
        defer parsed.deinit();
        const t = QrCodeTicket.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "qrcode ticket parse failed", .{}) };
        return .{ .ok = t };
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试(URL / method / 请求体 / 默认值 / shortUrl 多步 / 所有权)
// 脚手架复用 `sub_util.zig` 的 Recorder/Fixture(phase-2 约定),全离线。
// ---------------------------------------------------------------------------

test "qrCodeCreateTmpTicket: QR_SCENE + 默认 expire_seconds=30 + 请求体 + 所有权" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/qrcode/create", .response = "{\"ticket\":\"gQG1\",\"expire_seconds\":60,\"url\":\"http://weixin.qq.com/q/r1\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    switch (qr.qrCodeCreateTmpTicket(io, 100, null)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
            try testing.expectEqualStrings("gQG1", tk.ticket);
            try testing.expectEqual(@as(i64, 60), tk.expire_seconds); // stub 固定返回 60
            try testing.expectEqualStrings("http://weixin.qq.com/q/r1", tk.url);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/qrcode/create") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    // Java impl :53-55:expireSeconds=null → 请求体默认 30 秒
    try testing.expectEqualStrings(
        "{\"action_name\":\"QR_SCENE\",\"expire_seconds\":30,\"action_info\":{\"scene\":{\"scene_id\":100}}}",
        mock.body(),
    );
}

test "qrCodeCreateTmpTicketBySceneStr: QR_STR_SCENE + 显式过期 + isBlank/上限校验" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/qrcode/create", .response = "{\"ticket\":\"T\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    switch (qr.qrCodeCreateTmpTicketBySceneStr(io, "str1", 60)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings(
        "{\"action_name\":\"QR_STR_SCENE\",\"expire_seconds\":60,\"action_info\":{\"scene\":{\"scene_str\":\"str1\"}}}",
        mock.body(),
    );

    // isBlank(空白串) → .err(Java StringUtils.isBlank)
    switch (qr.qrCodeCreateTmpTicketBySceneStr(io, "   ", null)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }
    // >2592000 → .err(Java impl :49-50)
    switch (qr.qrCodeCreateTmpTicket(io, 1, 2592001)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }
    // Java 只拦截 >2592000;0 / 负数不拦截(与旧 clampExpire 不同,忠实 Java)
    switch (qr.qrCodeCreateTmpTicket(io, 7, 0)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"expire_seconds\":0") != null);
}

test "qrCodeCreateLastTicket / BySceneStr: QR_LIMIT_* 无 expire_seconds + 1..100000 校验" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/qrcode/create", .response = "{\"ticket\":\"gQG1\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 永久(int):直接 getQrCodeTicket(expireSeconds=null),请求体不带 expire_seconds
    switch (qr.qrCodeCreateLastTicket(io, 123)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings(
        "{\"action_name\":\"QR_LIMIT_SCENE\",\"action_info\":{\"scene\":{\"scene_id\":123}}}",
        mock.body(),
    );

    // 永久(String)
    switch (qr.qrCodeCreateLastTicketBySceneStr(io, "fx1")) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings(
        "{\"action_name\":\"QR_LIMIT_STR_SCENE\",\"action_info\":{\"scene\":{\"scene_str\":\"fx1\"}}}",
        mock.body(),
    );

    // 越界 0 / 100001 → .err(Java impl :84-85)
    switch (qr.qrCodeCreateLastTicket(io, 0)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }
    switch (qr.qrCodeCreateLastTicket(io, 100001)) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }
}

test "QrCodeTicket.fromJson: 缺失 expire_seconds 默认 -1(Java bean 永久标记)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/qrcode/create", .response = "{\"ticket\":\"T\",\"url\":\"U\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };

    switch (qr.qrCodeCreateLastTicket(fx.threaded.io(), 5)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
            try testing.expectEqual(@as(i64, -1), tk.expire_seconds); // bean 默认 -1 = 永久
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "qrCodePicture: GET mp showqrcode?ticket=<encoded> 无 token + 原始字节" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/showqrcode?ticket=", .response = "PNG_BYTES" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };

    switch (qr.qrCodePicture(fx.threaded.io(), "gQG1")) {
        .ok => |b| {
            defer gpa.free(b); // []u8 结果 gpa 拥有
            try testing.expectEqualStrings("PNG_BYTES", b);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "https://mp.weixin.qq.com/cgi-bin/showqrcode?ticket=gQG1") != null);
    // 凭 ticket 取图,不注入 access_token(executeNoToken 通道)
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=") == null);
}

test "qrCodePictureUrl(null/false): 长链 + URL 编码 + 无短链、无 HTTP 调用" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{} };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // need_short_url=null → Java qrCodePictureUrl(ticket)(委托 false)
    switch (qr.qrCodePictureUrl(io, "gQ G1+/=", null)) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expect(std.mem.indexOf(u8, u, "https://mp.weixin.qq.com/cgi-bin/showqrcode?ticket=") != null);
            // 编码断言:空格→+,特殊字符被转义(mp_helpers.buildUrl/urlEncode)
            try testing.expect(std.mem.indexOf(u8, u, "gQ+G1%2B%2F%3D") != null);
            try testing.expect(std.mem.indexOf(u8, u, "access_token=") == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    // need_short_url=false → Java qrCodePictureUrl(ticket, false)
    switch (qr.qrCodePictureUrl(io, "gQ G1+/=", false)) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expect(std.mem.indexOf(u8, u, "showqrcode?ticket=gQ+G1%2B%2F%3D") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 0), mock.calls); // 长链分支不触发任何 HTTP 请求
}

test "qrCodePictureUrl(true): shortUrl 多步 POST cgi-bin/shorturl 返回短链" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/shorturl", .response = "{\"short_url\":\"https://w.url.cn/SHORT\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };

    switch (qr.qrCodePictureUrl(fx.threaded.io(), "gQ G1", true)) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expectEqualStrings("https://w.url.cn/SHORT", u);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    // 恰好一次 shortUrl POST(长链 → 短链),无其它请求
    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/shorturl") != null);
    // 请求体 = {"action":"long2short","long_url":<showqrcode 长链>}
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"action\":\"long2short\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "showqrcode") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "gQ+G1") != null); // 空格→+ 编码
}

test "Service.shortUrl: 拒绝含 &access_token= 的长链(Java 微信 bug 防护)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/shorturl", .response = "{\"short_url\":\"SHOULD-NOT-BE-USED\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);

    // qrCodePictureUrl(true) 依赖的 shortUrl 通道,对输入长链做 &access_token= 守卫
    switch (fx.svc.shortUrl(fx.threaded.io(), "https://x.example/cb?a=1&access_token=LEAK")) {
        .ok => return error.Unexpected,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }
    // 守卫在发请求之前触发,不应有任何 HTTP 调用
    try testing.expectEqual(@as(usize, 0), mock.calls);
}

test "showqrcode 长链等价于 SHOW_QRCODE_WITH_TICKET 模板 + urlEncode" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{} };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var qr = QrcodeService{ .svc = &fx.svc };
    const ticket = "gQ G1+/=";

    // Java impl :104-105:String.format(SHOW_QRCODE_WITH_TICKET.getUrl(), URLEncoder.encode(ticket))
    try testing.expectEqualStrings("cgi-bin/showqrcode?ticket=%s", api_url.Qrcode.show_qrcode_with_ticket);
    const enc = try mp_helpers.urlEncode(gpa, ticket);
    defer gpa.free(enc);
    const base = api_url.url(api_url.Host.mp, api_url.Qrcode.show_qrcode);
    const expected = try std.fmt.allocPrint(gpa, "{s}?ticket={s}", .{ base, enc });
    defer gpa.free(expected);

    switch (qr.qrCodePictureUrl(fx.threaded.io(), ticket, false)) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expectEqualStrings(expected, u);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 0), mock.calls);
}
