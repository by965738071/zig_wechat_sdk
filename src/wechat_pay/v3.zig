//! V3(JSON)接口底座 —— 对应 Java `contrib/http/*`(`WechatPayHttpClientBuilder` +
//! `WechatPay2Credential/Validator`)与 `constant/WxPayApi` 的 V3 常量部分。
//!
//! 与 V2 不同,V3 必须携带 `Authorization` 头(`WECHATPAY2-SHA256-RSA2048 ...`),
//! 而 `wechat_mp.http.RequestExecutor` 的 vtable 不带 header 参数,
//! 因此这里定义**带 header 的执行器 vtable**;真实实现 `HttpExecutor` 用 std.http fetch
//! 的 `extra_headers` 注入,测试可用 mock 捕获 header 断言格式。
//!
//! 应答验签:V3 应答头 `Wechatpay-*` 经 vtable 新增的 `execute_ex` 回传(设计一次
//! 铺开),由本文件协议层 `verifyResponse` 接成「拼验签串 + 签名验证」的接缝。
//! 真实 std.http 通道当前不回传应答头(fetch 仅给 status,见 HttpExecutor 注释),
//! 属需真实网络验证的接缝,不伪造验签结果。
//!
//! ⚠️ mTLS 缺口:V2 的 /secapi/* 与申请平台证书都需要商户证书双向 TLS,
//! `std.http` 目前不支持客户端证书 —— 真实通道留 TODO,签名/加密协议层已完整可用。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_http = @import("wechat_mp").http;
const config_mod = @import("config.zig");
pub const sign = @import("sign.zig");

pub const WxError = error_mod.WxError;
pub const WxResult = result_mod.WxResult;
pub const Method = mp_http.RequestExecutor.Method;

/// V3 接口路径前缀(对应 `WxPayApi` 里的 `/v3/...` 常量)。
pub const jsapi_order_path = "/v3/pay/transactions/jsapi";
/// `{out_trade_no}` 占位:GET 查询;拼 `?mchid=`。
pub const out_trade_no_path = "/v3/pay/transactions/out-trade-no/";

pub const Response = result_mod.Response;

/// 带 header 的 V3 请求执行器(对应 Java `CloseableHttpClient.execute(HttpUriRequest)`)。
pub const RequestExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub const VTable = struct {
        /// 成功返回响应 body 的 gpa 副本(调用方释放);header 仅供实现发请求,不承诺回传。
        execute: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, headers: []const Header, body: ?[]const u8) WxResult([]u8),
        /// 架构级扩展:带回传响应头(与 mp/http.zig 同形状)。可空,默认 null;
        /// 未覆写时 `executeEx` 回退到 `execute` 且响应头为空(诚实标注、不伪造)。
        /// V3 应答验签所需的 `Wechatpay-*` 头由此回传。
        execute_ex: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, headers: []const Header, body: ?[]const u8) WxResult(Response) = null,
    };

    pub fn execute(self: RequestExecutor, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, headers: []const Header, body: ?[]const u8) WxResult([]u8) {
        return self.vtable.execute(self.ptr, gpa, io, method, uri, headers, body);
    }

    /// 带回传响应头的执行(与 mp/http.zig `RequestExecutor.executeEx` 同形)。
    pub fn executeEx(self: RequestExecutor, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, headers: []const Header, body: ?[]const u8) WxResult(Response) {
        if (self.vtable.execute_ex) |f| return f(self.ptr, gpa, io, method, uri, headers, body);
        return switch (self.execute(gpa, io, method, uri, headers, body)) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{ .body = b, .headers = &.{} } },
        };
    }
};

