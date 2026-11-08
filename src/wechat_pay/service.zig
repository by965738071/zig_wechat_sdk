//! 微信支付服务门面 —— 对应 Java `service.impl.BaseWxPayServiceImpl`(约 1600 行)。
//!
//! 协议面(与 Java 同名方法一一对应):
//! - **V2(XML+MD5/HMAC)**:统一签名 → XML POST → 响应**原始 xml** 解析出 map →
//!   就地验签(checkSign 基于原始字段,不能重新序列化后算);
//!   `orderQuery/closeOrder/reverse/refund/refundQuery` 对应 Java 同名方法。
//!   ⚠️ mTLS 缺口:`refund(/secapi/pay/refund)` 与 `reverse(/secapi/pay/reverse)`
//!   在 Java 里走 `httpExecuteWithCertificate`(商户证书双向 TLS);
//!   `std.http` 无客户端证书支持 —— 协议层完整,真实网络通道留 TODO。
//! - **V3(JSON+RSA+AES-GCM)**:Authorization 头签名走 `sign.KeySigner`
//!   (vendored zig-rsa),执行器用 `v3.RequestExecutor`(带 header);
//!   回调解密/验签在 `notify.zig`/`crypt.zig`。
const std = @import("std");
const xml = @import("common").xml;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const random_mod = @import("common").random;
const mp_http = @import("wechat_mp").http;
const config_mod = @import("config.zig");
const sign_mod = @import("sign.zig");
const v2_mod = @import("v2.zig");
pub const v3 = @import("v3.zig");
pub const notify = @import("notify.zig");
pub const crypt = @import("crypt.zig");
pub const mtls = @import("mtls.zig");

pub const WxError = error_mod.WxError;
pub const WxResult = result_mod.WxResult;
pub const RequestExecutor = mp_http.RequestExecutor;

const unified_order_url = "https://api.mch.weixin.qq.com/pay/unifiedorder";
const refund_url = "https://api.mch.weixin.qq.com/secapi/pay/refund";

/// V3 请求头随机量注入口(测试确定性;生产传 null 自动生成)。
pub const NonceTs = struct { nonce: []const u8, timestamp: []const u8 };

