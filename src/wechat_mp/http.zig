//! 请求执行层 —— 对应 Java `util.http.RequestHttp` + `util.requestexecuter.*`
//! (`RequestExecutor<T,E>` 策略接口)。
//!
//! Java 按请求类型分派不同 executor(SimpleGet / SimplePost / MediaUpload /
//! ApacheHttpClient 两种实现...)。Zig 骨架把「缝」收敛为**字节流级**的
//! `RequestExecutor` vtable:GET(body=null)/ POST(body=原始字节),
//! 返回响应 body 的 gpa 分配副本。
//! 媒体上传(multipart)等特化 executor 以同构 vtable 补充即可(TODO)。
const std = @import("std");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;
const result_mod = @import("common").result;
const json_util = @import("common").json_util;
const config_mod = @import("config.zig");

pub const WxError = error_mod.WxError;
pub const WxResult = result_mod.WxResult;
pub const Response = result_mod.Response;

/// 请求执行器(对应 `RequestExecutor<T, E>` + `RequestHttp` 的组合角色)。
pub const RequestExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// GET(body 为 null)或 POST(body 为原始字节)。
        /// 成功返回响应 body 的 gpa 分配副本(调用方释放);
        /// 网络错误 → WxError.transport(code=-1),交给上层 -1 退避重试。
        execute: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult([]u8),
        /// 架构级扩展:带回传响应头的执行(对应 Java `CloseableHttpClient.execute`
        /// 拿到的 `CloseableHttpResponse` = 响应头 + 实体)。接口形状一次设计到位:
        /// 返回 `Response{body,headers}`,正是 V3 应答验签所需 `Wechatpay-*` 的来源。
        /// 可空,默认 null —— 未覆写的实现由 wrapper `executeEx` 统一回退到 `execute`
        /// (响应头为空),从而「一次性铺开所有调用方」而 `zig build` 全程可过,
        /// 不必反复改 vtable。真实 std.http 通道回传响应头的限制见 HttpExecutor 注释。
        execute_ex: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult(Response) = null,
    };

    pub const Method = enum { get, post };

    pub fn execute(self: RequestExecutor, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        return self.vtable.execute(self.ptr, gpa, io, method, uri, body);
    }

    /// 带回传响应头的执行。实现未覆写 `execute_ex` 时回退到 `execute`,把 body
    /// 包成 `Response` 且响应头为空 —— 诚实标注「该执行器不回传响应头」,不伪造头。
    /// 返回的 `Response` 由 gpa 拥有,用毕 `deinit(gpa)`。
    pub fn executeEx(self: RequestExecutor, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult(Response) {
        if (self.vtable.execute_ex) |f| return f(self.ptr, gpa, io, method, uri, body);
        return switch (self.execute(gpa, io, method, uri, body)) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{ .body = b, .headers = &.{} } },
        };
    }
};

// ---------------------------------------------------------------------------
// 真实实现:std.http(内置 TLS)。与 Java ApacheHttpComponentsImpl 对应。
// ---------------------------------------------------------------------------