/// std.http 真实实现(对应 `ApacheHttpComponentsImpl`)。
pub const HttpExecutor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    connect_timeout_ms: u64 = 3_000,
    read_timeout_ms: u64 = 30_000,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpExecutor {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn executor(self: *HttpExecutor) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: Method, uri: []const u8, headers: []const RequestExecutor.Header, body: ?[]const u8) WxResult([]u8) {
        _ = ctx;
        // TODO(mTLS): std.http 无客户端证书支持;若接口需双向 TLS 需接第三方 TLS 栈。
        var client = std.http.Client{ .allocator = gpa, .io = io };
        defer client.deinit();

        var extra = std.ArrayList(std.http.Header).empty;
        defer extra.deinit(gpa);
        for (headers) |h| extra.append(gpa, .{ .name = h.name, .value = h.value }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();

        const res = client.fetch(.{
            .location = .{ .url = uri },
            .method = switch (method) {
                .get => .GET,
                .post => .POST,
            },
            .payload = body,
            .extra_headers = extra.items,
            .response_writer = &out.writer,
        }) catch |e| return .{ .err = WxError.transport(gpa, "v3 http {s} {s}: {s}", .{ @tagName(method), uri, @errorName(e) }) };
        const resp_body = out.toOwnedSlice() catch |e| return .{
            .err = WxError.transport(gpa, "v3 response buffer: {s}", .{@errorName(e)}),
        };
        // 非 2xx 并入错误(与 mp/http.zig HttpExecutor 同步的骨架约定)。
        if (foldHttpStatus(gpa, res.status.class() == .success, @backingInt(res.status), resp_body)) |we| {
            gpa.free(resp_body);
            return .{ .err = we };
        }
        return .{ .ok = resp_body };
    }

    const vtable = RequestExecutor.VTable{ .execute = executeImpl };
};

/// V3 应答错误({"code":..,"message":..})→ WxError。
/// 对应 Java `WechatPayValidator`/`WxPayException.custom`。无错误返回 null。
pub fn v3ErrorFromJson(gpa: std.mem.Allocator, resp: []const u8) ?WxError {
    var parsed = json_util.parse(gpa, resp) catch return null;
    defer parsed.deinit();
    const code = json_util.getStr(parsed.value, "code") orelse return null;
    const msg = json_util.getStr(parsed.value, "message") orelse return null;
    return .{
        .allocator = gpa,
        .source = .wechat_api,
        .error_code = -99, // V3 错误码是字符串,数值位留 -99(对应 Java 无 errcode 的自定义异常)
        .error_msg = gpa.dupe(u8, msg) catch "",
        .error_msg_en = gpa.dupe(u8, code) catch "",
        .raw = gpa.dupe(u8, resp) catch null,
        .wx_type = .pay,
    };
}

/// 非 2xx 状态折叠为 WxError（与 mp/http.zig `HttpExecutor` 的 4xx/5xx 约定一致）。
/// 纯函数、不触碰网络，便于离线单测；按「状态码 + 响应体」判定：
///   - 2xx：返回 null（按成功透传，业务错误交给上层 `v3ErrorFromJson`）；
///   - 非 2xx 且响应体是 V3 业务错误 `{"code","message"}`：返回标准 WxError；
///   - 非 2xx 且响应体不是微信错误报文（门户 HTML 等）：折叠为 transport 错误；
///   - 非 2xx 且响应体含 errcode/<xml>：返回 null，由上层 Service 折叠。
/// 返回的 WxError 由 gpa 分配，调用方负责 deinit。
pub fn foldHttpStatus(gpa: std.mem.Allocator, status_ok: bool, status_code: u16, resp_body: []const u8) ?WxError {
    if (status_ok) return null;
    if (v3ErrorFromJson(gpa, resp_body)) |we| return we;
    if (std.mem.indexOf(u8, resp_body, "errcode") == null and
        std.mem.indexOf(u8, resp_body, "<xml") == null)
    {
        return WxError.transport(gpa, "v3 http status {d}", .{status_code});
    }
    return null;
}

// ---------------------------------------------------------------------------
// 应答验签(对应 Java `WechatPay2Validator`:验 `Wechatpay-Timestamp/Nonce` + body)
// ---------------------------------------------------------------------------

/// 应答/回调共用验签串:`timestamp\nnonce\nbody\n`。返回 gpa 分配串(调用方 free)。
pub fn buildVerifyString(gpa: std.mem.Allocator, timestamp: []const u8, nonce: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}\n", .{ timestamp, nonce, body });
}