pub const PayService = struct {
    gpa: std.mem.Allocator,
    cfg: *config_mod.PayConfig,
    exec: RequestExecutor,
    /// V3 RSA 签名器(桩=未配置密钥;真实实现 `sign.KeySigner.signer()`)
    rsa: sign_mod.RsaSigner = sign_mod.RsaSigner.stub,
    /// V3 执行器(带 Authorization 头);null → V3 方法报配置错误
    v3exec: ?v3.RequestExecutor = null,
    /// V3 平台证书公钥 PEM(**借用**,调用方保活);null → 不做应答/回调验签
    platform_pub_pem: ?[]const u8 = null,
    /// 商户客户端证书提供者接缝(mTLS)。null → 需证书的接口自检报 missing_cert。
    /// 真实双向 TLS 需外部 TLS 栈 + 真实 p12 证书,见 `mtls.zig` 调研结论,不伪造。
    client_cert: ?mtls.CertProvider = null,

    pub fn init(gpa: std.mem.Allocator, cfg: *config_mod.PayConfig, exec: RequestExecutor) PayService {
        return .{ .gpa = gpa, .cfg = cfg, .exec = exec };
    }

    /// 发请求前的 mTLS 自检接缝(对应 Java `post(url, xml, true)` 的 useCertificate):
    /// 返回 `mtls.CheckOutcome`,调用方可据此决定是否继续。纯逻辑、离线可测,
    /// 不执行真实 TLS 握手(见 mtls.zig)。未注入 provider 时用空占位。
    pub fn mtlsStatus(self: *PayService, path: []const u8) mtls.CheckOutcome {
        var empty = mtls.InMemoryCertProvider{};
        const provider = self.client_cert orelse empty.provider();
        return mtls.check(path, provider);
    }

    /// 把字段列表序列化为带 CDATA 的 <xml> 并签名(sign 字段最后追加)。
    fn signedXml(self: *PayService, fields: []const sign_mod.Field) ![]u8 {
        const s = try sign_mod.signV2(self.gpa, fields, self.cfg.mch_key, self.cfg.sign_type);
        defer self.gpa.free(s);
        var b = xml.Builder.init(self.gpa);
        defer b.deinit();
        for (fields) |f| try b.addIfNotEmpty(f.key, f.value);
        try b.add("sign", s);
        return b.finish(true);
    }

    /// 16 字符随机 nonce(对应 `RandomUtils.getRandomStr()`)。gpa 分配,调用方 free。
    fn nonce16(self: *PayService, io: std.Io) ![]u8 {
        return random_mod.randomStr16(self.gpa, io);
    }

    // -----------------------------------------------------------------------
    // V2 通道
    // -----------------------------------------------------------------------

    /// V2 公共链路:组公共字段(appid/mch_id/nonce_str)→ 签名 XML → POST →
    /// 响应验签。返回响应原始 xml(gpa 分配,调用方 free)。
    fn v2Post(
        self: *PayService,
        io: std.Io,
        url_path: []const u8,
        extra: []const sign_mod.Field,
    ) WxResult([]u8) {
        const gpa = self.gpa;
        const nonce = self.nonce16(io) catch |e|
            return .{ .err = WxError.transport(gpa, "nonce: {s}", .{@errorName(e)}) };
        defer gpa.free(nonce);

        var fields = std.ArrayList(sign_mod.Field).empty;
        defer fields.deinit(gpa);
        // sub_appid/sub_mch_id 对应 `BaseWxPayRequest.checkAndSign` 从 config 回退;
        // 空值由 addIfNotEmpty/buildSignString 跳过,直连商户签名不变。
        const common = [_]sign_mod.Field{
            .{ .key = "appid", .value = self.cfg.appid },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "sub_appid", .value = self.cfg.sub_appid },
            .{ .key = "sub_mch_id", .value = self.cfg.sub_mch_id },
            .{ .key = "nonce_str", .value = nonce },
        };
        for (common) |f| fields.append(gpa, f) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        for (extra) |f| fields.append(gpa, f) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };

        const req_xml = self.signedXml(fields.items) catch |e|
            return .{ .err = WxError.internal(gpa, "sign xml: {s}", .{@errorName(e)}) };
        defer gpa.free(req_xml);

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ v2_mod.api_host, url_path }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(uri);

        return switch (self.exec.execute(gpa, io, .post, uri, req_xml)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp); // 验签函数的返回值是独立副本,原响应在此释放
                break :blk self.verifyV2Xml(resp);
            },
        };
    }

    /// 响应原始 xml → 结构化结果 + 业务状态检查(对应 Java `checkResult` 层层校验:
    /// return_code 与 result_code 任一 FAIL 都抛异常,这里折叠为 WxError)。
    fn parseV2(self: *PayService, comptime T: type, resp_xml: []const u8) WxResult(T) {
        const gpa = self.gpa;
        var m = xml.parse(gpa, resp_xml) catch |e|
            return .{ .err = WxError.cryptoError(gpa, "pay xml parse: {s}", .{@errorName(e)}) };
        defer xml.freeMap(&m);

        var r = T.fromMap(gpa, m) catch
            return .{ .err = WxError.transport(gpa, "pay result oom", .{}) };
        // T 可能是 BaseResult 自身(close/reverse 直接返回 BaseResult),
        // 也可能是嵌套 base 的复合结果;comptime 分支消除即可。
        const is_plain_base = T == v2_mod.BaseResult;
        const ok_flag = if (is_plain_base) r.businessOk() else r.base.businessOk();
        if (!ok_flag) {
            const b: *const v2_mod.BaseResult = if (is_plain_base) &r else &r.base;
            const des = if (b.err_code_des.len > 0) b.err_code_des else b.return_msg;
            const e = WxError{
                .allocator = gpa,
                .source = .wechat_api,
                .error_code = -99,
                .error_msg = gpa.dupe(u8, des) catch "",
                .error_msg_en = gpa.dupe(u8, b.err_code) catch "",
                .raw = gpa.dupe(u8, resp_xml) catch null,
                .wx_type = .pay,
            };
            r.deinit();
            return .{ .err = e };
        }
        return .{ .ok = r };
    }

    /// V2 统一下单(代表接口)。对应 `createOrder(WxPayUnifiedOrderRequest)`。
    /// 返回响应**原始 xml**(调用方释放);已就地完成验签(失败 → 错误)。
    pub fn unifiedOrder(self: *PayService, io: std.Io, out_trade_no: []const u8, total_fee: []const u8, body: []const u8) WxResult([]u8) {
        const nonce = self.nonce16(io) catch |e|
            return .{ .err = WxError.transport(self.gpa, "nonce: {s}", .{@errorName(e)}) };
        defer self.gpa.free(nonce);
        // 对应 `WxPayUnifiedOrderRequest.checkAndSign`:
        //  - trade_type 回退 cfg.trade_type(仍为空则 JSAPI);
        //  - sub_appid/sub_mch_id 由 BaseWxPayRequest.checkAndSign 从 config 回退填充。
        // 空值的字段在 signedXml(addIfNotEmpty) 与 buildSignString 里都会被跳过,
        // 故直连商户(未配置子商户)时签名/XML 与旧版完全一致。
        const fields = [_]sign_mod.Field{
            .{ .key = "appid", .value = self.cfg.appid },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "sub_appid", .value = self.cfg.sub_appid },
            .{ .key = "sub_mch_id", .value = self.cfg.sub_mch_id },
            .{ .key = "nonce_str", .value = nonce },
            .{ .key = "notify_url", .value = self.cfg.notify_url },
            .{ .key = "out_trade_no", .value = out_trade_no },
            .{ .key = "body", .value = body },
            .{ .key = "total_fee", .value = total_fee },
            .{ .key = "trade_type", .value = self.cfg.effectiveTradeType() },
        };
        const req_xml = self.signedXml(&fields) catch |e|
            return .{ .err = WxError.internal(self.gpa, "sign xml: {s}", .{@errorName(e)}) };
        defer self.gpa.free(req_xml);

        return switch (self.exec.execute(self.gpa, io, .post, unified_order_url, req_xml)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer self.gpa.free(resp); // 验签函数的返回值是独立副本,原响应在此释放
                break :blk self.verifyV2Xml(resp);
            },
        };
    }

    /// 对应 `queryOrder(outTradeNo)` / `queryOrderById(transactionId)`:
    /// 二者取其一(非空的那个参与签名)。POST /pay/orderquery。
    pub const OrderQueryArgs = struct {
        out_trade_no: []const u8 = "",
        transaction_id: []const u8 = "",
    };
    pub fn orderQuery(self: *PayService, io: std.Io, args: OrderQueryArgs) WxResult(v2_mod.OrderQueryResult) {
        const fields = [_]sign_mod.Field{
            .{ .key = "out_trade_no", .value = args.out_trade_no },
            .{ .key = "transaction_id", .value = args.transaction_id },
        };
        const resp = switch (self.v2Post(io, v2_mod.url.order_query, &fields)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);
        return self.parseV2(v2_mod.OrderQueryResult, resp);
    }

    /// 对应 `closeOrder(outTradeNo)`。POST /pay/closeorder。
    pub fn closeOrder(self: *PayService, io: std.Io, out_trade_no: []const u8) WxResult(v2_mod.BaseResult) {
        const fields = [_]sign_mod.Field{.{ .key = "out_trade_no", .value = out_trade_no }};
        const resp = switch (self.v2Post(io, v2_mod.url.close_order, &fields)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);
        return self.parseV2(v2_mod.BaseResult, resp);
    }

    /// 对应 `reverse(outTradeNo)`。POST /secapi/pay/reverse。
    /// mTLS:Java `post(url, xml, true)` 需商户证书。Zig 侧 `mtlsStatus(path)` 提供
    /// 自检接缝(需证书路径判定 + 证书配置检查);真实双向 TLS 需外部 TLS 栈 +
    /// 真实 p12 证书 + 网络验证,见 `mtls.zig`,不伪造。协议层(签名/XML)已完整。
    pub fn reverse(self: *PayService, io: std.Io, out_trade_no: []const u8) WxResult(v2_mod.BaseResult) {
        const fields = [_]sign_mod.Field{.{ .key = "out_trade_no", .value = out_trade_no }};
        const resp = switch (self.v2Post(io, v2_mod.url.reverse, &fields)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);
        return self.parseV2(v2_mod.BaseResult, resp);
    }

    /// 对应 `refund(WxPayRefundRequest)` 常用字段子集。POST /secapi/pay/refund。
    /// mTLS:同 `reverse`,`mtlsStatus(path)` 自检 + `mtls.zig` 协议层接缝;
    /// 当前执行器仅发普通 HTTPS,真实双向 TLS 通道待接(不伪造已生效)。
    pub const RefundArgs = struct {
        out_trade_no: []const u8 = "",
        transaction_id: []const u8 = "",
        out_refund_no: []const u8 = "",
        total_fee: []const u8 = "",
        refund_fee: []const u8 = "",
        refund_desc: []const u8 = "",
        /// 空→cfg.refund_notify_url(对应 Java `WxPayRefundRequest.checkAndSign`
        /// 回退到 `WxPayConfig.getRefundNotifyUrl()`,而非支付回调 notifyUrl)。
        notify_url: []const u8 = "",
    };
    pub fn refund(self: *PayService, io: std.Io, args: RefundArgs) WxResult(v2_mod.RefundResult) {
        const notify_url = if (args.notify_url.len > 0) args.notify_url else self.cfg.refund_notify_url;
        const fields = [_]sign_mod.Field{
            .{ .key = "out_trade_no", .value = args.out_trade_no },
            .{ .key = "transaction_id", .value = args.transaction_id },
            .{ .key = "out_refund_no", .value = args.out_refund_no },
            .{ .key = "total_fee", .value = args.total_fee },
            .{ .key = "refund_fee", .value = args.refund_fee },
            .{ .key = "refund_desc", .value = args.refund_desc },
            .{ .key = "notify_url", .value = notify_url },
        };
        // refund_url 常量与 v2_mod.url.refund 同值,保留旧常量以兼容既有引用点。
        _ = refund_url;
        const resp = switch (self.v2Post(io, v2_mod.url.refund, &fields)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);
        return self.parseV2(v2_mod.RefundResult, resp);
    }

    /// 对应 `queryRefund(WxPayRefundQueryRequest)`:四个单号定位字段取非空者。
    /// POST /pay/refundquery。
    pub const RefundQueryArgs = struct {
        out_trade_no: []const u8 = "",
        transaction_id: []const u8 = "",
        out_refund_no: []const u8 = "",
        refund_id: []const u8 = "",
    };
    pub fn refundQuery(self: *PayService, io: std.Io, args: RefundQueryArgs) WxResult(v2_mod.RefundQueryResult) {
        const fields = [_]sign_mod.Field{
            .{ .key = "out_trade_no", .value = args.out_trade_no },
            .{ .key = "transaction_id", .value = args.transaction_id },
            .{ .key = "out_refund_no", .value = args.out_refund_no },
            .{ .key = "refund_id", .value = args.refund_id },
        };
        const resp = switch (self.v2Post(io, v2_mod.url.refund_query, &fields)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);
        return self.parseV2(v2_mod.RefundQueryResult, resp);
    }

    /// V2 响应/回调统一验签:原始 xml → 扁平 map(保留全部字段)→ checkSign。
    /// 对应 `BaseWxPayResult` 从**原始报文**构造再验签的细节。
    pub fn verifyV2Xml(self: *PayService, resp_xml: []const u8) WxResult([]u8) {
        var m = xml.parse(self.gpa, resp_xml) catch |e|
            return .{ .err = WxError.cryptoError(self.gpa, "pay xml parse: {s}", .{@errorName(e)}) };
        defer xml.freeMap(&m);

        const fields = v2_mod.mapToFields(self.gpa, &m) catch
            return .{ .err = WxError.transport(self.gpa, "oom", .{}) };
        defer self.gpa.free(fields);

        const ok = sign_mod.checkSign(self.gpa, fields, self.cfg.mch_key, self.cfg.sign_type) catch |e|
            return .{ .err = WxError.internal(self.gpa, "checksign: {s}", .{@errorName(e)}) };
        if (!ok) return .{ .err = WxError.cryptoError(self.gpa, "pay 响应验签失败", .{}) };
        // 业务层再自行 parse 一次拿字段
        return .{ .ok = self.gpa.dupe(u8, resp_xml) catch return .{ .err = WxError.transport(self.gpa, "oom", .{}) } };
    }

    // -----------------------------------------------------------------------
    // V3 通道
    // -----------------------------------------------------------------------

    /// V3 公共链路:组 Authorization 头(RSA 签名)→ 带 header 执行器发请求。
    /// 返回响应 body(gpa 分配,调用方 free)。`inject` 非空时用固定 nonce/时间戳
    /// (纯函数式注入,保证测试确定性)。
    /// 内部委托 `v3SendEx` 取回带响应头的 `Response`,再 `takeBody` 只要 body;
    /// 未覆写 `execute_ex` 的执行器会回退到 `execute`,行为与旧版完全一致。
    pub fn v3Send(
        self: *PayService,
        io: std.Io,
        method: v3.Method,
        url_path: []const u8,
        body: ?[]const u8,
        inject: ?NonceTs,
    ) WxResult([]u8) {
        return switch (self.v3SendEx(io, method, url_path, body, inject)) {
            .err => |e| .{ .err = e },
            .ok => |resp| .{ .ok = resp.takeBody(self.gpa) },
        };
    }

    /// 与 v3Send 同链路,但返回**带响应头**的完整 `Response`(经 `executeEx`)。
    /// 这是 V3 应答验签的取头入口:调用方拿到后可传给 `verifyV3ResponseFrom`。
    /// 真实 std.http 通道当前回传空头(fetch 仅给 status,详见 v3.HttpExecutor 注释),
    /// 需真实网络 + 真实平台证书才能完成真联调;此处为协议层/接缝。
    pub fn v3SendEx(
        self: *PayService,
        io: std.Io,
        method: v3.Method,
        url_path: []const u8,
        body: ?[]const u8,
        inject: ?NonceTs,
    ) WxResult(v3.Response) {
        const gpa = self.gpa;
        const exec = self.v3exec orelse
            return .{ .err = WxError.configError(gpa, "V3 执行器未注入(PayService.v3exec)", .{}) };

        var nbuf: [16]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        var nonce: []const u8 = "";
        var ts: []const u8 = "";
        if (inject) |inj| {
            nonce = inj.nonce;
            ts = inj.timestamp;
        } else {
            random_mod.randomStr(io, &nbuf) catch |e|
                return .{ .err = WxError.transport(gpa, "nonce: {s}", .{@errorName(e)}) };
            nonce = &nbuf;
            const secs = @divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
            var tw: std.Io.Writer = .fixed(&tbuf);
            tw.print("{d}", .{secs}) catch
                return .{ .err = WxError.internal(gpa, "timestamp fmt", .{}) };
            ts = tw.buffered();
        }

        const mstr = switch (method) {
            .get => "GET",
            .post => "POST",
        };
        const auth = sign_mod.authorizationFor(gpa, self.cfg, self.rsa, mstr, url_path, ts, nonce, body orelse "") catch |e|
            return .{ .err = WxError.cryptoError(gpa, "V3 请求签名失败: {s}", .{@errorName(e)}) };
        defer gpa.free(auth);

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ v2_mod.api_host, url_path }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const headers = [_]v3.RequestExecutor.Header{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "weixin-java-sdk-zig/0.1" },
        };
        return exec.executeEx(gpa, io, method, uri, &headers, body);
    }

    /// V3 JSON POST(兼容旧骨架入口;Authorization 已接入真实签名链路)。
    pub fn v3Post(self: *PayService, io: std.Io, url_path: []const u8, json_body: []const u8) WxResult([]u8) {
        return self.v3Send(io, .post, url_path, json_body, null);
    }

    /// 应答验签入口(对应 Java `WechatPay2Validator`):显式传入响应头里的
    /// Wechatpay-Timestamp/Nonce/Signature + 原始 body。回调侧验签(头在 HTTP
    /// server 手里)可直接走这里或 `notify.verifySignature`。
    pub fn verifyV3Response(self: *PayService, timestamp: []const u8, nonce: []const u8, body: []const u8, signature_b64: []const u8) WxResult(bool) {
        const pem = self.platform_pub_pem orelse
            return .{ .err = WxError.configError(self.gpa, "未配置平台证书公钥(platform_pub_pem)", .{}) };
        const ok = v3.verifyWithPublicKeyPem(self.gpa, pem, timestamp, nonce, body, signature_b64) catch |e|
            return .{ .err = WxError.cryptoError(self.gpa, "V3 应答验签: {s}", .{@errorName(e)}) };
        return .{ .ok = ok };
    }

    /// 应答验签 seam(对应 Java `WxPayValidator.validate(CloseableHttpResponse)`):
    /// 直接吃 `v3SendEx` 回传的 `Response`(body + Wechatpay-* 头),用**已配置的
    /// 平台证书公钥**(凭证)走完整判定链:Content-Type 判定 -> 取 4 头 -> 时间戳
    /// 新鲜度(防重放) -> 拼验签串 -> 真实 RSA 验签。不伪造验证结果。
    /// `now_seconds`/`tolerance_seconds` 由调用方注入(可控时钟,便于离线单测);
    /// 传 `v3.default_timestamp_tolerance_seconds` 用 Java 默认的 5 分钟。
    /// 返回的 `VerifyOutcome` 显式区分 verified / skipped_non_json / missing_header
    /// / invalid_timestamp / stale_timestamp / signature_mismatch / crypto_error。
    pub fn verifyV3ResponseFrom(self: *PayService, resp: v3.Response, now_seconds: i64, tolerance_seconds: i64) WxResult(v3.VerifyOutcome) {
        const pem = self.platform_pub_pem orelse
            return .{ .err = WxError.configError(self.gpa, "未配置平台证书公钥(platform_pub_pem)", .{}) };
        return .{ .ok = v3.verifyResponse(self.gpa, resp, pem, now_seconds, tolerance_seconds) };
    }

    /// 对应 `createOrderV3(WxPayUnifiedOrderV3Request)`(JSAPI 下单常用字段)。
    /// POST /v3/pay/transactions/jsapi → prepay_id。
    pub const JsapiOrderArgs = struct {
        description: []const u8,
        out_trade_no: []const u8,
        openid: []const u8,
        /// 金额(分)
        amount_total: i64,
        currency: []const u8 = "CNY",
        notify_url: []const u8 = "", // 空→cfg.notify_url
    };
    pub fn v3CreateJsapiOrder(self: *PayService, io: std.Io, args: JsapiOrderArgs, inject: ?NonceTs) WxResult(v3.JsapiOrderResult) {
        const gpa = self.gpa;
        const notify_url = if (args.notify_url.len > 0) args.notify_url else self.cfg.notify_url;

        // 请求体(对应 WxPayUnifiedOrderV3Request.toJson):嵌套对象手工组装
        var amount = json_util.ObjectBuilder.init(gpa);
        defer amount.deinit();
        amount.putInt("total", args.amount_total) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        amount.putStr("currency", args.currency) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        var payer = json_util.ObjectBuilder.init(gpa);
        defer payer.deinit();
        payer.putStr("openid", args.openid) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("appid", self.cfg.appid) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putStr("mchid", self.cfg.mch_id) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putStr("description", args.description) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putStr("out_trade_no", args.out_trade_no) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putStr("notify_url", notify_url) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putValue("amount", .{ .object = amount.map }) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        ob.putValue("payer", .{ .object = payer.map }) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.v3Send(io, .post, v3.jsapi_order_path, body, inject)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        if (v3.v3ErrorFromJson(gpa, resp)) |e| return .{ .err = e };

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "V3 下单应答非 JSON", .{}) };
        defer parsed.deinit();
        if (json_util.getStr(parsed.value, "prepay_id") == null)
            return .{ .err = WxError.transport(gpa, "V3 下单应答缺 prepay_id", .{}) };
        const r = v3.JsapiOrderResult.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `queryOrderV3(outTradeNo)`。
    /// GET /v3/pay/transactions/out-trade-no/{no}?mchid=…
    pub fn v3QueryByOutTradeNo(self: *PayService, io: std.Io, out_trade_no: []const u8, inject: ?NonceTs) WxResult(v3.OrderResult) {
        const gpa = self.gpa;
        const url_path = std.fmt.allocPrint(gpa, "{s}{s}?mchid={s}", .{ v3.out_trade_no_path, out_trade_no, self.cfg.mch_id }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(url_path);

        const resp = switch (self.v3Send(io, .get, url_path, "", inject)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        if (v3.v3ErrorFromJson(gpa, resp)) |e| return .{ .err = e };

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "V3 查单应答非 JSON", .{}) };
        defer parsed.deinit();
        const r = v3.OrderResult.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `closeOrderV3(outTradeNo)`。POST /v3/pay/transactions/out-trade-no/{no}/close。
    /// 成功时微信返回 204 空 body → `.ok = {}`。
    pub fn v3CloseOrder(self: *PayService, io: std.Io, out_trade_no: []const u8, inject: ?NonceTs) WxResult(void) {
        const gpa = self.gpa;
        const url_path = std.fmt.allocPrint(gpa, "{s}{s}/close", .{ v3.out_trade_no_path, out_trade_no }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(url_path);
        const body = std.fmt.allocPrint(gpa, "{{\"mchid\":\"{s}\"}}", .{self.cfg.mch_id}) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.v3Send(io, .post, url_path, body, inject)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        if (v3.v3ErrorFromJson(gpa, resp)) |e| return .{ .err = e };
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/// 通用 V2 mock:校验 uri 子串,捕获 method/uri/body,返回按 cfg **重新签名**的响应。
const V2Mock = struct {
    cfg: *config_mod.PayConfig,
    want: []const u8,
    resp: []const sign_mod.Field,
    bad_sign: bool = false,
    cap_method: ?mp_http.RequestExecutor.Method = null,
    cap_uri: ?[]u8 = null,
    cap_body: ?[]u8 = null,
    calls: usize = 0,

    fn deinitCaps(self: *V2Mock, g: std.mem.Allocator) void {
        if (self.cap_uri) |u| g.free(u);
        if (self.cap_body) |b| g.free(b);
    }

    fn execute(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = i;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.cap_method = method;
        self.cap_uri = g.dupe(u8, uri) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        self.cap_body = g.dupe(u8, body orelse "") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        if (std.mem.indexOf(u8, uri, self.want) == null)
            return .{ .err = error_mod.WxError.transport(g, "mock uri miss: {s}", .{uri}) };

        var b = xml.Builder.init(g);
        defer b.deinit();
        for (self.resp) |f| b.add(f.key, f.value) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        const s = sign_mod.signV2(g, self.resp, self.cfg.mch_key, self.cfg.sign_type) catch
            return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        defer g.free(s);
        b.add("sign", if (self.bad_sign) "BADSIGN000" else s) catch
            return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        return .{ .ok = b.finish(true) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) } };
    }

    fn executor(self: *V2Mock) mp_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = V2Mock.execute } };
    }
};

