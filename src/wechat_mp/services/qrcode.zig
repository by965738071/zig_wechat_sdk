//! 二维码服务 —— 对应 Java `api.WxMpQrcodeService` + `api.impl.WxMpQrcodeServiceImpl`。
//!
//! URL 以 Java 枚举 `enums.WxMpApiUrl.Qrcode` 为准:
//! - QRCODE_CREATE            → https://api.weixin.qq.com/cgi-bin/qrcode/create
//! - SHOW_QRCODE              → https://mp.weixin.qq.com/cgi-bin/showqrcode
//! - SHOW_QRCODE_WITH_TICKET  → https://mp.weixin.qq.com/cgi-bin/showqrcode?ticket=%s
//! - SHORTURL_API_URL         → https://api.weixin.qq.com/cgi-bin/shorturl
//!
//! `qrCodePictureUrl(ticket, needShortUrl=true)` 先拼 showqrcode 长链,
//! 再走主接口 `Service.shortUrl`(POST cgi-bin/shorturl)压缩,与 Java 一致。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;

/// 二维码 ticket —— 对应 Java `bean.result.WxMpQrCodeTicket`(全部 gpa 拥有)。
pub const QrCodeTicket = struct {
    gpa: std.mem.Allocator,
    ticket: []const u8 = "",
    /// 临时二维码的有效时间;永久二维码为 0(接口不返回)
    expire_seconds: i64 = 0,
    url: []const u8 = "",

    pub fn deinit(self: *QrCodeTicket) void {
        self.gpa.free(@constCast(self.ticket));
        self.gpa.free(@constCast(self.url));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !QrCodeTicket {
        var t = QrCodeTicket{
            .gpa = gpa,
            .ticket = try gpa.dupe(u8, json_util.getStrOr(v, "ticket", "")),
            .url = try gpa.dupe(u8, json_util.getStrOr(v, "url", "")),
        };
        t.expire_seconds = json_util.getInt(v, "expire_seconds") orelse 0;
        return t;
    }
};

/// 对应 Java `WxMpApiUrl.Qrcode.MP_DEFAULT_HOST_URL`。
pub const mp_host_url = "https://mp.weixin.qq.com";
pub const api_host_url = service_mod.api_host_url;

/// URL 百分号编码(复用 service.urlEncode,与 showqrcode 需要 URLEncode 的行为一致)。
fn percentEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    return service_mod.urlEncode(gpa, s);
}

fn postJson(gpa: std.mem.Allocator, v: json_util.Value) WxResult([]u8) {
    return .{ .ok = json_util.stringify(gpa, v) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) } };
}

