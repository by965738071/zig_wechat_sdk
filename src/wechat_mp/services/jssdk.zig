//! JS-SDK 签名服务 —— 对应 Java `api.impl.BaseWxMpServiceImpl#getTicket /
//! #getJsapiTicket / #createJsapiSignature`（任务描述写作 `WxMpServiceImpl`，
//! 实际实现位于其父类 `BaseWxMpServiceImpl`）。
//!
//! URL 常量对应 `enums/WxMpApiUrl.GET_TICKET_URL`：
//! `/cgi-bin/ticket/getticket?type=<TicketType.code>`（JSAPI 的 code 为 `"jsapi"`，
//! 以 Java 源码为准，并非任务描述里的 `/cgi-bin/ticket/get`）。
//!
//! 与 Java 的差异（骨架阶段）：
//! - Java 把 ticket 缓存在 ConfigStorage（`updateTicket/isTicketExpired` + 锁），
//!   Zig 骨架未实现 ticket 缓存，`getTicket` 每次直接发 GET（缺口见文件尾）；
//! - Java `createJsapiSignature` 内部用 `RandomUtils.getRandomStr()`（16 位
//!   `[a-zA-Z0-9]`）+ `System.currentTimeMillis()/1000`；Zig 拆成两层：
//!   `createSignature` 允许注入 nonce/timestamp（测试确定性），
//!   `create` 才自动生成（对应 Java 原始签名形态）。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const sha1_mod = @import("common").crypt.sha1;
const random_mod = @import("common").random;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;

/// 对应 Java `enums/TicketType`（code 与 Java 逐一对齐）。
pub const TicketType = enum {
    jsapi,
    sdk,
    wx_card,

    pub fn code(self: TicketType) []const u8 {
        return switch (self) {
            .jsapi => "jsapi",
            .sdk => "2",
            .wx_card => "wx_card",
        };
    }
};

/// `getTicket` 响应解析结果（对应 Java 从 JSON 取的 ticket/expires_in）。
/// `ticket` 由 gpa 拥有，用完必须 `deinit`。
pub const Ticket = struct {
    gpa: std.mem.Allocator,
    ticket: []u8,
    expires_in: i64,

    pub fn deinit(self: *Ticket) void {
        self.gpa.free(self.ticket);
    }
};

/// 对应 Java `bean/WxJsapiSignature`（前端 wx.config 需要的字段）。
/// 所有权：`app_id/nonce_str/signature` 均由 gpa 拥有（dupe 自入参/config），
/// 用完必须 `deinit`。`timestamp` 单位秒（对应 Java 的 long 秒值）。
/// 注：Java 结构里还有 `url` 字段——调用方本来就持有该 url，骨架按任务约定不复制。
pub const JsSignature = struct {
    gpa: std.mem.Allocator,
    app_id: []u8,
    nonce_str: []u8,
    timestamp: i64,
    signature: []u8,

    pub fn deinit(self: *JsSignature) void {
        const g = self.gpa;
        g.free(self.app_id);
        g.free(self.nonce_str);
        g.free(self.signature);
    }
};