pub const HttpExecutor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// 对应 Java 侧 `WxPayConfig.httpConnectionTimeout / httpTimeout`。
    /// **仅记录、暂未生效**(本轮复核加严,保留现状、如实注释、不伪造实现):
    /// 核对 Zig 0.18.0-dev.935 的 `std.http.Client`:
    ///  - `fetch` / `FetchOptions` / `RequestOptions` 均无 timeout 字段;
    ///  - 全文件唯一的 `Io.Timeout` 是 `Client.zig:1449` 的
    ///    `ConnectTcpOptions.timeout`,但它在 `connectTcpOptions`(1452-1490)
    ///    **函数体内从未被读取**,是个「声明但未接线」的死字段;
    ///  - `request()`(1691)走 `connect()`(1607)-> `connectTcp()`(1433)
    ///    -> `connectTcpOptions(.{ .timeout = .none })`,不带任何 Options。
    /// 因此即便「弃用 fetch、自行驱动 request + receiveHead + 收包循环」,
    /// 也无法把 connect/read 超时真正接到连接或读取上 —— 除非改动/绕过标准库。
    /// 而自行重写 fetch 主循环还会同时失去 fetch 内置的解压(readerDecompressing)、
    /// 重定向、TLS CA bundle 等处理,风险过高且离线不可测。
    /// 结论:按用户「若风险过大保留现状与如实注释」处理,字段仅作配置占位,
    /// 不伪造实现、不宣称已生效。真实网络超时需待标准库支持后接入。
    connect_timeout_ms: u64 = 3_000,
    read_timeout_ms: u64 = 30_000,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpExecutor {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn executor(self: *HttpExecutor) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = ctx;
        var client = std.http.Client{ .allocator = gpa, .io = io };
        defer client.deinit();

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();

        const res = client.fetch(.{
            .location = .{ .url = uri },
            .method = switch (method) {
                .get => .GET,
                .post => .POST,
            },
            .payload = body,
            .response_writer = &out.writer,
        }) catch |e| return .{ .err = WxError.transport(gpa, "http {s} {s}: {s}", .{ @tagName(method), uri, @errorName(e) }) };

        const resp_body = out.toOwnedSlice() catch |e|
            return .{ .err = WxError.transport(gpa, "response buffer: {s}", .{@errorName(e)}) };
        errdefer gpa.free(resp_body);

        if (res.status.class() != .success) {
            // 语义对齐 Java `SimplePostRequestExecutor.handleResponse`:错误判定以响应
            // 内容为核心(errcode != 0 由 Service 层折叠为 WxError);但 4xx/5xx 且响应
            // 体不是微信错误(无 errcode 的 JSON/无 <xml>)时,Java 因 WxError.fromJson
            // 失败照样抛出 —— 这里在执行器层折叠状态码,避免把门户 HTML 当成功透传。
            if (std.mem.indexOf(u8, resp_body, "errcode") == null and
                std.mem.indexOf(u8, resp_body, "<xml") == null)
            {
                return .{ .err = WxError.transport(gpa, "http status {d} for {s}", .{ @backingInt(res.status), uri }) };
            }
        }
        return .{ .ok = resp_body };
    }

    const vtable = RequestExecutor.VTable{ .execute = executeImpl };
};

// ---------------------------------------------------------------------------
// 测试/离线桩:按 uri 子串返回预置响应。对应 Java 测试里的 mock 模式。
// ---------------------------------------------------------------------------

pub const StubExecutor = struct {
    gpa: std.mem.Allocator,
    /// 简单路由表:uri 里包含 match 即返回 response(按声明顺序取第一个命中)
    entries: []const Entry,
    calls: usize = 0,
    /// 供离线单测注入的响应头(如 `Wechatpay-*`)。借用,execute_ex 会 dupe 进
    /// Response(由调用方 deinit),对应真实执行器从 HTTP head 抓到的响应头。
    resp_headers: []const result_mod.Header = &.{},

    pub const Entry = struct { match: []const u8, response: []const u8 };

    pub fn init(gpa: std.mem.Allocator, entries: []const Entry) StubExecutor {
        return .{ .gpa = gpa, .entries = entries };
    }

    pub fn executor(self: *StubExecutor) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        _ = method;
        _ = body;
        const self: *StubExecutor = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, uri, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{ .err = WxError.transport(gpa, "oom", .{}) } };
            }
        }
        return .{ .err = WxError.transport(gpa, "stub miss: {s}", .{uri}) };
    }

    /// 回传响应头的执行(离线单测用):body 复用 executeImpl 的路由,headers 由
    /// resp_headers dupe 而来,模拟真实执行器的 `Response.Head.iterateHeaders()`。
    fn executeExImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult(Response) {
        const r = executeImpl(ctx, gpa, io, method, uri, body);
        return switch (r) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{
                .body = b,
                .headers = result_mod.dupeHeaders(gpa, field(ctx).resp_headers) catch {
                    gpa.free(b);
                    return .{ .err = WxError.transport(gpa, "oom", .{}) };
                },
            } },
        };
    }

    fn field(ctx: *anyopaque) *StubExecutor {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable = RequestExecutor.VTable{ .execute = executeImpl, .execute_ex = executeExImpl };
};

// ---------------------------------------------------------------------------
// access_token 拉取器 —— 对应 BaseWxMpServiceImpl.doGetAccessTokenRequest。
// 注入给 InMemoryConfigStorage 的 TokenSlot;协议(缓存/双重检查)在 common/token。
// ---------------------------------------------------------------------------