fn mkCfg(gpa: std.mem.Allocator) !config_mod.PayConfig {
    return config_mod.PayConfig.init(gpa, .{
        .appid = "wxpay",
        .mch_id = "19000",
        .mch_key = "k32k32k32k32k32k32k32k32k32k32k",
        .notify_url = "https://example.com/notify",
    });
}

fn mkSplitCfg(gpa: std.mem.Allocator) !config_mod.PayConfig {
    return config_mod.PayConfig.init(gpa, .{
        .appid = "wxpay",
        .mch_id = "19000",
        .mch_key = "k32k32k32k32k32k32k32k32k32k32k",
        .notify_url = "PAY_CALLBACK",
        .refund_notify_url = "REFUND_CALLBACK",
    });
}

// 对照 Java `WxPayConfig`:notifyUrl(支付)与 refundNotifyUrl(退款)是两个独立字段,
// 分别被统一下单与退款请求回退使用。
test "pay config: notifyUrl/refundNotifyUrl 独立字段 + 各自回退" {
    const gpa = std.testing.allocator;
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "refund_id", .value = "500002" },
        .{ .key = "out_refund_no", .value = "R7" },
        .{ .key = "refund_fee", .value = "1" },
    };
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 配置层:两个字段分别保存、分别释放(deinit 泄漏由 testing.allocator 兜底)。
    {
        var cfg = try mkSplitCfg(gpa);
        defer cfg.deinit();
        try std.testing.expectEqualStrings("PAY_CALLBACK", cfg.notify_url);
        try std.testing.expectEqualStrings("REFUND_CALLBACK", cfg.refund_notify_url);
    }

    // 退款:空 args.notify_url → 回退 cfg.refund_notify_url(不是支付 notify_url)。
    {
        var cfg = try mkSplitCfg(gpa);
        defer cfg.deinit();
        var mock = V2Mock{ .cfg = &cfg, .want = "/secapi/pay/refund", .resp = &resp_fields };
        defer mock.deinitCaps(gpa);
        var pay = PayService.init(gpa, &cfg, mock.executor());
        switch (pay.refund(io, .{ .out_refund_no = "R7", .total_fee = "2", .refund_fee = "1" })) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
            },
        }
        const body = mock.cap_body.?;
        try std.testing.expect(std.mem.indexOf(u8, body, "REFUND_CALLBACK") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "PAY_CALLBACK") == null);
    }

    // 退款:显式 args.notify_url 覆盖配置里的两个回调地址。
    {
        var cfg = try mkSplitCfg(gpa);
        defer cfg.deinit();
        var mock = V2Mock{ .cfg = &cfg, .want = "/secapi/pay/refund", .resp = &resp_fields };
        defer mock.deinitCaps(gpa);
        var pay = PayService.init(gpa, &cfg, mock.executor());
        switch (pay.refund(io, .{ .out_refund_no = "R7", .total_fee = "2", .refund_fee = "1", .notify_url = "OVERRIDE_CALLBACK" })) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
            },
        }
        const body = mock.cap_body.?;
        try std.testing.expect(std.mem.indexOf(u8, body, "OVERRIDE_CALLBACK") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "REFUND_CALLBACK") == null);
    }

    // 统一下单(支付):用 cfg.notify_url,而不是 refund_notify_url。
    {
        var cfg = try mkSplitCfg(gpa);
        defer cfg.deinit();
        var mock = V2Mock{ .cfg = &cfg, .want = "/pay/unifiedorder", .resp = &resp_fields };
        defer mock.deinitCaps(gpa);
        var pay = PayService.init(gpa, &cfg, mock.executor());
        switch (pay.unifiedOrder(io, "T1", "1", "goods")) {
            .ok => |b| gpa.free(b),
            .err => |e| {
                var err = e;
                defer err.deinit();
            },
        }
        const body = mock.cap_body.?;
        try std.testing.expect(std.mem.indexOf(u8, body, "PAY_CALLBACK") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "REFUND_CALLBACK") == null);
    }
}