/// 对应 `createJsapiSignature` 中的
/// `SHA1.genWithAmple("jsapi_ticket="+t, "noncestr="+n, "timestamp="+ts, "url="+u)`：
/// 四段 `k=v` 按 ASCII 字典序排序（键首字母 j<n<t<u，排序结果恒为
/// `jsapi_ticket=…&noncestr=…&timestamp=…&url=…`）→ `&` 连接 → SHA-1 小写 hex。
/// 返回串由 gpa 拥有（调用方释放）。
/// 对应 Java `StringUtils.isAnyEmpty` 的防御：任一空参报配置错误。
pub fn signJsapi(
    gpa: std.mem.Allocator,
    jsapi_ticket: []const u8,
    nonce_str: []const u8,
    timestamp: i64,
    url: []const u8,
) WxResult([]u8) {
    if (jsapi_ticket.len == 0 or nonce_str.len == 0 or url.len == 0) {
        return .{ .err = error_mod.WxError.configError(gpa, "jsapi 签名参数为空: ticket/noncestr/url", .{}) };
    }
    var ts_buf: [32]u8 = undefined;
    const ts_part = std.fmt.bufPrint(&ts_buf, "timestamp={d}", .{timestamp}) catch unreachable;

    const p_ticket = std.fmt.allocPrint(gpa, "jsapi_ticket={s}", .{jsapi_ticket}) catch
        return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
    defer gpa.free(p_ticket);
    const p_nonce = std.fmt.allocPrint(gpa, "noncestr={s}", .{nonce_str}) catch
        return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
    defer gpa.free(p_nonce);
    const p_url = std.fmt.allocPrint(gpa, "url={s}", .{url}) catch
        return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
    defer gpa.free(p_url);

    const sig = sha1_mod.genWithAmple(gpa, &.{ p_ticket, p_nonce, ts_part, p_url }) catch
        return .{ .err = error_mod.WxError.internal(gpa, "sha1 拼接失败", .{}) };
    return .{ .ok = sig };
}

pub const JssdkService = struct {
    svc: *service_mod.Service,

    /// 对应 `BaseWxMpServiceImpl.getTicket(TicketType)`：
    /// GET `cgi-bin/ticket/getticket?type=<code>`（access_token 由服务层附加，
    /// 与 Java `execute(SimpleGetRequestExecutor, GET_TICKET_URL + code, null)` 一致）。
    /// errcode != 0 已由服务层折叠为 `.err`；此处只解析 ticket/expires_in。
    pub fn getTicket(self: *JssdkService, io: std.Io, t: TicketType) WxResult(Ticket) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{
            service_mod.api_host_url,
            service_mod.ApiUrl.ticket_get.asUri(),
        }) catch return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const qs = [_]service_mod.Query{.{ .key = "type", .value = t.code() }};
        const resp = switch (self.svc.get(io, uri, &qs)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = error_mod.WxError.transport(gpa, "getticket 响应非 JSON", .{}),
        };
        defer parsed.deinit();

        // 对应 Java `tmpJsonObject.get("ticket").getAsString()`：缺字段即报错
        const src = json_util.getStr(parsed.value, "ticket") orelse return .{
            .err = error_mod.WxError.transport(gpa, "getticket 响应缺少 ticket", .{}),
        };
        const ticket = gpa.dupe(u8, src) catch return .{
            .err = error_mod.WxError.internal(gpa, "oom", .{}),
        };
        errdefer gpa.free(ticket);
        // 对应 `get("expires_in").getAsInt()`；骨架宽容缺省 7200
        const expires_in = json_util.getInt(parsed.value, "expires_in") orelse 7200;
        return .{ .ok = .{ .gpa = gpa, .ticket = ticket, .expires_in = expires_in } };
    }

    /// 对应 `getJsapiTicket()` → `getTicket(TicketType.JSAPI, false)`。
    pub fn getJsapiTicket(self: *JssdkService, io: std.Io) WxResult(Ticket) {
        return self.getTicket(io, .jsapi);
    }

    /// 对应 `createJsapiSignature(String url)`，但 nonce/timestamp 由调用方注入
    /// （Java 内部随机生成；注入是为了测试可断言已知向量）。
    /// 流程与 Java 相同：getJsapiTicket(false) → SHA1.genWithAmple → 组装
    /// `WxJsapiSignature`（appId 取 config.getAppId()）。
    pub fn createSignature(
        self: *JssdkService,
        io: std.Io,
        url: []const u8,
        nonce_str: []const u8,
        timestamp: i64,
    ) WxResult(JsSignature) {
        const gpa = self.svc.gpa;
        var tk = switch (self.getJsapiTicket(io)) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };
        defer tk.deinit();

        const sig = switch (signJsapi(gpa, tk.ticket, nonce_str, timestamp, url)) {
            .ok => |s| s,
            .err => |e| return .{ .err = e },
        };
        errdefer gpa.free(sig);

        const app_id = gpa.dupe(u8, self.svc.config.appid()) catch {
            gpa.free(sig);
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        };
        errdefer gpa.free(app_id);
        const nonce = gpa.dupe(u8, nonce_str) catch {
            gpa.free(app_id);
            gpa.free(sig);
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        };
        return .{ .ok = .{
            .gpa = gpa,
            .app_id = app_id,
            .nonce_str = nonce,
            .timestamp = timestamp,
            .signature = sig,
        } };
    }

    /// 对应 Java `createJsapiSignature(url)` 原始形态：
    /// nonce = `RandomUtils.getRandomStr()`（16 位字母数字，见 common/random.zig），
    /// timestamp = `System.currentTimeMillis() / 1000`（墙钟秒）。
    pub fn create(self: *JssdkService, io: std.Io, url: []const u8) WxResult(JsSignature) {
        var nonce: [16]u8 = undefined;
        random_mod.randomStr(io, &nonce) catch |e| return .{
            .err = error_mod.WxError.transport(self.svc.gpa, "随机串生成失败: {s}", .{@errorName(e)}),
        };
        const ts: i64 = @intCast(@divFloor(
            std.Io.Timestamp.now(io, .real).nanoseconds,
            std.time.ns_per_s,
        ));
        return self.createSignature(io, url, &nonce, ts);
    }
};