pub const AccessTokenFetcher = struct {
    cfg: config_mod.ConfigStorage,
    exec: RequestExecutor,
    /// 完整 token 接口前缀(不含 appid/secret 参数),如
    /// `https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential`。
    /// stable_token 变体:置 `stable=true` 并把 `token_url` 设为
    /// `https://api.weixin.qq.com/cgi-bin/stable_token`,按 Java
    /// `WxMpServiceHttpClientImpl#doGetStableAccessTokenRequest` 走 JSON POST。
    token_url: []const u8,
    /// false=普通 GET token;true=稳定版 POST stable_token(请求体见 `fetchImpl`)。
    stable: bool = false,

    pub fn fetcher(self: *AccessTokenFetcher) token_mod.Fetcher {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) token_mod.FetchOutcome {
        const self: *AccessTokenFetcher = @ptrCast(@alignCast(ctx));

        const resp: []u8 = blk: {
            if (self.stable) {
                // 对应 Java `WxMpStableAccessTokenRequest`:
                // {"grant_type":"client_credential","appid":..,"secret":..,"force_refresh":false}
                // (force_refresh 固定 false —— Fetcher vtable 未暴露 force 参数,与
                //  Java 常用的 getStableAccessToken(false) 一致)。
                var ob = json_util.ObjectBuilder.init(gpa);
                defer ob.deinit();
                ob.putStr("grant_type", "client_credential") catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
                ob.putStr("appid", self.cfg.appid()) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
                ob.putStr("secret", self.cfg.secret()) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
                ob.putBool("force_refresh", false) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
                const body = ob.toJson() catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
                defer gpa.free(body);
                const r = switch (self.exec.execute(gpa, io, .post, self.token_url, body)) {
                    .ok => |b| b,
                    .err => |e| return .{ .err = e },
                };
                break :blk r;
            }
            const uri = std.fmt.allocPrint(gpa, "{s}&appid={s}&secret={s}", .{
                self.token_url, self.cfg.appid(), self.cfg.secret(),
            }) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
            defer gpa.free(uri);
            const r = switch (self.exec.execute(gpa, io, .get, uri, null)) {
                .ok => |b| b,
                .err => |e| return .{ .err = e },
            };
            break :blk r;
        };
        defer gpa.free(resp);

        var err = WxError.fromJson(gpa, resp, .mp) catch return .{
            .err = WxError.transport(gpa, "token response not json", .{}),
        };
        if (err.error_code != 0 or err.raw == null) {
            defer err.deinit();
            return .{ .err = err };
        }
        defer err.deinit();

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "token response not json", .{}),
        };
        defer parsed.deinit();
        const t_src = json_util.getStr(parsed.value, "access_token") orelse return .{
            .err = WxError.transport(gpa, "token response missing access_token", .{}),
        };
        // 必须 dupe:token.acquire 会在写槽后释放 Fetched.token(所有权约定),
        // 而 parsed 的 arena 在本函数返回时就被销毁。
        const t = gpa.dupe(u8, t_src) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const exp = json_util.getInt(parsed.value, "expires_in") orelse 7200;
        return .{ .ok = .{ .token = t, .expires_in = exp } };
    }
};

// ---------------------------------------------------------------------------
// jsapi_ticket 拉取器 —— 对应 Java `BaseWxMpServiceImpl#getTicket` 里的
// `execute(SimpleGetRequestExecutor, GET_TICKET_URL + type.getCode(), null)`。
// GET `cgi-bin/ticket/getticket?type=jsapi&access_token=...`,响应
// {"errcode":0,"ticket":"...","expires_in":7200}。注入 ConfigStorage 的
// ticket 槽(token.Fetcher);协议(缓存/双重检查/过期)在 common/token。
// ---------------------------------------------------------------------------

pub const JsapiTicketFetcher = struct {
    cfg: config_mod.ConfigStorage,
    exec: RequestExecutor,
    /// 完整 ticket 接口(含 type),如
    /// `https://api.weixin.qq.com/cgi-bin/ticket/getticket?type=jsapi`。
    /// access_token 由本 fetcher 从 cfg.acquireAccessToken 取后追加。
    ticket_url: []const u8,

    pub fn fetcher(self: *JsapiTicketFetcher) token_mod.Fetcher {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) token_mod.FetchOutcome {
        const self: *JsapiTicketFetcher = @ptrCast(@alignCast(ctx));

        // 1. 取 access_token(对应 Java execute 里自动附 token 的动作)
        var tbuf: [256]u8 = undefined;
        const tok = switch (self.cfg.acquireAccessToken(io, &tbuf, false)) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };

        // 2. 拼 url(GET_TICKET_URL 已含 ?type=jsapi -> 用 & 追加)
        const uri = std.fmt.allocPrint(gpa, "{s}&access_token={s}", .{ self.ticket_url, tok }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const resp: []u8 = switch (self.exec.execute(gpa, io, .get, uri, null)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        // 3. errcode 校验(与 token fetcher 同口径)
        var err = WxError.fromJson(gpa, resp, .mp) catch return .{
            .err = WxError.transport(gpa, "ticket response not json", .{}),
        };
        if (err.error_code != 0 or err.raw == null) {
            defer err.deinit();
            return .{ .err = err };
        }
        defer err.deinit();

        // 4. 解析 ticket / expires_in
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "ticket response not json", .{}),
        };
        defer parsed.deinit();
        const t_src = json_util.getStr(parsed.value, "ticket") orelse return .{
            .err = WxError.transport(gpa, "ticket response missing ticket", .{}),
        };
        const t = gpa.dupe(u8, t_src) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const exp = json_util.getInt(parsed.value, "expires_in") orelse 7200;
        return .{ .ok = .{ .token = t, .expires_in = exp } };
    }
};