/// 用平台证书公钥验签(对应 `Signature.verify`)。签名不符=false;PEM 格式错=BadRsaKey。
pub fn verifyWithPublicKeyPem(
    gpa: std.mem.Allocator,
    platform_pub_pem: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    body: []const u8,
    signature_b64: []const u8,
) !bool {
    const msg = try buildVerifyString(gpa, timestamp, nonce, body);
    defer gpa.free(msg);
    return sign.verifyWithPublicKeyPem(gpa, platform_pub_pem, msg, signature_b64);
}

// ---------------------------------------------------------------------------
// 应答验签协议层 —— 逐字对照 Java `v3/auth/WxPayValidator.java` +
// `bean/notify/SignatureHeader.java`(wechatpay4_1)。
//
// 这是「接缝」:把 `RequestExecutor.executeEx` 回传的 `Response{body,headers}`
// 接成 WxPayValidator.validate 的完整判定链。平台证书公钥是**凭证**,由调用方
// 注入(`platform_pub_pem`),本层老老实实调 `sign.verifyWithPublicKeyPem` 做真实
// RSA 验签,不伪造「验证通过」结果。真实 std.http 通道目前不回传应答头(见
// HttpExecutor 注释),故此处离线可测,真联调需真实网络 + 真实平台证书。
// ---------------------------------------------------------------------------

/// 对应 Java `WxPayValidator.DEFAULT_TIMESTAMP_TOLERANCE_SECONDS`(5 分钟)。
pub const default_timestamp_tolerance_seconds: i64 = 5 * 60;

/// 对应 Java `bean/notify/SignatureHeader`:应答验签头四元组。
pub const SignatureHeader = struct {
    timestamp: []const u8,
    nonce: []const u8,
    signature: []const u8,
    serial: []const u8,
};

/// 从响应头提取验签四元组(大小写不敏感,对应 WxPayValidator.validate 里四个
/// `response.getFirstHeader("Wechatpay-...")`)。任一缺失返回 null
/// (对应 Java `if (timestamp == null || ... ) return false`)。
/// 注:Java 用 `Wechatpay-TimeStamp`,HTTP 头名大小写不敏感,故这里统一写
/// `Wechatpay-Timestamp` 也能命中。
pub fn signatureHeaderFrom(headers: []const result_mod.Header) ?SignatureHeader {
    return .{
        .timestamp = result_mod.headerValue(headers, "Wechatpay-Timestamp") orelse return null,
        .nonce = result_mod.headerValue(headers, "Wechatpay-Nonce") orelse return null,
        .signature = result_mod.headerValue(headers, "Wechatpay-Signature") orelse return null,
        .serial = result_mod.headerValue(headers, "Wechatpay-Serial") orelse return null,
    };
}

/// 对应 Java `WxPayValidator.isTimestampFresh` 的解析段:
/// `Long.parseLong(timestamp.trim())`,解析失败或负值返回 null。
pub fn parseTimestamp(timestamp: []const u8) ?i64 {
    const t = std.fmt.parseInt(i64, std.mem.trim(u8, timestamp, " \t"), 10) catch return null;
    if (t < 0) return null; // 对应 Java `if (responseTime < 0) return false`
    return t;
}

/// 对应 Java `WxPayValidator.isTimestampFresh`(防重放):
///  - tolerance <= 0:关闭校验,恒 true;
///  - 解析失败/负值:false;
///  - |now - ts| > tolerance:false;否则 true。
/// `now_seconds` 由调用方注入(对应 Java 可注入的 `LongSupplier currentTimeSeconds`),
/// 使离线单测可用可控时钟。
pub fn isTimestampFresh(timestamp: []const u8, now_seconds: i64, tolerance_seconds: i64) bool {
    if (tolerance_seconds <= 0) return true;
    const ts = parseTimestamp(timestamp) orelse return false;
    const diff = now_seconds - ts;
    const abs_diff: i64 = if (diff < 0) -diff else diff;
    return abs_diff <= tolerance_seconds;
}