// ---------------------------------------------------------------------------
// 测试:mock executor 记录 method/uri,断言请求与已知 SHA-1 向量。
// （样板照 menu.zig：MockExec + TestCtx）
// ---------------------------------------------------------------------------

/// 记录型 mock(照 `user.zig` 的 StubExecutor vtable 方式,额外捕获请求)。
const MockExec = struct {
    gpa: std.mem.Allocator,
    resp: []const u8,
    calls: usize = 0,
    last_method: http_mod.RequestExecutor.Method = .get,
    last_uri: []u8 = &.{},

    fn executor(self: *MockExec) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = execImpl } };
    }

    fn deinit(self: *MockExec) void {
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
    }

    fn execImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        _ = body;
        const self: *MockExec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = method;
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        self.last_uri = gpa.dupe(u8, uri) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = gpa.dupe(u8, self.resp) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) } };
    }
};

/// 测试公共脚手架:假 token 的 config(对应 user.zig 测试样板)。
const TestCtx = struct {
    threaded: std.Io.Threaded,
    cfg: config_mod.InMemoryConfigStorage,

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };

    fn init(gpa: std.mem.Allocator) !TestCtx {
        const threaded = std.Io.Threaded.init(gpa, .{});
        const cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
        return .{ .threaded = threaded, .cfg = cfg };
    }

    fn deinit(self: *TestCtx) void {
        self.cfg.deinit();
        self.threaded.deinit();
    }

    fn io(self: *TestCtx) std.Io {
        return self.threaded.io();
    }

    fn service(self: *TestCtx, exec: http_mod.RequestExecutor) service_mod.Service {
        return service_mod.Service.init(self.cfg.gpa, self.cfg.config(), exec);
    }
};

const http_mod = @import("../http.zig");
const token_mod = @import("common").token;
const config_mod = @import("../config.zig");

/// 官方文档示例向量（与 Java `SHA1.genWithAmple` 结果一致，期望值预先用
/// python hashlib 算好写死）。
const doc_ticket = "sM4AOVdWfPE4DxkXGEs8VMCPGGVi4CedVM0k4XinGEu94ttcQZu2N6TFDZQyGqT0";
const doc_nonce = "WafNZkqFkFbFtMtx";
const doc_ts: i64 = 1320628854;
const doc_url = "http://example.com/page1";
const doc_sig = "1fee2b688c819eb42addfd5a88fbfb23dce3f3f3";