test "JsapiTicketFetcher: GET type=jsapi + access_token, parse ticket/expires_in" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 记录型 executor:捕获 uri,返回带合法签名的 ticket 响应
    const Capture = struct {
        resp: []const u8,
        last_uri: []u8 = &.{},
        calls: usize = 0,
        fn deinit(self: *@This(), g: std.mem.Allocator) void {
            if (self.last_uri.len > 0) g.free(self.last_uri);
        }
        fn executor(self: *@This()) RequestExecutor {
            return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = execImpl } };
        }
        fn execImpl(c: *anyopaque, g: std.mem.Allocator, i: std.Io, m: RequestExecutor.Method, u: []const u8, b: ?[]const u8) WxResult([]u8) {
            _ = i;
            _ = m;
            _ = b;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.calls += 1;
            if (self.last_uri.len > 0) g.free(self.last_uri);
            self.last_uri = g.dupe(u8, u) catch return .{ .err = WxError.transport(g, "oom", .{}) };
            return .{ .ok = g.dupe(u8, self.resp) catch return .{ .err = WxError.transport(g, "oom", .{}) } };
        }
    };
    var cap = Capture{ .resp = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"TICKET_XYZ\",\"expires_in\":7200}" };
    defer cap.deinit(gpa);

    var stub = StubExecutor.init(gpa, &.{});
    _ = &stub;
    const AF = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .ok = .{ .token = g.dupe(u8, "ACCESS_TOKEN") catch return .{ .err = WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
        }
    };
    var cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = AF.f } }, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tf = JsapiTicketFetcher{
        .cfg = cfg.config(),
        .exec = cap.executor(),
        .ticket_url = "https://api.weixin.qq.com/cgi-bin/ticket/getticket?type=jsapi",
    };
    cfg.ticket_fetcher = tf.fetcher();

    var buf: [256]u8 = undefined;
    switch (cfg.config().acquireJsapiTicket(io, &buf, false)) {
        .ok => |t| try std.testing.expectEqualStrings("TICKET_XYZ", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedTicketError;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), cap.calls);
    try std.testing.expect(std.mem.indexOf(u8, cap.last_uri, "type=jsapi") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.last_uri, "access_token=ACCESS_TOKEN") != null);
}

