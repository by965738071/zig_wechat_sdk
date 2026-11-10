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
///
/// 三个 vtable 槽按「一次性设计到位、可空回退」铺开,mp / open(共用本接口)与
/// pay 的 V3 接口(另见 `wechat_pay/v3.zig`,自带请求头参数)都能回传响应头:
///   - `execute`                : 只要 body(最老、所有 mock 都实现);
///   - `execute_ex`             : 回传 `Response{body,headers}`(V3 应答验签取
///     `Wechatpay-*` 头的入口)。可空,回退到 `execute` 且响应头为空;
///   - `execute_with_headers`   : 带**自定义请求头**执行并回传 `Response`
///     (multipart `Content-Type` 等)。可空,回退到 `execute_ex`/`execute`,
///     请求头被忽略并如实标注。
/// 因后两个槽均为带默认 null 的可选字段,既有全部 vtable 字面量(mock 只给
/// `execute`)零改动即可编译 —— 这就是「先定形状、一次铺开、不反复改 vtable」。
pub const RequestExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// 一个请求/响应头(名/值)。复用 `common.result.Header` 保持全仓单一形状。
    pub const Header = result_mod.Header;

    pub const VTable = struct {
        /// GET(body 为 null)或 POST(body 为原始字节)。
        /// 成功返回响应 body 的 gpa 分配副本(调用方释放);
        /// 网络错误 → WxError.transport(code=-1),交给上层 -1 退避重试。
        execute: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult([]u8),
        /// 带回传响应头的执行(对应 Java `CloseableHttpResponse` = 头 + 实体)。
        /// 可空,默认 null;未覆写由 `executeEx` 回退到 `execute`,响应头为空。
        execute_ex: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, body: ?[]const u8) WxResult(Response) = null,
        /// 带自定义请求头 + 回传响应头的执行。可空,默认 null;未覆写由
        /// `executeWithHeaders` 回退到 `executeEx`,忽略请求头(诚实标注)。
        execute_with_headers: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, req_headers: []const Header, body: ?[]const u8) WxResult(Response) = null,
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

    /// 带自定义请求头并回传响应头的执行(对应 Java `MaterialUploadRequestExecutor`
    /// 设置 `Content-Type`)。实现未覆写 `execute_with_headers` 时回退到 `executeEx`:
    /// 请求头被忽略、响应头走既有回退 —— 不伪造「已发送自定义头」。
    pub fn executeWithHeaders(self: RequestExecutor, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, req_headers: []const Header, body: ?[]const u8) WxResult(Response) {
        if (self.vtable.execute_with_headers) |f| return f(self.ptr, gpa, io, method, uri, req_headers, body);
        return self.executeEx(gpa, io, method, uri, body);
    }
};

// ---------------------------------------------------------------------------
// 真实实现:std.http(内置 TLS)。与 Java ApacheHttpComponentsImpl 对应。
//
// 工具链重核(Zig 0.18.0-dev.954+60635c2bd):`Client.fetch` 仍只回 status
// (`std/http/Client.zig:1801 FetchResult{ status }`),拿不到响应头。要回传响应头
// 必须走低层 `request -> receiveHead -> readerDecompressing`,并在 `reader()`
// (会 `invalidateStrings` 复用 head 缓冲)之前从 `head.bytes` 抓头。本轮据此把
// 真实 HttpExecutor 接到 `execute_ex`/`execute_with_headers`,使 V3 应答验签
// (Wechatpay-* 头)与 multipart `Content-Type` 有真实通道,不再只靠 mock。
// ---------------------------------------------------------------------------

/// 低层一发一收的结果:gpa 拥有 body + 解析后的响应头,用毕 `deinit(gpa)`。
pub const RawHttpResponse = struct {
    status: std.http.Status,
    body: []u8,
    headers: []const result_mod.Header,

    pub fn deinit(self: RawHttpResponse, gpa: std.mem.Allocator) void {
        var r = Response{ .body = self.body, .headers = self.headers };
        r.deinit(gpa);
    }
};

/// 逐字对照 dev.954 `Client.fetch` 主循环,但额外回传响应头、并允许注入自定义
/// 请求头(`extra`),替代「只给 status」的 fetch:
///  - `request(method, uri, .{ .extra_headers = extra, .redirect_behavior })`;
///  - POST 走 `sendBodyUnflushed`,GET 走 `sendBodiless`;
///  - `receiveHead` 后**先** `parseHeaders(head.bytes)`,再 `readerDecompressing`
///    读 body(与 fetch 解压口径一致,支持 identity/gzip/deflate/zstd);
///  - 重定向:GET 跟随最多 3 次,POST 不跟随(避免重发 payload),与 fetch 同。
/// 错误以 Zig error 抛出,由调用方折叠成 `WxError.transport`。
pub fn httpRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    method: RequestExecutor.Method,
    uri: []const u8,
    extra: []const std.http.Header,
    body: ?[]const u8,
) !RawHttpResponse {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    const parsed = try std.Uri.parse(uri);
    const http_method: std.http.Method = switch (method) {
        .get => .GET,
        .post => .POST,
    };
    const redirects: std.http.Client.Request.RedirectBehavior = if (body == null)
        .init(3)
    else
        .unhandled;
    var req = try client.request(http_method, parsed, .{
        .redirect_behavior = redirects,
        .extra_headers = extra,
    });
    defer req.deinit();

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(payload);
        try bw.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer: []u8 = if (redirects == .unhandled) &.{} else try gpa.alloc(u8, 8 * 1024);
    defer if (redirects != .unhandled) gpa.free(redirect_buffer);
    var response = try req.receiveHead(redirect_buffer);
    const status = response.head.status;

    // reader()/readerDecompressing() 会 invalidateStrings 并复用 head 缓冲,
    // 故必须在初始化 body reader 之前把响应头 dupe 出来(纯解析、离线可测)。
    const headers = try result_mod.parseHeaders(gpa, response.head.bytes);
    errdefer result_mod.freeHeaders(gpa, headers);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = try reader.streamRemaining(&out.writer);
    const owned = try out.toOwnedSlice();
    return .{ .status = status, .body = owned, .headers = headers };
}