test "v2 order_query mock: method+uri+signed xml body + parsed result" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "trade_state", .value = "SUCCESS" },
        .{ .key = "out_trade_no", .value = "T1001" },
        .{ .key = "transaction_id", .value = "wx42" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "/pay/orderquery", .resp = &resp_fields };
    var pay = PayService.init(gpa, &cfg, mock.executor());

    const r = pay.orderQuery(threaded.io(), .{ .out_trade_no = "T1001" });
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            defer res.deinit();
            try std.testing.expect(res.base.businessOk());
            try std.testing.expectEqualStrings("SUCCESS", res.trade_state);
            try std.testing.expectEqualStrings("wx42", res.transaction_id);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("order_query err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
    defer mock.deinitCaps(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(mp_http.RequestExecutor.Method.post, mock.cap_method.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.cap_uri.?, "https://api.mch.weixin.qq.com/pay/orderquery") != null);
    const body = mock.cap_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "<out_trade_no><![CDATA[T1001]]></out_trade_no>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<sign><![CDATA[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<nonce_str>") != null);
}

test "v2 bad response sign -> crypto error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "FAIL" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "/pay/orderquery", .resp = &resp_fields, .bad_sign = true };
    var pay = PayService.init(gpa, &cfg, mock.executor());

    const r = pay.orderQuery(threaded.io(), .{ .out_trade_no = "T1" });
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            res.deinit();
            return error.ShouldFail;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.crypto, err.source);
        },
    }
    mock.deinitCaps(gpa);
}