test "RequestExecutor.executeEx passes back response headers (V3 verify seam)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = StubExecutor.init(gpa, &.{
        .{ .match = "v3/pay", .response = "{\"prepay_id\":\"wx1\"}" },
    });
    stub.resp_headers = &.{
        .{ .name = "Wechatpay-Timestamp", .value = "1700000000" },
        .{ .name = "Wechatpay-Nonce", .value = "NONCE" },
        .{ .name = "Wechatpay-Signature", .value = "SIG" },
    };

    // executeEx 拿到 body + headers;头大小写不敏感(HTTP 语义)
    const r = stub.executor().executeEx(gpa, io, .get, "https://api.mch.weixin.qq.com/v3/pay/x", null);
    switch (r) {
        .ok => |resp| {
            var v = resp;
            defer v.deinit(gpa);
            try std.testing.expectEqualStrings("{\"prepay_id\":\"wx1\"}", v.body);
            try std.testing.expectEqualStrings("1700000000", v.header("wechatpay-timestamp").?);
            try std.testing.expectEqualStrings("NONCE", v.header("Wechatpay-Nonce").?);
            try std.testing.expect(v.header("Wechatpay-Missing") == null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedExecError;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    // 未覆写 execute_ex 的实现(CaptureExec 仅提供 execute) -> 回退:body 正常、头为空
    var plain = StubExecutor.init(gpa, &.{});
    _ = &plain;
    const PlainOnly = struct {
        fn f(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, m: RequestExecutor.Method, u: []const u8, b: ?[]const u8) WxResult([]u8) {
            _ = ctx;
            _ = i;
            _ = m;
            _ = u;
            _ = b;
            return .{ .ok = g.dupe(u8, "BODY") catch return .{ .err = WxError.transport(g, "oom", .{}) } };
        }
    };
    const fallback = RequestExecutor{ .ptr = undefined, .vtable = &.{ .execute = PlainOnly.f } };
    const r2 = fallback.executeEx(gpa, io, .get, "x", null);
    switch (r2) {
        .ok => |resp| {
            var v = resp;
            defer v.deinit(gpa);
            try std.testing.expectEqualStrings("BODY", v.body);
            try std.testing.expectEqual(@as(usize, 0), v.headers.len);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedExecError;
        },
    }
}

test "stub executor + token fetcher wiring" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "{\"access_token\":\"AT\",\"expires_in\":7200}" },
    });

    // ConfigStorage ←→ AccessTokenFetcher 相互引用:先给个不会用到的占位 fetcher，
    // 再把真实 fetcher 回填到 pub 字段(与 Java 先 new Storage 再 init http 同序)。
    const Dummy = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = error_mod.WxError.transport(g, "placeholder fetcher", .{}) };
        }
    };
    var storage = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = Dummy.f } }, .{ .appid = "A", .secret = "S" });
    defer storage.deinit();

    var fetch_ctx = AccessTokenFetcher{
        .cfg = storage.config(),
        .exec = stub.executor(),
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    storage.fetcher = fetch_ctx.fetcher();

    var buf: [256]u8 = undefined;
    const r = storage.config().acquireAccessToken(io, &buf, false);
    switch (r) {
        .ok => |t| try std.testing.expectEqualStrings("AT", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedTokenError;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}

/// 记录型 mock:捕获 method / uri / body,用于断言 stable_token 的 POST 请求体。
const CaptureExec = struct {
    gpa: std.mem.Allocator,
    resp: []const u8,
    calls: usize = 0,
    last_method: RequestExecutor.Method = .get,
    last_uri: []u8 = &.{},
    last_body: []u8 = &.{},

    fn executor(self: *CaptureExec) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = execImpl } };
    }

    fn deinit(self: *CaptureExec) void {
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
    }

    fn execImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *CaptureExec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = method;
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        self.last_uri = gpa.dupe(u8, uri) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
        self.last_body = gpa.dupe(u8, body orelse "") catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = gpa.dupe(u8, self.resp) catch return .{ .err = WxError.transport(gpa, "oom", .{}) } };
    }
};

test "stable access token posts Java WxMpStableAccessTokenRequest payload" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var exec = CaptureExec{ .gpa = gpa, .resp = "{\"access_token\":\"SAT\",\"expires_in\":7200}" };
    defer exec.deinit();

    const Dummy = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = WxError.transport(g, "placeholder fetcher", .{}) };
        }
    };
    var storage = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = Dummy.f } }, .{ .appid = "wxAPPID", .secret = "SECRET" });
    defer storage.deinit();

    var fetch_ctx = AccessTokenFetcher{
        .cfg = storage.config(),
        .exec = exec.executor(),
        .token_url = "https://api.weixin.qq.com/cgi-bin/stable_token",
        .stable = true,
    };
    storage.fetcher = fetch_ctx.fetcher();

    var buf: [256]u8 = undefined;
    const r = storage.config().acquireAccessToken(io, &buf, false);
    switch (r) {
        .ok => |t| try std.testing.expectEqualStrings("SAT", t),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedTokenError;
        },
    }

    try std.testing.expectEqual(@as(usize, 1), exec.calls);
    try std.testing.expectEqual(RequestExecutor.Method.post, exec.last_method);
    try std.testing.expect(std.mem.indexOf(u8, exec.last_uri, "cgi-bin/stable_token") != null);
    // 请求体即 Java WxMpStableAccessTokenRequest 的四个字段
    try std.testing.expect(std.mem.indexOf(u8, exec.last_body, "\"grant_type\":\"client_credential\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec.last_body, "\"appid\":\"wxAPPID\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec.last_body, "\"secret\":\"SECRET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec.last_body, "\"force_refresh\":false") != null);
}