pub const HttpExecutor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// 对应 Java `WxPayConfig.httpConnectionTimeout / httpTimeout`。
    /// **仍仅记录、暂未生效**(本轮按 dev.954 重核,如实保留、不伪造实现):
    ///  - `fetch`/`FetchOptions`/`RequestOptions` 均无 timeout 字段;
    ///  - 全 `std/http/Client.zig` 唯一的 `Io.Timeout` 是 `ConnectTcpOptions.timeout`
    ///    (`Client.zig:1449`),但 `connectTcpOptions`(1452-1490)函数体从未读取它,
    ///    是「声明但未接线」的死字段;`request()` 走 `connect()` 也不带 Options。
    /// 结论:标准库高层 API(fetch/request)仍无可用 connect/read 超时入口,
    /// 不擅自绕过/改写标准库,字段仅作配置占位,不宣称已生效。
    connect_timeout_ms: u64 = 3_000,
    read_timeout_ms: u64 = 30_000,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpExecutor {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn executor(self: *HttpExecutor) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// 4xx/5xx 且非微信错误报文 → 折叠为 transport 错误(避免把门户 HTML 当成功);
    /// 否则把 `RawHttpResponse` 的所有权转移成 `Response{body,headers}`。
    fn foldAndWrap(gpa: std.mem.Allocator, uri: []const u8, raw: RawHttpResponse) WxResult(Response) {
        const status = raw.status;
        if (status.class() != .success and
            std.mem.indexOf(u8, raw.body, "errcode") == null and
            std.mem.indexOf(u8, raw.body, "<xml") == null)
        {
            raw.deinit(gpa);
            return .{ .err = WxError.transport(gpa, "http status {d} for {s}", .{ @backingInt(status), uri }) };
        }
        return .{ .ok = .{ .body = raw.body, .headers = raw.headers } };
    }

    /// 真实执行:回传 `Response{body,headers}`(响应头由 httpRequest 抓取)。
    fn executeExImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult(Response) {
        _ = ctx;
        const raw = httpRequest(gpa, io, method, uri, &.{}, body) catch |e|
            return .{ .err = WxError.transport(gpa, "http {s} {s}: {s}", .{ @tagName(method), uri, @errorName(e) }) };
        return foldAndWrap(gpa, uri, raw);
    }

    /// 带自定义请求头的真实执行:把 `result.Header` 转成 `std.http.Header` 交给
    /// `extra_headers`,同时回传响应头(multipart `Content-Type` 用)。
    fn executeWithHeadersImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, req_headers: []const RequestExecutor.Header, body: ?[]const u8) WxResult(Response) {
        _ = ctx;
        var extra = std.ArrayList(std.http.Header).empty;
        defer extra.deinit(gpa);
        for (req_headers) |h| {
            extra.append(gpa, .{ .name = h.name, .value = h.value }) catch
                return .{ .err = WxError.transport(gpa, "oom", .{}) };
        }
        const raw = httpRequest(gpa, io, method, uri, extra.items, body) catch |e|
            return .{ .err = WxError.transport(gpa, "http {s} {s}: {s}", .{ @tagName(method), uri, @errorName(e) }) };
        return foldAndWrap(gpa, uri, raw);
    }

    /// 只要 body 的兼容路径:委托 executeExImpl 后 `takeBody`(释放响应头、返回 body)。
    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        return switch (executeExImpl(ctx, gpa, io, method, uri, body)) {
            .err => |e| .{ .err = e },
            .ok => |r| .{ .ok = r.takeBody(gpa) },
        };
    }

    /// 三个槽一次填齐:真实通道现在能回传响应头、并接受自定义请求头。
    const vtable = RequestExecutor.VTable{
        .execute = executeImpl,
        .execute_ex = executeExImpl,
        .execute_with_headers = executeWithHeadersImpl,
    };
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

test "HttpExecutor (real std.http) vtable now carries header-capable slots" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 引用真实执行器(而非 mock)强制分析低层 httpRequest 链路;同时证明
    // Service 层现在有一条可注入「真实执行器」的构造路径(不再只有 mock 可用)。
    var http = HttpExecutor.init(gpa, io);
    const exec = http.executor();
    try std.testing.expect(exec.vtable.execute_ex != null);
    try std.testing.expect(exec.vtable.execute_with_headers != null);

    // httpRequest 在 reader() 之前调用的解析入口:能从原始 head 抓出
    // V3 验签 / Content-Type 头(纯函数、离线、无需真实网络)。
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Wechatpay-Timestamp: 1700000000\r\n" ++
        "Wechatpay-Signature: SIG\r\n" ++
        "\r\n";
    const hs = try result_mod.parseHeaders(gpa, head);
    defer result_mod.freeHeaders(gpa, hs);
    try std.testing.expectEqualStrings("application/json", result_mod.headerValue(hs, "content-type").?);
    try std.testing.expectEqualStrings("1700000000", result_mod.headerValue(hs, "WECHATPAY-TIMESTAMP").?);
    try std.testing.expectEqualStrings("SIG", result_mod.headerValue(hs, "Wechatpay-Signature").?);
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