test "jssdk signJsapi known vector and empty-param guard" {
    const gpa = std.testing.allocator;
    const r = signJsapi(gpa, doc_ticket, doc_nonce, doc_ts, doc_url);
    switch (r) {
        .ok => |s| {
            defer gpa.free(s);
            try std.testing.expectEqualStrings(doc_sig, s);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // 对应 Java StringUtils.isAnyEmpty → IllegalArgumentException
    const bad = signJsapi(gpa, "", doc_nonce, doc_ts, doc_url);
    try std.testing.expect(bad.failed());
    var err = bad.err;
    defer err.deinit();
}

test "jssdk getticket mock uri type=jsapi and parse" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"" ++ doc_ticket ++ "\",\"expires_in\":7200}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var jssdk = JssdkService{ .svc = &svc };
    const r = jssdk.getJsapiTicket(ctx.io());
    switch (r) {
        .ok => |t| {
            var tk = t;
            defer tk.deinit();
            try std.testing.expectEqualStrings(doc_ticket, tk.ticket);
            try std.testing.expectEqual(@as(i64, 7200), tk.expires_in);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(http_mod.RequestExecutor.Method.get, mock.last_method);
    // 对应 Java GET_TICKET_URL + TicketType.JSAPI.getCode()
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "cgi-bin/ticket/getticket") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "type=jsapi") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "access_token=TOK") != null);

    // TicketType.SDK 的 code 是 "2"（对应 Java 枚举）
    const r2 = jssdk.getTicket(ctx.io(), .sdk);
    switch (r2) {
        .ok => |t| {
            var tk = t;
            tk.deinit();
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "type=2") != null);
}

test "jssdk createSignature full flow (injected nonce/ts)" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"" ++ doc_ticket ++ "\",\"expires_in\":7200}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var jssdk = JssdkService{ .svc = &svc };
    const r = jssdk.createSignature(ctx.io(), doc_url, doc_nonce, doc_ts);
    switch (r) {
        .ok => |s| {
            var sig = s;
            defer sig.deinit();
            try std.testing.expectEqualStrings("A", sig.app_id); // config.getAppId()
            try std.testing.expectEqualStrings(doc_nonce, sig.nonce_str);
            try std.testing.expectEqual(doc_ts, sig.timestamp);
            try std.testing.expectEqualStrings(doc_sig, sig.signature);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    // 恰好一次 ticket 请求（token 走缓存）
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "type=jsapi") != null);
}

test "jssdk create generates nonce and timestamp" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"" ++ doc_ticket ++ "\",\"expires_in\":7200}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var jssdk = JssdkService{ .svc = &svc };
    const r = jssdk.create(ctx.io(), doc_url);
    switch (r) {
        .ok => |s| {
            var sig = s;
            defer sig.deinit();
            // 对应 Java RandomUtils.getRandomStr() 的 16 字符长度约定
            try std.testing.expectEqual(@as(usize, 16), sig.nonce_str.len);
            for (sig.nonce_str) |c| {
                try std.testing.expect(std.mem.indexOfScalar(u8, random_mod.ALPHABET, c) != null);
            }
            try std.testing.expectEqual(@as(usize, 40), sig.signature.len); // sha1 hex
            // 秒级时间戳（> 2023-11 的某个下界即可）
            try std.testing.expect(sig.timestamp > 1_700_000_000);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "jssdk getticket errcode folds to WxError" {
    const gpa = std.testing.allocator;
    // 48001(api 未授权)不在 ACCESS_TOKEN_ERROR_CODES 里,不触发刷新重试
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var jssdk = JssdkService{ .svc = &svc };
    const r = jssdk.getJsapiTicket(ctx.io());
    switch (r) {
        .ok => |*t| {
            var tk = t.*;
            tk.deinit();
            return error.Unexpected;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 48001), err.error_code);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}