test "v2 close_order + reverse + refund_query mock" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    const ok_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
    };

    var m1 = V2Mock{ .cfg = &cfg, .want = "/pay/closeorder", .resp = &ok_fields };
    var pay1 = PayService.init(gpa, &cfg, m1.executor());
    {
        const r = pay1.closeOrder(io, "T9");
        switch (r) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
                try std.testing.expect(res.businessOk());
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try std.testing.expect(std.mem.indexOf(u8, m1.cap_uri.?, "/pay/closeorder") != null);
        try std.testing.expect(std.mem.indexOf(u8, m1.cap_body.?, "T9") != null);
        m1.deinitCaps(gpa);
    }

    var m2 = V2Mock{ .cfg = &cfg, .want = "/secapi/pay/reverse", .resp = &ok_fields };
    var pay2 = PayService.init(gpa, &cfg, m2.executor());
    {
        const r = pay2.reverse(io, "T9");
        switch (r) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try std.testing.expect(std.mem.indexOf(u8, m2.cap_uri.?, "/secapi/pay/reverse") != null);
        m2.deinitCaps(gpa);
    }

    const rq_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "refund_count", .value = "2" },
        // 第 0 笔
        .{ .key = "out_refund_no_0", .value = "R1" },
        .{ .key = "refund_status_0", .value = "SUCCESS" },
        .{ .key = "refund_fee_0", .value = "1" },
        .{ .key = "refund_recv_accout_0", .value = "支付用户零钱" },
        .{ .key = "coupon_refund_count_0", .value = "1" },
        .{ .key = "coupon_refund_id_0_0", .value = "C1" },
        // 第 1 笔
        .{ .key = "out_refund_no_1", .value = "R2" },
        .{ .key = "refund_status_1", .value = "PROCESSING" },
        .{ .key = "refund_fee_1", .value = "2" },
    };
    var m3 = V2Mock{ .cfg = &cfg, .want = "/pay/refundquery", .resp = &rq_fields };
    var pay3 = PayService.init(gpa, &cfg, m3.executor());
    {
        const r = pay3.refundQuery(io, .{ .out_refund_no = "R1" });
        switch (r) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
                const recs = res.refund_records;
                try std.testing.expectEqual(@as(usize, 2), recs.len);
                try std.testing.expectEqualStrings("R1", recs[0].out_refund_no);
                try std.testing.expectEqualStrings("SUCCESS", recs[0].refund_status);
                try std.testing.expectEqualStrings("支付用户零钱", recs[0].refund_recv_accout);
                // 代金券明细(coupon_refund_count 驱动 N_M 键)
                try std.testing.expectEqual(@as(usize, 1), recs[0].refund_coupons.len);
                try std.testing.expectEqualStrings("C1", recs[0].refund_coupons[0].coupon_refund_id);
                // 第 1 笔无 coupon_refund_count_1 → 0 张代金券
                try std.testing.expectEqualStrings("R2", recs[1].out_refund_no);
                try std.testing.expectEqualStrings("PROCESSING", recs[1].refund_status);
                try std.testing.expectEqual(@as(usize, 0), recs[1].refund_coupons.len);
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try std.testing.expect(std.mem.indexOf(u8, m3.cap_body.?, "out_refund_no") != null);
        m3.deinitCaps(gpa);
    }
}