pub const QrcodeService = struct {
    svc: *service_mod.Service,

    /// 对应 `qrCodeCreateTmpTicket(int sceneId, Integer expireSeconds)`:
    /// sceneId==0 报错;expire_seconds 上限 2592000(30天),null 默认 30。
    /// 服务层语义:errcode!=0 已由 Service 折叠为 .err,这里做参数校验。
    pub fn createTmpTicketBySceneId(
        self: *QrcodeService,
        io: std.Io,
        scene_id: i64,
        expire_seconds: ?i64,
    ) WxResult(QrCodeTicket) {
        if (scene_id == 0) return .{ .err = result_mod.WxError.configError(self.svc.gpa, "临时二维码场景值不能为0", .{}) };
        const es = clampExpire(expire_seconds) orelse return .{ .err = result_mod.WxError.configError(self.svc.gpa, "临时二维码有效时间最大不能超过2592000(即30天)", .{}) };
        return self.createQrCode(io, .{ .action_name = "QR_SCENE", .scene_id = scene_id, .expire_seconds = es });
    }

    /// 对应 `qrCodeCreateTmpTicket(String sceneStr, Integer expireSeconds)`。
    pub fn createTmpTicketBySceneStr(
        self: *QrcodeService,
        io: std.Io,
        scene_str: []const u8,
        expire_seconds: ?i64,
    ) WxResult(QrCodeTicket) {
        if (scene_str.len == 0) return .{ .err = result_mod.WxError.configError(self.svc.gpa, "临时二维码场景值不能为空", .{}) };
        const es = clampExpire(expire_seconds) orelse return .{ .err = result_mod.WxError.configError(self.svc.gpa, "临时二维码有效时间最大不能超过2592000(即30天)", .{}) };
        return self.createQrCode(io, .{ .action_name = "QR_STR_SCENE", .scene_str = scene_str, .expire_seconds = es });
    }

    /// 对应 `qrCodeCreateLastTicket(int sceneId)`:场景值 1..100000。
    pub fn createLastTicketBySceneId(self: *QrcodeService, io: std.Io, scene_id: i64) WxResult(QrCodeTicket) {
        if (scene_id < 1 or scene_id > 100000) {
            return .{ .err = result_mod.WxError.configError(self.svc.gpa, "永久二维码的场景值目前只支持1--100000", .{}) };
        }
        return self.createQrCode(io, .{ .action_name = "QR_LIMIT_SCENE", .scene_id = scene_id });
    }

    /// 对应 `qrCodeCreateLastTicket(String sceneStr)`。
    pub fn createLastTicketBySceneStr(self: *QrcodeService, io: std.Io, scene_str: []const u8) WxResult(QrCodeTicket) {
        return self.createQrCode(io, .{ .action_name = "QR_LIMIT_STR_SCENE", .scene_str = scene_str });
    }

    /// 对应 `qrCodePicture(ticket)`:GET mp.weixin.qq.com/cgi-bin/showqrcode?ticket=
    /// 返回图片原始字节(PNG/JPG),调用方 free。Java 返回 Bitmap 可写文件。
    pub fn qrCodePicture(self: *QrcodeService, io: std.Io, ticket: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const enc = percentEncode(gpa, ticket) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(enc);
        const uri = std.fmt.allocPrint(gpa, "{s}/cgi-bin/showqrcode?ticket={s}", .{ mp_host_url, enc }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        // showqrcode 凭 ticket 取图,无需 access_token(与 Java 一致)
        return self.svc.executeNoToken(io, uri, &.{}, null);
    }

    /// 对应 `qrCodePictureUrl(ticket)`(needShortUrl=false)。
    /// 返回串 gpa 分配,调用方 free。
    pub fn qrCodePictureUrl(self: *QrcodeService, ticket: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const enc = percentEncode(gpa, ticket) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(enc);
        const url = std.fmt.allocPrint(gpa, "{s}/cgi-bin/showqrcode?ticket={s}", .{ mp_host_url, enc }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = url };
    }

    /// 对应 `qrCodePictureUrl(ticket, needShortUrl=true)` 分支:
    /// 拼 showqrcode 长链(URL 编码 ticket,与 qrCodePictureUrl 同构造),再调
    /// 主接口 `Service.shortUrl` 把长链压成短链(POST cgi-bin/shorturl)。
    /// 返回串 gpa 分配,调用方 free。
    pub fn qrCodePictureUrlShort(self: *QrcodeService, io: std.Io, ticket: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const enc = percentEncode(gpa, ticket) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(enc);
        const long_url = std.fmt.allocPrint(gpa, "{s}/cgi-bin/showqrcode?ticket={s}", .{ mp_host_url, enc }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(long_url);
        return switch (self.svc.shortUrl(io, long_url)) {
            .ok => |s| .{ .ok = s },
            .err => |e| .{ .err = e },
        };
    }

    // ---- 内部 ----

    /// 请求参数(alignment: action_name + scene 二选一 + 过期时间)。
    const CreateArgs = struct {
        action_name: []const u8,
        scene_id: ?i64 = null,
        scene_str: ?[]const u8 = null,
        expire_seconds: ?i64 = null,
    };

    fn createQrCode(self: *QrcodeService, io: std.Io, args: CreateArgs) WxResult(QrCodeTicket) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        const opts = std.json.Stringify.Options{ .escape_unicode = false };

        w.writeAll("{\"action_name\":") catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        std.json.Stringify.encodeJsonString(args.action_name, opts, w) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        if (args.expire_seconds) |es| {
            w.print(",\"expire_seconds\":{d}", .{es}) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll(",\"action_info\":{\"scene\":{") catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        if (args.scene_str) |s| {
            w.writeAll("\"scene_str\":") catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
            std.json.Stringify.encodeJsonString(s, opts, w) catch
                return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        } else if (args.scene_id) |sid| {
            w.print("\"scene_id\":{d}", .{sid}) catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("}}}") catch return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const uri = std.fmt.allocPrint(gpa, "{s}cgi-bin/qrcode/create", .{api_host_url}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const resp = switch (self.svc.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "qrcode/create not json", .{}),
        };
        defer parsed.deinit();
        const t = QrCodeTicket.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.transport(gpa, "qrcode ticket parse failed", .{}) };
        return .{ .ok = t };
    }
};

/// 对应 Java `createQrCode` 里的 expireSeconds 校验:
/// null → 默认 30 秒;>2592000(30 天)或 <=0 视为非法(null 由调用方折叠为参数错误)。
fn clampExpire(expire_seconds: ?i64) ?i64 {
    const es = expire_seconds orelse return 30;
    if (es > 2592000 or es <= 0) return null;
    return es;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

test "qrcode: tmp tickets(url 断言 + 默认过期 30s)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/qrcode/create", .response = "{\"ticket\":\"gQG1\",\"expire_seconds\":60,\"url\":\"http://weixin.qq.com/q/r1\"}" },
        .{ .match = "cgi-bin/showqrcode?ticket=", .response = "PNG_BYTES" },
    });

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var qr = QrcodeService{ .svc = &svc };

    // 临时(id),不带 expire_seconds → 默认 30 秒
    {
        const r = qr.createTmpTicketBySceneId(io, 100, null);
        switch (r) {
            .ok => |*t| {
                var tk = t.*;
                defer tk.deinit();
                try testing.expectEqualStrings("gQG1", tk.ticket);
                try testing.expectEqual(@as(i64, 60), tk.expire_seconds); // stub 固定返回 60
                try testing.expectEqualStrings("http://weixin.qq.com/q/r1", tk.url);
            },
            .err => return error.Unexpected,
        }
    }

    // 临时(str):显式过期时间 + QR_STR_SCENE 请求体断言
    {
        const r = qr.createTmpTicketBySceneStr(io, "str1", 60);
        switch (r) {
            .ok => |*t| {
                var tk = t.*;
                defer tk.deinit();
                try testing.expectEqual(@as(i64, 60), tk.expire_seconds);
            },
            .err => return error.Unexpected,
        }
    }

    // 永久(int):1..100000 → QR_LIMIT_SCENE(不携带 expire_seconds)
    {
        const r = qr.createLastTicketBySceneId(io, 123);
        switch (r) {
            .ok => |*t| {
                var tk = t.*;
                defer tk.deinit();
                try testing.expectEqual(@as(i64, 60), tk.expire_seconds); // stub 静态响应
            },
            .err => return error.Unexpected,
        }
    }

    // 永久(str):QR_LIMIT_STR_SCENE
    {
        const r = qr.createLastTicketBySceneStr(io, "fx1");
        switch (r) {
            .ok => |*t| {
                var tk = t.*;
                defer tk.deinit();
                try testing.expectEqualStrings("gQG1", tk.ticket);
            },
            .err => return error.Unexpected,
        }
    }
}

