//! JS-SDK 签名服务 —— 对应 Java `api.impl.BaseWxMpServiceImpl#getTicket /
//! #getJsapiTicket / #createJsapiSignature`（任务描述写作 `WxMpServiceImpl`，
//! 实际实现位于其父类 `BaseWxMpServiceImpl`）。
//!
//! URL 常量对应 `enums/WxMpApiUrl.GET_TICKET_URL`：
//! `/cgi-bin/ticket/getticket?type=<TicketType.code>`（JSAPI 的 code 为 `"jsapi"`，
//! 以 Java 源码为准，并非任务描述里的 `/cgi-bin/ticket/get`）。
//!
//! 签名路径统一（修复此前的双重实现）：`create` / `createSignature` 一律委托
//! `Service.createJsapiSignature` —— 后者经 `ConfigStorage.acquireJsapiTicket`
//! 取**带缓存**的 jsapi ticket（过期 / force 刷新 / 锁协议在 common/token）。
//! 这样签名不再绕过 ticket 缓存，全仓只有 Service 一处产生 JS-SDK 签名
//! （SHA1 单一来源），不会因直连 getticket 而旁路缓存。
//! 本文件的 `getTicket` / `getJsapiTicket` 保留为**底层、不带缓存**的裸拉取
//! 原语（直接 GET getticket），仅供需要读取「当前 ticket」的场景 / 既有测试；
//! 需要签名时一律走 `create` / `createSignature`。`signJsapi` 保留为纯 SHA1
//! helper（离线可测的已知向量）。
//!
//! Java `createJsapiSignature` 内部用 `RandomUtils.getRandomStr()`（16 位
//! `[a-zA-Z0-9]`）+ `System.currentTimeMillis()/1000`；这里 `createSignature`
//! 允许注入 nonce/timestamp（测试确定性），`create` 用 inject=null 让 Service
//! 自动生成（对应 Java 原始签名形态）。
const std = @import("std");

const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const random_mod = @import("common").random;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
const sha1_mod = @import("common").crypt.sha1;
const token_mod = @import("common").token;

const config_mod = @import("../config.zig");
const http_mod = @import("../http.zig");
const service_mod = @import("../service.zig");

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

    /// 对应 `createJsapiSignature(String url)`，nonce/timestamp 由调用方注入
    /// （注入是为了测试可断言已知向量）。
    /// **单一来源**：委托 `Service.createJsapiSignature`，后者经带缓存的
    /// `ConfigStorage.acquireJsapiTicket` 取 ticket，不再绕过缓存、也不再自行
    /// 计算签名（此前本文件曾有一套独立的直连 + SHA1 实现）。
    pub fn createSignature(
        self: *JssdkService,
        io: std.Io,
        url: []const u8,
        nonce_str: []const u8,
        timestamp: i64,
    ) WxResult(JsSignature) {
        return switch (self.svc.createJsapiSignature(io, url, .{
            .noncestr = nonce_str,
            .timestamp = timestamp,
        })) {
            .ok => |s| .{ .ok = self.wrapSignature(s) },
            .err => |e| .{ .err = e },
        };
    }

    /// 对应 Java `createJsapiSignature(url)` 原始形态（随机 nonce + 墙钟秒）。
    /// 同样委托缓存版 Service 路径；`inject=null` 时由 Service 自动生成 16 位
    /// nonce 与秒级时间戳（对应 Java RandomUtils / currentTimeMillis）。
    pub fn create(self: *JssdkService, io: std.Io, url: []const u8) WxResult(JsSignature) {
        return switch (self.svc.createJsapiSignature(io, url, null)) {
            .ok => |s| .{ .ok = self.wrapSignature(s) },
            .err => |e| .{ .err = e },
        };
    }

    /// 把 `Service.JsapiSignature` 转成本文件的 `JsSignature`：不重复计算、
    /// 不重复分配。Service 侧 4 个字段（appid/noncestr/url/signature）全为 gpa
    /// 拥有；`JsSignature` 不含 url（调用方本就持有 url），故此处 free 掉 url，
    /// 其余 3 个串**转移所有权**给返回值，且不调用 Service 侧的 deinit
    /// （避免 double free）。
    fn wrapSignature(self: *JssdkService, s: service_mod.Service.JsapiSignature) JsSignature {
        const sig = s;
        self.svc.gpa.free(sig.url);
        return .{
            .gpa = self.svc.gpa,
            .app_id = sig.appid,
            .nonce_str = sig.noncestr,
            .timestamp = sig.timestamp,
            .signature = sig.signature,
        };
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

    /// 签名委托给 Service 后,ticket 改由带缓存的 ticket_fetcher 提供,
    /// 不再是 MockExec 直连 getticket。
    const TicketFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, doc_ticket) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };

    fn init(gpa: std.mem.Allocator) !TestCtx {
        const threaded = std.Io.Threaded.init(gpa, .{});
        const cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{
            .appid = "A",
            .secret = "S",
            .ticket_fetcher = .{ .ptr = undefined, .vtable = &.{ .fetch = TicketFetch.f } },
        });
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
    // 签名委托给带缓存的 Service 路径:ticket 来自 ticket_fetcher,
    // 不再经由 MockExec 直连 getticket(缓存/刷新不被旁路)。
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
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

test "jssdk 签名委托缓存:ticket_fetcher 只拉取一次且无直连 getticket" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 计数型 ticket_fetcher:证明缓存命中(第二次签名不再拉取)。
    const Counting = struct {
        count: usize = 0,
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = i;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.count += 1;
            const t = g.dupe(u8, doc_ticket) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
        fn fetcher(self: *@This()) token_mod.Fetcher {
            return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = f } };
        }
    };
    var counting = Counting{};
    const AF = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = AF.f } }, .{
        .appid = "A",
        .secret = "S",
        .ticket_fetcher = counting.fetcher(),
    });
    defer cfg.deinit();

    // MockExec 若被调用就说明又绕回了直连 getticket(缓存被旁路)。
    var mock = MockExec{ .gpa = gpa, .resp = "{}" };
    defer mock.deinit();
    var svc = service_mod.Service.init(gpa, cfg.config(), mock.executor());
    var jssdk = JssdkService{ .svc = &svc };

    for (0..2) |_| {
        switch (jssdk.createSignature(io, doc_url, doc_nonce, doc_ts)) {
            .ok => |s| {
                var sig = s;
                defer sig.deinit();
                try std.testing.expectEqualStrings(doc_sig, sig.signature);
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
    }
    // ticket 只拉取一次(命中缓存),且完全没有直连 getticket 请求。
    try std.testing.expectEqual(@as(usize, 1), counting.count);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
}