test "v2 refund mock: refund fields in body + parsed response" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "refund_id", .value = "500002" },
        .{ .key = "out_refund_no", .value = "R7" },
        .{ .key = "refund_fee", .value = "1" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "/secapi/pay/refund", .resp = &resp_fields };
    var pay = PayService.init(gpa, &cfg, mock.executor());

    const r = pay.refund(threaded.io(), .{
        .out_trade_no = "T7",
        .out_refund_no = "R7",
        .total_fee = "2",
        .refund_fee = "1",
        .refund_desc = "test",
    });
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            defer res.deinit();
            try std.testing.expectEqualStrings("500002", res.refund_id);
            try std.testing.expectEqualStrings("R7", res.out_refund_no);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("refund err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
    defer mock.deinitCaps(gpa);
    try std.testing.expect(std.mem.indexOf(u8, mock.cap_uri.?, "/secapi/pay/refund") != null);
    const body = mock.cap_body.?;
    for ([_][]const u8{ "out_refund_no", "total_fee", "refund_fee", "refund_desc" }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, body, k) != null);
    }
}

test "v2 business FAIL -> wechat_api error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "FAIL" },
        .{ .key = "err_code", .value = "ORDERNOTEXIST" },
        .{ .key = "err_code_des", .value = "订单不存在" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "/pay/orderquery", .resp = &resp_fields };
    var pay = PayService.init(gpa, &cfg, mock.executor());

    const r = pay.orderQuery(threaded.io(), .{ .out_trade_no = "NOPE" });
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            res.deinit();
            return error.ShouldFail;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.wechat_api, err.source);
            try std.testing.expectEqualStrings("ORDERNOTEXIST", err.error_msg_en);
            try std.testing.expectEqualStrings("订单不存在", err.error_msg);
        },
    }
    mock.deinitCaps(gpa);
}

/// V3 mock:捕获 method/uri/body/Authorization,返回预置响应。
const V3Mock = struct {
    resp: []const u8,
    want: []const u8,
    cap_method: ?v3.Method = null,
    cap_uri: ?[]u8 = null,
    cap_body: ?[]u8 = null,
    cap_auth: ?[]u8 = null,
    calls: usize = 0,

    fn deinitCaps(self: *V3Mock, g: std.mem.Allocator) void {
        if (self.cap_uri) |u| g.free(u);
        if (self.cap_body) |b| g.free(b);
        if (self.cap_auth) |a| g.free(a);
    }

    fn execute(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: v3.Method, uri: []const u8, headers: []const v3.RequestExecutor.Header, body: ?[]const u8) WxResult([]u8) {
        _ = i;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.cap_method = method;
        self.cap_uri = g.dupe(u8, uri) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        self.cap_body = g.dupe(u8, body orelse "") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        var found: []const u8 = "";
        for (headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization")) found = h.value;
        }
        if (found.len == 0) return .{ .err = error_mod.WxError.transport(g, "missing Authorization header", .{}) };
        self.cap_auth = g.dupe(u8, found) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        if (std.mem.indexOf(u8, uri, self.want) == null)
            return .{ .err = error_mod.WxError.transport(g, "v3 mock uri miss: {s}", .{uri}) };
        return .{ .ok = g.dupe(u8, self.resp) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) } };
    }

    fn executor(self: *V3Mock) v3.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = V3Mock.execute } };
    }
};

test "v3 create jsapi order end-to-end (mock + real rsa + injected nonce/ts)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try config_mod.PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .cert_serial_no = "SERIAL1",
        .notify_url = "https://example.com/notify",
    });
    defer cfg.deinit();
    var ks = try sign_mod.KeySigner.fromPem(gpa, sign_mod.TEST_PRIV_PEM);
    defer ks.deinit();

    var mock = V3Mock{ .resp = "{\"prepay_id\":\"wx260108\"}", .want = "/v3/pay/transactions/jsapi" };
    var stub_exec = mp_http.StubExecutor.init(gpa, &.{});
    var pay = PayService.init(gpa, &cfg, stub_exec.executor());
    pay.rsa = ks.signer();
    pay.v3exec = mock.executor();

    const inject = NonceTs{ .nonce = "NONCE", .timestamp = "1700000000" };
    const r = pay.v3CreateJsapiOrder(threaded.io(), .{
        .description = "测试商品",
        .out_trade_no = "T9",
        .openid = "oOPEN",
        .amount_total = 100,
    }, inject);
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            defer res.deinit();
            try std.testing.expectEqualStrings("wx260108", res.prepay_id);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("v3 jsapi err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }

    defer mock.deinitCaps(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(v3.Method.post, mock.cap_method.?);
    try std.testing.expectEqualStrings(v3.jsapi_order_path, mock.cap_uri.?[v2_mod.api_host.len..]);
    const body = mock.cap_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"out_trade_no\":\"T9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"total\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"openid\":\"oOPEN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"currency\":\"CNY\"") != null);

    // Authorization 头格式 + 真签名闭环:从 header 抽 signature,对签名串验公钥
    const auth = mock.cap_auth.?;
    const prefix = "WECHATPAY2-SHA256-RSA2048 mchid=\"1900010\",nonce_str=\"NONCE\",timestamp=\"1700000000\",serial_no=\"SERIAL1\",signature=\"";
    try std.testing.expect(std.mem.startsWith(u8, auth, prefix));
    const s = prefix.len;
    const epos = std.mem.indexOfScalarPos(u8, auth, s, '"').?;
    const sign_str = try std.fmt.allocPrint(gpa, "POST\n{s}\n1700000000\nNONCE\n{s}\n", .{ v3.jsapi_order_path, body });
    defer gpa.free(sign_str);
    try std.testing.expect(try sign_mod.verifyWithPublicKeyPem(gpa, sign_mod.TEST_PUB_PEM, sign_str, auth[s..epos]));
}