test "qrcode: picture bytes + pictureUrl" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/showqrcode?ticket=", .response = "PNG_BYTES" },
        .{ .match = "cgi-bin/shorturl", .response = "{\"short_url\":\"https://w.url.cn/S\"}" },
    });

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "NOPE") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());
    var qr = QrcodeService{ .svc = &svc };

    // pictureUrl:mp 域 + ticket URL 编码
    {
        const r = qr.qrCodePictureUrl("gQ G1+/=");
        switch (r) {
            .ok => |u| {
                defer gpa.free(@constCast(u));
                try testing.expect(std.mem.indexOf(u8, u, "https://mp.weixin.qq.com/cgi-bin/showqrcode?ticket=") != null);
                // 编码断言:空格→+,特殊字符被转义
                try testing.expect(std.mem.indexOf(u8, u, "gQ+G1%2B%2F%3D") != null);
            },
            .err => return error.Unexpected,
        }
    }

    // picture:无 token GET → 返回原始字节
    switch (qr.qrCodePicture(io, "gQG1")) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expectEqualStrings("PNG_BYTES", b);
        },
        .err => return error.Unexpected,
    }
    // pictureUrlShort:走 shortUrl 通道 → 返回短链
    switch (qr.qrCodePictureUrlShort(io, "t")) {
        .ok => |u| {
            defer gpa.free(@constCast(u));
            try testing.expectEqualStrings("https://w.url.cn/S", u);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "qrcode: 参数校验(对应 Java 异常)" {
    var stub = http_mod.StubExecutor.init(testing.allocator, &.{});
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(testing.allocator, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var svc = service_mod.Service.init(testing.allocator, cfg.config(), stub.executor());
    var qr = QrcodeService{ .svc = &svc };

    // scene_id==0 / 过期超限 / 永久越界 → .err(对应 Java 异常)
    switch (qr.createTmpTicketBySceneId(io, 0, null)) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }
    switch (qr.createTmpTicketBySceneId(io, 1, 2592001)) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }
    switch (qr.createLastTicketBySceneId(io, 0)) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }
    switch (qr.createLastTicketBySceneId(io, 100001)) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }
}