/// 对应 Java `WxPayValidator.validate` 开头的 Content-Type 判定:
/// 只有 `application/json` 应答参与验签(非 JSON,如文件下载/204,Java 直接 `return true`)。
/// 带 `; charset=...` 时只取 mime 段,大小写不敏感。头缺失/空视为非 JSON -> 跳过。
pub fn isJsonContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
    const mime = std.mem.trim(u8, ct[0..semi], " \t");
    return std.ascii.eqlIgnoreCase(mime, "application/json");
}

/// 应答验签结果(把 Java validate 的各条 `return` 分支显式化,便于离线断言)。
pub const VerifyOutcome = union(enum) {
    /// 签名验证通过。
    verified,
    /// 非 application/json:按 Java `return true` 跳过验签。
    skipped_non_json,
    /// 四个 Wechatpay-* 头缺一:对应 Java `return false`。
    missing_header,
    /// Wechatpay-Timestamp 非法(非数字/负数):对应 Java `return false`。
    invalid_timestamp,
    /// 时间戳与本地时钟偏差超过容差:对应 Java `return false`。
    stale_timestamp,
    /// RSA 验签不通过(签名不符或报文被篡改)。
    signature_mismatch,
    /// PEM/base64 解码等错误(对应 BadRsaKey),不是「验签不通过」而是无法验证。
    crypto_error: anyerror,

    /// 是否可视为「应答有效」(verified 或按 Java 跳过的非 JSON)。
    pub fn passed(self: VerifyOutcome) bool {
        return switch (self) {
            .verified, .skipped_non_json => true,
            else => false,
        };
    }
};

/// 应答验签接缝(对应 `WxPayValidator.validate(CloseableHttpResponse)`):
///   Content-Type 判定 -> 取 4 头 -> 时间戳新鲜度 -> 拼 `timestamp\nnonce\nbody\n`
///   -> `sign.verifyWithPublicKeyPem(platform_pub_pem, msg, signature)`。
/// 平台证书公钥 `platform_pub_pem` 是凭证,由调用方注入;本函数做**真实** RSA
/// 验签,不伪造结果。`serial` 头按 Java 要求必须存在,但骨架用单一注入公钥,
/// 不做「按证书序列号选证书」(真实多证书需证书管理器,属联调范畴)。
pub fn verifyResponse(
    gpa: std.mem.Allocator,
    resp: Response,
    platform_pub_pem: []const u8,
    now_seconds: i64,
    tolerance_seconds: i64,
) VerifyOutcome {
    if (!isJsonContentType(result_mod.headerValue(resp.headers, "Content-Type")))
        return .skipped_non_json;

    const sh = signatureHeaderFrom(resp.headers) orelse return .missing_header;

    const ts = parseTimestamp(sh.timestamp) orelse return .invalid_timestamp;
    if (tolerance_seconds > 0) {
        const diff = now_seconds - ts;
        const abs_diff: i64 = if (diff < 0) -diff else diff;
        if (abs_diff > tolerance_seconds) return .stale_timestamp;
    }

    const msg = buildVerifyString(gpa, sh.timestamp, sh.nonce, resp.body) catch |e| return .{ .crypto_error = e };
    defer gpa.free(msg);
    const ok = sign.verifyWithPublicKeyPem(gpa, platform_pub_pem, msg, sh.signature) catch |e| return .{ .crypto_error = e };
    return if (ok) .verified else .signature_mismatch;
}

// ---------------------------------------------------------------------------
// 结果对象(对应 bean/... V3 POJO 的常用字段子集;字段 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

fn dupeStr(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) ![]u8 {
    const s = json_util.getStr(v, key) orelse return gpa.dupe(u8, "");
    return gpa.dupe(u8, s);
}

/// 对应 JSAPI 下单响应 `WxPayUnifiedOrderV3Result`({prepay_id})。
pub const JsapiOrderResult = struct {
    gpa: std.mem.Allocator,
    prepay_id: []u8 = "",

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !JsapiOrderResult {
        return .{ .gpa = gpa, .prepay_id = try dupeStr(gpa, v, "prepay_id") };
    }
    pub fn deinit(self: *JsapiOrderResult) void {
        self.gpa.free(self.prepay_id);
        self.* = undefined;
    }
};