test "v3 query by out_trade_no + close order (mock)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try config_mod.PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .cert_serial_no = "SERIAL1",
    });
    defer cfg.deinit();
    var ks = try sign_mod.KeySigner.fromPem(gpa, sign_mod.TEST_PRIV_PEM);
    defer ks.deinit();

    var m1 = V3Mock{ .resp = "{\"out_trade_no\":\"T9\",\"trade_state\":\"SUCCESS\",\"transaction_id\":\"wx77\"}", .want = "/v3/pay/transactions/out-trade-no/" };
    var stub1 = mp_http.StubExecutor.init(gpa, &.{});
    var pay1 = PayService.init(gpa, &cfg, stub1.executor());
    pay1.rsa = ks.signer();
    pay1.v3exec = m1.executor();
    {
        const inj = NonceTs{ .nonce = "N1", .timestamp = "1700000001" };
        const r = pay1.v3QueryByOutTradeNo(io, "T9", inj);
        switch (r) {
            .ok => |*rp| {
                var res = rp.*;
                defer res.deinit();
                try std.testing.expectEqualStrings("SUCCESS", res.trade_state);
                try std.testing.expectEqualStrings("wx77", res.transaction_id);
            },
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try std.testing.expectEqual(v3.Method.get, m1.cap_method.?);
        try std.testing.expect(std.mem.endsWith(u8, m1.cap_uri.?, "/v3/pay/transactions/out-trade-no/T9?mchid=1900010"));
        // GET 空 body:签名串末段为空
        const sign_str = try std.fmt.allocPrint(gpa, "GET\n/v3/pay/transactions/out-trade-no/T9?mchid=1900010\n1700000001\nN1\n\n", .{});
        defer gpa.free(sign_str);
        const auth = m1.cap_auth.?;
        const marker = "signature=\"";
        const sp = std.mem.indexOf(u8, auth, marker).? + marker.len;
        const ep = std.mem.indexOfScalarPos(u8, auth, sp, '"').?;
        try std.testing.expect(try sign_mod.verifyWithPublicKeyPem(gpa, sign_mod.TEST_PUB_PEM, sign_str, auth[sp..ep]));
        m1.deinitCaps(gpa);
    }

    var m2 = V3Mock{ .resp = "", .want = "/close" };
    var stub2 = mp_http.StubExecutor.init(gpa, &.{});
    var pay2 = PayService.init(gpa, &cfg, stub2.executor());
    pay2.rsa = ks.signer();
    pay2.v3exec = m2.executor();
    {
        const inj = NonceTs{ .nonce = "N2", .timestamp = "1700000002" };
        const r = pay2.v3CloseOrder(io, "T9", inj);
        switch (r) {
            .ok => {},
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try std.testing.expect(std.mem.endsWith(u8, m2.cap_uri.?, "/v3/pay/transactions/out-trade-no/T9/close"));
        try std.testing.expectEqualStrings("{\"mchid\":\"1900010\"}", m2.cap_body.?);
        m2.deinitCaps(gpa);
    }
}

test "v3 error response maps to WxError" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try config_mod.PayConfig.init(gpa, .{ .appid = "wxp", .mch_id = "1900010", .cert_serial_no = "S" });
    defer cfg.deinit();
    var ks = try sign_mod.KeySigner.fromPem(gpa, sign_mod.TEST_PRIV_PEM);
    defer ks.deinit();

    var mock = V3Mock{ .resp = "{\"code\":\"ORDERPAID\",\"message\":\"订单已支付\"}", .want = "/v3/pay/transactions/jsapi" };
    var stub = mp_http.StubExecutor.init(gpa, &.{});
    var pay = PayService.init(gpa, &cfg, stub.executor());
    pay.rsa = ks.signer();
    pay.v3exec = mock.executor();

    const r = pay.v3CreateJsapiOrder(threaded.io(), .{ .description = "d", .out_trade_no = "T", .openid = "o", .amount_total = 1 }, NonceTs{ .nonce = "N", .timestamp = "1700000000" });
    switch (r) {
        .ok => |*rp| {
            var res = rp.*;
            res.deinit();
            return error.ShouldFail;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqualStrings("ORDERPAID", err.error_msg_en);
            try std.testing.expectEqualStrings("订单已支付", err.error_msg);
        },
    }
    mock.deinitCaps(gpa);
}

/// V3 执行器 mock:覆写 `execute_ex`,回传带 Wechatpay-* 头的 Response。
/// 用于验证「v3SendEx -> verifyV3ResponseFrom」的完整应答验签 seam。
const V3HeaderMock = struct {
    resp_body: []const u8,
    headers: []const result_mod.Header,
    calls: usize = 0,

    fn executor(self: *V3HeaderMock) v3.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, g: std.mem.Allocator, io: std.Io, method: v3.Method, uri: []const u8, headers: []const v3.RequestExecutor.Header, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        _ = method;
        _ = uri;
        _ = headers;
        _ = body;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{ .ok = g.dupe(u8, self.resp_body) catch return .{ .err = WxError.transport(g, "oom", .{}) } };
    }

    fn executeExImpl(ctx: *anyopaque, g: std.mem.Allocator, io: std.Io, method: v3.Method, uri: []const u8, headers: []const v3.RequestExecutor.Header, body: ?[]const u8) WxResult(v3.Response) {
        const r = executeImpl(ctx, g, io, method, uri, headers, body);
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return switch (r) {
            .err => |e| .{ .err = e },
            .ok => |b| .{ .ok = .{
                .body = b,
                .headers = result_mod.dupeHeaders(g, self.headers) catch {
                    g.free(b);
                    return .{ .err = WxError.transport(g, "oom", .{}) };
                },
            } },
        };
    }

    const vtable = v3.RequestExecutor.VTable{ .execute = executeImpl, .execute_ex = executeExImpl };
};