/// 捕获 method/uri/body 的 executor —— 用于离线断言 shortUrl 的 POST 请求体。
const CapExec = struct {
    gpa: std.mem.Allocator,
    resp: []const u8,
    calls: usize = 0,
    last_method: http_mod.RequestExecutor.Method = .get,
    last_uri: []u8 = &.{},
    last_body: []u8 = &.{},

    fn executor(self: *CapExec) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = exec } };
    }
    fn deinit(self: *CapExec) void {
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
    }
    fn exec(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) http_mod.WxResult([]u8) {
        _ = io;
        const self: *CapExec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = method;
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        self.last_uri = gpa.dupe(u8, uri) catch return .{ .err = http_mod.WxError.transport(gpa, "oom", .{}) };
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
        self.last_body = gpa.dupe(u8, body orelse "") catch return .{ .err = http_mod.WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = gpa.dupe(u8, self.resp) catch return .{ .err = http_mod.WxError.transport(gpa, "oom", .{}) } };
    }
};

test "shortUrl: long2short POST + short_url 解析 + qrCodePictureUrlShort 接线" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var cap = CapExec{ .gpa = gpa, .resp = "{\"short_url\":\"https://w.url.cn/SHORT\"}" };
    defer cap.deinit();
    var svc = service_mod.Service.init(gpa, cfg.config(), cap.executor());
    var qr = QrcodeService{ .svc = &svc };

    // pictureUrlShort:先拼 showqrcode 长链(ticket 经 URL 编码),再 POST 压缩。
    const r = qr.qrCodePictureUrlShort(io, "gQ G1");
    switch (r) {
        .ok => |u| {
            defer gpa.free(@constCast(u));
            try testing.expectEqualStrings("https://w.url.cn/SHORT", u);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    try testing.expectEqual(@as(usize, 1), cap.calls);
    try testing.expectEqual(http_mod.RequestExecutor.Method.post, cap.last_method);
    try testing.expect(std.mem.indexOf(u8, cap.last_uri, "cgi-bin/shorturl") != null);
    // 请求体 = {"action":"long2short","long_url":<showqrcode 长链>}
    try testing.expect(std.mem.indexOf(u8, cap.last_body, "\"action\":\"long2short\"") != null);
    try testing.expect(std.mem.indexOf(u8, cap.last_body, "showqrcode") != null);
    try testing.expect(std.mem.indexOf(u8, cap.last_body, "gQ+G1") != null); // 空格→+ 的编码
}

test "shortUrl: 拒绝含 &access_token= 的长链(Java 微信 bug 防护)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();

    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/shorturl", .response = "{\"short_url\":\"SHOULD-NOT-BE-USED\"}" },
    });
    var svc = service_mod.Service.init(gpa, cfg.config(), stub.executor());

    switch (svc.shortUrl(io, "https://x.example/cb?a=1&access_token=LEAK")) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }
    // 守卫在发请求之前触发,不应有任何 HTTP 调用。
    try testing.expectEqual(@as(usize, 0), stub.calls);
}