/// 对应 V3 查单 `WxPayOrderQueryV3Result`(常用字段子集)。
pub const OrderResult = struct {
    gpa: std.mem.Allocator,
    trade_state: []u8 = "",
    trade_state_desc: []u8 = "",
    out_trade_no: []u8 = "",
    transaction_id: []u8 = "",
    success_time: []u8 = "",

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !OrderResult {
        var self = OrderResult{ .gpa = gpa };
        errdefer self.deinit();
        self.trade_state = try dupeStr(gpa, v, "trade_state");
        self.trade_state_desc = try dupeStr(gpa, v, "trade_state_desc");
        self.out_trade_no = try dupeStr(gpa, v, "out_trade_no");
        self.transaction_id = try dupeStr(gpa, v, "transaction_id");
        self.success_time = try dupeStr(gpa, v, "success_time");
        return self;
    }
    pub fn deinit(self: *OrderResult) void {
        const g = self.gpa;
        for ([_][]u8{ self.trade_state, self.trade_state_desc, self.out_trade_no, self.transaction_id, self.success_time }) |s| g.free(s);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "v3 path constants" {
    try std.testing.expectEqualStrings("/v3/pay/transactions/jsapi", jsapi_order_path);
    try std.testing.expectEqualStrings("/v3/pay/transactions/out-trade-no/", out_trade_no_path);
}

test "v3 error json mapping" {
    const gpa = std.testing.allocator;
    var e = v3ErrorFromJson(gpa, "{\"code\":\"ORDERPAID\",\"message\":\"订单已支付\"}").?;
    defer e.deinit();
    try std.testing.expectEqualStrings("ORDERPAID", e.error_msg_en);
    try std.testing.expectEqualStrings("订单已支付", e.error_msg);
    try std.testing.expect(v3ErrorFromJson(gpa, "{\"prepay_id\":\"wx1\"}") == null);
    try std.testing.expect(v3ErrorFromJson(gpa, "not json") == null);
}

test "v3 foldHttpStatus (mirrors mp/http.zig 4xx/5xx)" {
    const gpa = std.testing.allocator;
    // 2xx 一律透传
    try std.testing.expect(foldHttpStatus(gpa, true, 200, "anything") == null);
    try std.testing.expect(foldHttpStatus(gpa, true, 200, "{\"code\":\"X\",\"message\":\"y\"}") == null);

    // 非 2xx + V3 业务错误体 → 标准 WxError
    {
        var e = foldHttpStatus(gpa, false, 400, "{\"code\":\"ORDERPAID\",\"message\":\"订单已支付\"}").?;
        defer e.deinit();
        try std.testing.expectEqualStrings("ORDERPAID", e.error_msg_en);
        try std.testing.expectEqualStrings("订单已支付", e.error_msg);
        try std.testing.expectEqual(WxError.Source.wechat_api, e.source);
    }

    // 非 2xx + 门户 HTML（既无 errcode、也无 <xml>、也不是 V3 错误）→ transport 错误
    {
        var e = foldHttpStatus(gpa, false, 502, "<html>bad gateway</html>").?;
        defer e.deinit();
        try std.testing.expectEqual(WxError.Source.transport, e.source);
        try std.testing.expectEqual(@as(i64, -1), e.error_code);
        try std.testing.expect(std.mem.indexOf(u8, e.error_msg, "502") != null);
    }

    // 非 2xx + 含 errcode / <xml> 的报文 → 交上层 Service 折叠（返回 null）
    try std.testing.expect(foldHttpStatus(gpa, false, 400, "{\"errcode\":40001,\"errmsg\":\"x\"}") == null);
    try std.testing.expect(foldHttpStatus(gpa, false, 400, "<xml><return_code>FAIL</return_code></xml>") == null);
}

test "v3 verify string + response verify with embedded key" {
    const gpa = std.testing.allocator;
    const ts = "1700000000";
    const nonce = "AAAABBBBCCCC";
    const body = "{\"trade_state\":\"SUCCESS\"}";
    const msg = try buildVerifyString(gpa, ts, nonce, body);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("1700000000\nAAAABBBBCCCC\n{\"trade_state\":\"SUCCESS\"}\n", msg);

    var ks = try sign.KeySigner.fromPem(gpa, sign.TEST_PRIV_PEM);
    defer ks.deinit();
    const sig = try ks.signBase64(gpa, msg);
    defer gpa.free(sig);
    try std.testing.expect(try verifyWithPublicKeyPem(gpa, sign.TEST_PUB_PEM, ts, nonce, body, sig));
    // 篡改 body → 验不过
    try std.testing.expect(!(try verifyWithPublicKeyPem(gpa, sign.TEST_PUB_PEM, ts, nonce, "{}", sig)));
}

// ---- V3 应答验签协议层(逐字对照 WxPayValidator)离线单测 ----

/// 构造一份「合法签名」的应答:用内嵌测试私钥对 `timestamp\nnonce\nbody\n` 真签名,
/// 放进 Wechatpay-* 响应头。这是真实 RSA 验签,不伪造验证结果。
fn signedResponse(gpa: std.mem.Allocator, ts: []const u8, nonce: []const u8, body: []const u8, extra_ct: ?[]const u8) !struct { resp: Response, sig: []u8 } {
    const msg = try buildVerifyString(gpa, ts, nonce, body);
    defer gpa.free(msg);
    var ks = try sign.KeySigner.fromPem(gpa, sign.TEST_PRIV_PEM);
    defer ks.deinit();
    const sig = try ks.signBase64(gpa, msg);

    const n: usize = if (extra_ct != null) 5 else 4;
    const hs = try gpa.alloc(result_mod.Header, n);
    hs[0] = .{ .name = try gpa.dupe(u8, "Wechatpay-Timestamp"), .value = try gpa.dupe(u8, ts) };
    hs[1] = .{ .name = try gpa.dupe(u8, "Wechatpay-Nonce"), .value = try gpa.dupe(u8, nonce) };
    hs[2] = .{ .name = try gpa.dupe(u8, "Wechatpay-Signature"), .value = try gpa.dupe(u8, sig) };
    hs[3] = .{ .name = try gpa.dupe(u8, "Wechatpay-Serial"), .value = try gpa.dupe(u8, "SERIAL1") };
    if (extra_ct) |ct| hs[4] = .{ .name = try gpa.dupe(u8, "Content-Type"), .value = try gpa.dupe(u8, ct) };
    return .{ .resp = .{ .body = try gpa.dupe(u8, body), .headers = hs }, .sig = sig };
}

test "signatureHeaderFrom: extracts 4 headers case-insensitively, null on missing" {
    const hs = [_]result_mod.Header{
        .{ .name = "wechatpay-timestamp", .value = "1700000000" },
        .{ .name = "Wechatpay-Nonce", .value = "N" },
        .{ .name = "WECHATPAY-SIGNATURE", .value = "S" },
        .{ .name = "Wechatpay-Serial", .value = "SER" },
    };
    const sh = signatureHeaderFrom(&hs).?;
    try std.testing.expectEqualStrings("1700000000", sh.timestamp);
    try std.testing.expectEqualStrings("N", sh.nonce);
    try std.testing.expectEqualStrings("S", sh.signature);
    try std.testing.expectEqualStrings("SER", sh.serial);
    // 缺一个头 -> null(对应 Java return false)
    try std.testing.expect(signatureHeaderFrom(hs[0..3]) == null);
}

test "parseTimestamp / isTimestampFresh: WxPayValidator replay guard" {
    // 解析:trim + 非数字/负数 -> null
    try std.testing.expectEqual(@as(i64, 1700000000), parseTimestamp(" 1700000000 ").?);
    try std.testing.expect(parseTimestamp("not-a-number") == null);
    try std.testing.expect(parseTimestamp("-1") == null); // Java 拒绝负值

    // 容差判定(可控时钟 now=1700000000,tol=300)
    const now: i64 = 1700000000;
    try std.testing.expect(isTimestampFresh("1700000000", now, 300)); // 边界内
    try std.testing.expect(isTimestampFresh("1699999750", now, 300)); // 差 250
    try std.testing.expect(!isTimestampFresh("1699999600", now, 300)); // 差 400 > 300
    try std.testing.expect(!isTimestampFresh("bad", now, 300)); // 非法
    try std.testing.expect(!isTimestampFresh("-5", now, 300)); // 负值
    try std.testing.expect(isTimestampFresh("1", now, 0)); // 容差<=0 关闭校验恒 true
}

test "isJsonContentType: Java validate Content-Type gate" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("Application/JSON"));
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType(null)); // 头缺失 -> 跳过
}