test "v3 response verification seam end-to-end: v3SendEx -> verifyV3ResponseFrom" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = "1700000000";
    const nonce = "RESP_NONCE";
    const body = "{\"prepay_id\":\"wx260108\"}";
    // 用内嵌测试私钥对响应验签串真签名(平台证书公钥 = 内嵌测试公钥,是测试凭证)
    const msg = try v3.buildVerifyString(gpa, ts, nonce, body);
    defer gpa.free(msg);
    var ks = try sign_mod.KeySigner.fromPem(gpa, sign_mod.TEST_PRIV_PEM);
    defer ks.deinit();
    const sig = try ks.signBase64(gpa, msg);
    defer gpa.free(sig);

    const hdrs = [_]result_mod.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Wechatpay-Timestamp", .value = ts },
        .{ .name = "Wechatpay-Nonce", .value = nonce },
        .{ .name = "Wechatpay-Signature", .value = sig },
        .{ .name = "Wechatpay-Serial", .value = "SERIAL1" },
    };

    var cfg = try config_mod.PayConfig.init(gpa, .{ .appid = "wxp", .mch_id = "1900010", .cert_serial_no = "S" });
    defer cfg.deinit();
    var stub = mp_http.StubExecutor.init(gpa, &.{});
    var pay = PayService.init(gpa, &cfg, stub.executor());
    pay.rsa = ks.signer();
    pay.platform_pub_pem = sign_mod.TEST_PUB_PEM;
    var mock = V3HeaderMock{ .resp_body = body, .headers = &hdrs };
    pay.v3exec = mock.executor();

    // v3SendEx 带回传的头
    const sent = pay.v3SendEx(io, .get, v3.out_trade_no_path, null, NonceTs{ .nonce = "REQ_NONCE", .timestamp = "1700000000" });
    switch (sent) {
        .ok => |resp| {
            var v = resp;
            defer v.deinit(gpa);
            try std.testing.expectEqualStrings(body, v.body);
            try std.testing.expectEqualStrings("SERIAL1", v.header("Wechatpay-Serial").?);
            // 走完整验签 seam(可控时钟 now=ts)
            const vr = pay.verifyV3ResponseFrom(v, 1700000000, v3.default_timestamp_tolerance_seconds);
            switch (vr) {
                .ok => |outcome| try expectTagV3(.verified, outcome),
                .err => |e| {
                    var err = e;
                    defer err.deinit();
                    return error.UnexpectedVerifyError;
                },
            }
            // 重放时钟(超 5 分钟) -> stale_timestamp
            const stale = pay.verifyV3ResponseFrom(v, 1700000500, v3.default_timestamp_tolerance_seconds);
            switch (stale) {
                .ok => |outcome| try expectTagV3(.stale_timestamp, outcome),
                .err => |e| {
                    var err = e;
                    defer err.deinit();
                    return error.UnexpectedVerifyError;
                },
            }
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedSendError;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

fn expectTagV3(comptime want: std.meta.Tag(v3.VerifyOutcome), out: v3.VerifyOutcome) !void {
    try std.testing.expectEqual(want, std.meta.activeTag(out));
}

// ---------------------------------------------------------------------------
// 既有骨架测试(保留)
// ---------------------------------------------------------------------------

test "v2 unified order roundtrip with signed response (stubbed)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 桩:原样回显一个**带合法签名**的响应(用同规则现签)
    const EchoSign = struct {
        cfg: *config_mod.PayConfig,
        fn execute(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
            _ = i;
            _ = method;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, uri, "unifiedorder") == null or body == null)
                return .{ .err = error_mod.WxError.transport(g, "stub miss", .{}) };
            const fields = [_]sign_mod.Field{
                .{ .key = "return_code", .value = "SUCCESS" },
                .{ .key = "result_code", .value = "SUCCESS" },
                .{ .key = "prepay_id", .value = "wx20141027" },
            };
            const s = sign_mod.signV2(g, &fields, self.cfg.mch_key, self.cfg.sign_type) catch
                return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            defer g.free(s);
            const resp = std.fmt.allocPrint(
                g,
                "<xml><return_code><![CDATA[SUCCESS]]></return_code><result_code><![CDATA[SUCCESS]]></result_code><prepay_id><![CDATA[wx20141027]]></prepay_id><sign><![CDATA[{s}]]></sign></xml>",
                .{s},
            ) catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = resp };
        }
    };
    var cfg = try config_mod.PayConfig.init(gpa, .{ .appid = "wxpay", .mch_id = "19000", .mch_key = "k32k32k32k32k32k32k32k32k32k32k", .notify_url = "https://example.com/notify" });
    defer cfg.deinit();
    var echo = EchoSign{ .cfg = &cfg };
    const exec = mp_http.RequestExecutor{ .ptr = @ptrCast(&echo), .vtable = &.{ .execute = EchoSign.execute } };

    var pay = PayService.init(gpa, &cfg, exec);
    const r = pay.unifiedOrder(io, "T1001", "1", "test");
    switch (r) {
        .ok => |resp| {
            defer gpa.free(resp);
            try std.testing.expect(std.mem.indexOf(u8, resp, "prepay_id") != null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("pay err: [{d}] {s}\n", .{ err.error_code, err.error_msg });
            return error.Unexpected;
        },
    }
}

test "v3 post surfaces rsa stub" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var cfg = try config_mod.PayConfig.init(gpa, .{ .appid = "wxpay", .mch_id = "19000" });
    defer cfg.deinit();
    var stub = mp_http.StubExecutor.init(gpa, &.{});
    var pay = PayService.init(gpa, &cfg, stub.executor());

    const r = pay.v3Post(threaded.io(), "/v3/pay/transactions/jsapi", "{}");
    switch (r) {
        .ok => return error.V3ShouldNotBeOk,
        .err => |e| {
            var err = e;
            defer err.deinit();
            // 预期:V3 通道未接线(执行器/签名器未注入)
            try std.testing.expect(std.mem.indexOf(u8, err.error_msg, "V3") != null);
        },
    }
}

// ---------------------------------------------------------------------------
// 测试:WxPayConfig 剩余字段的消费方回退(trade_type / sub_appid / sub_mch_id)
// ---------------------------------------------------------------------------

test "unifiedOrder consumes cfg.trade_type + sub_appid/sub_mch_id in signed XML" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 带服务商子商户 + 自定义交易类型的配置
    var cfg = try config_mod.PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .mch_key = "k32k32k32k32k32k32k32k32k32k32k",
        .notify_url = "https://example.com/notify",
        .trade_type = "NATIVE",
        .sub_appid = "wxSUBAPP",
        .sub_mch_id = "SUBMCH99",
    });
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "prepay_id", .value = "wx1" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "unifiedorder", .resp = &resp_fields };
    defer mock.deinitCaps(gpa);
    var pay = PayService.init(gpa, &cfg, mock.executor());

    switch (pay.unifiedOrder(io, "T1", "1", "goods")) {
        .ok => |b| gpa.free(b),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedUnifiedOrderError;
        },
    }
    const body = mock.cap_body.?;
    // trade_type 回退到 cfg(NATIVE 而非旧版硬编码 JSAPI)
    try std.testing.expect(std.mem.indexOf(u8, body, "<trade_type><![CDATA[NATIVE]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "JSAPI") == null);
    // 子商户字段参与签名并写入 XML
    try std.testing.expect(std.mem.indexOf(u8, body, "<sub_appid><![CDATA[wxSUBAPP]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<sub_mch_id><![CDATA[SUBMCH99]]>") != null);
}

test "unifiedOrder direct merchant: empty sub fields omitted, JSAPI default intact" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try mkCfg(gpa); // 无 trade_type / 无子商户
    defer cfg.deinit();
    const resp_fields = [_]sign_mod.Field{
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "result_code", .value = "SUCCESS" },
    };
    var mock = V2Mock{ .cfg = &cfg, .want = "unifiedorder", .resp = &resp_fields };
    defer mock.deinitCaps(gpa);
    var pay = PayService.init(gpa, &cfg, mock.executor());
    switch (pay.unifiedOrder(io, "T1", "1", "goods")) {
        .ok => |b| gpa.free(b),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedUnifiedOrderError;
        },
    }
    const body = mock.cap_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "<trade_type><![CDATA[JSAPI]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sub_appid") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sub_mch_id") == null);
}

// ---------------------------------------------------------------------------
// 测试:mTLS 接缝在 PayService 上的接线(纯逻辑,离线)
// ---------------------------------------------------------------------------

test "PayService.mtlsStatus: honest missing_cert / not_required / present" {
    const gpa = std.testing.allocator;
    var cfg = try mkCfg(gpa);
    defer cfg.deinit();
    var stub = mp_http.StubExecutor.init(gpa, &.{});
    var pay = PayService.init(gpa, &cfg, stub.executor());

    // 未注入证书提供者:需证书的接口报 missing_cert(不伪造成功)
    switch (pay.mtlsStatus(v2_mod.url.refund)) {
        .missing_cert => {},
        else => return error.UnexpectedMtls,
    }
    // 普通接口:not_required
    switch (pay.mtlsStatus("/pay/unifiedorder")) {
        .not_required => {},
        else => return error.UnexpectedMtls,
    }
    // 注入配置了证书的 provider -> transport_unsupported(配置齐全但 std 无 mTLS)
    var provider = mtls.InMemoryCertProvider{ .cert = .{ .mch_id = "19000", .key_string = "BASE64_P12" } };
    pay.client_cert = provider.provider();
    switch (pay.mtlsStatus(v2_mod.url.reverse)) {
        .cert_present_transport_unsupported => |c| try std.testing.expectEqualStrings("BASE64_P12", c.key_string),
        else => return error.UnexpectedMtls,
    }
}