/// 断言 VerifyOutcome 的活动标签(tagged union 不能直接与 `Union.tag` 比较)。
fn expectTag(comptime want: std.meta.Tag(VerifyOutcome), out: VerifyOutcome) !void {
    try std.testing.expectEqual(want, std.meta.activeTag(out));
}

test "verifyResponse protocol seam: verified / tampered / stale / missing / non-json" {
    const gpa = std.testing.allocator;
    const ts = "1700000000";
    const nonce = "NONCE1";
    const body = "{\"trade_state\":\"SUCCESS\"}";

    // 1) 合法签名 + JSON Content-Type -> verified(真实 RSA)
    {
        const s = try signedResponse(gpa, ts, nonce, body, "application/json");
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        const out = verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000000, 300);
        try expectTag(.verified, out);
        try std.testing.expect(out.passed());
    }
    // 2) 篡改 body -> signature_mismatch
    {
        var s = try signedResponse(gpa, ts, nonce, body, "application/json");
        defer gpa.free(s.sig);
        gpa.free(s.resp.body);
        s.resp.body = try gpa.dupe(u8, "{\"trade_state\":\"FAIL\"}");
        defer s.resp.deinit(gpa);
        try expectTag(.signature_mismatch, verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000000, 300));
    }
    // 3) 时间戳超差(重放) -> stale_timestamp(签名本身合法,但被新鲜度拦下)
    {
        const s = try signedResponse(gpa, ts, nonce, body, "application/json");
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        try expectTag(.stale_timestamp, verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000500, 300));
    }
    // 4) 非法时间戳 -> invalid_timestamp
    {
        const s = try signedResponse(gpa, "BAD", nonce, body, "application/json");
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        try expectTag(.invalid_timestamp, verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000000, 300));
    }
    // 5) 缺一个 Wechatpay 头(Serial)-> missing_header;保留 Content-Type 才走到取头
    {
        const s = try signedResponse(gpa, ts, nonce, body, "application/json");
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        // [0..3]=timestamp/nonce/signature(缺 serial),[4]=Content-Type
        const keep = [_]result_mod.Header{ s.resp.headers[0], s.resp.headers[1], s.resp.headers[2], s.resp.headers[4] };
        const cut = try result_mod.dupeHeaders(gpa, &keep); // 深拷贝,避免双重释放
        const resp2 = Response{ .body = try gpa.dupe(u8, s.resp.body), .headers = cut };
        defer resp2.deinit(gpa);
        try expectTag(.missing_header, verifyResponse(gpa, resp2, sign.TEST_PUB_PEM, 1700000000, 300));
    }
    // 6) 非 JSON Content-Type -> skipped_non_json(Java return true),不验签
    {
        const s = try signedResponse(gpa, ts, nonce, body, "text/plain");
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        const out = verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000000, 300);
        try expectTag(.skipped_non_json, out);
        try std.testing.expect(out.passed());
    }
    // 7) 无 Content-Type 头 -> 也按非 JSON 跳过(与 Java 的 null 行为一致)
    {
        const s = try signedResponse(gpa, ts, nonce, body, null);
        defer s.resp.deinit(gpa);
        defer gpa.free(s.sig);
        try expectTag(.skipped_non_json, verifyResponse(gpa, s.resp, sign.TEST_PUB_PEM, 1700000000, 300));
    }
}
