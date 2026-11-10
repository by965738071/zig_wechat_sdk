//! 微信支付配置 —— 对应 Java `config.WxPayConfig`。
//! V2(XML+MD5/HMAC)与 V3(JSON+RSA+AES-GCM)两套凭据并存,与 Java 一致。
const std = @import("std");
const credentials = @import("common").credentials;

pub const SignType = enum {
    md5, // 默认(V2)
    hmac_sha256, // V2 可选

    /// 对应 Java 枚举值字符串
    pub fn str(self: SignType) []const u8 {
        return switch (self) {
            .md5 => "MD5",
            .hmac_sha256 => "HMAC-SHA256",
        };
    }

    /// 对应 Java `WxPayConstants.SignType.ALL_SIGN_TYPES`(仅 MD5 / HMAC-SHA256):
    /// `BaseWxPayRequest.checkAndSign` 用 `ALL_SIGN_TYPES.contains(signType)` 校验,
    /// 非法值抛 WxPayException。这里同样只认这两个**大小写敏感**的字符串。
    pub fn fromStr(s: []const u8) ?SignType {
        if (std.mem.eql(u8, s, "MD5")) return .md5;
        if (std.mem.eql(u8, s, "HMAC-SHA256")) return .hmac_sha256;
        return null;
    }

    /// 全部合法字符串(对应 ALL_SIGN_TYPES),供配置校验/错误信息使用。
    pub fn allStrings() []const []const u8 {
        return &.{ "MD5", "HMAC-SHA256" };
    }

    pub fn isLegalStr(s: []const u8) bool {
        return fromStr(s) != null;
    }
};

pub const PayConfig = struct {
    gpa: std.mem.Allocator,
    appid: []u8,
    mch_id: []u8,
    /// V2 签名密钥(32 位)
    mch_key: []u8,
    sign_type: SignType = .md5,
    /// 支付结果回调地址 —— 对应 Java `WxPayConfig.notifyUrl`。
    /// `WxPayUnifiedOrderRequest.checkAndSign` 在请求的 notify_url 为空时回退到此值。
    notify_url: []u8 = "",
    /// 退款结果回调地址 —— 对应 Java `WxPayConfig.refundNotifyUrl`。
    /// `WxPayRefundRequest.checkAndSign` 在请求的 notify_url 为空时回退到此值。
    /// 与 notifyUrl 是两个独立字段(骨架曾合二为一,此处按 Java 细分)。
    refund_notify_url: []u8 = "",

    /// V3:APIv3 密钥(32 位,回调 AEAD 解密用)
    api_v3_key: []u8 = "",
    /// V3:商户私钥 PEM(RSA 签名用,经 sign.KeySigner 加载,实现在 vendored zig-rsa)
    private_key_pem: []u8 = "",
    /// V3:商户证书序列号(Authorization 头 serial_no)
    cert_serial_no: []u8 = "",

    /// 交易类型 —— 对应 Java `WxPayConfig.tradeType`(JSAPI/NATIVE/APP...)。
    /// `WxPayUnifiedOrderRequest.checkAndSign` 在请求的 trade_type 为空时回退到此值;
    /// 骨架 `unifiedOrder` 的固定 "JSAPI" 现改为「cfg.trade_type 非空则用,否则 JSAPI」。
    trade_type: []u8 = "",
    /// 服务商模式子商户公众账号 ID —— 对应 `WxPayConfig.subAppId`。
    /// `BaseWxPayRequest.checkAndSign` 在请求 sub_app_id 为空时回退到此值。
    sub_appid: []u8 = "",
    /// 服务商模式子商户号 —— 对应 `WxPayConfig.subMchId`(同上回退)。
    sub_mch_id: []u8 = "",
    /// 商户 p12 证书 base64 —— 对应 `WxPayConfig.keyString`。V2 refund/reverse 与
    /// 平台证书下载的双向 TLS(mTLS)凭据;真实使用需商户证书 + 支持 mTLS 的 TLS 栈
    /// (见 `v3.zig`/service 的 mTLS 接缝),本骨架仅保存配置,不伪造通道。
    key_string: []u8 = "",

    // HTTP 超时(对应 Java httpConnectionTimeout/httpTimeout)。工具链重核
    // (0.18.0-dev.954):std.http.Client 的 fetch/request 仍无可用 connect/read
    // 超时入口(ConnectTcpOptions.timeout 是未接线的死字段),故字段仅作配置占位、
    // 不宣称已生效,详见 mp/http.zig HttpExecutor 注释。
    connect_timeout_ms: u64 = 3_000,
    read_timeout_ms: u64 = 30_000,
    pub const InitArgs = struct {
        appid: []const u8,
        mch_id: []const u8,
        mch_key: []const u8 = "",
        sign_type: SignType = .md5,
        notify_url: []const u8 = "",
        refund_notify_url: []const u8 = "",
        api_v3_key: []const u8 = "",
        private_key_pem: []const u8 = "",
        cert_serial_no: []const u8 = "",
        trade_type: []const u8 = "",
        sub_appid: []const u8 = "",
        sub_mch_id: []const u8 = "",
        key_string: []const u8 = "",
    };

    pub fn init(gpa: std.mem.Allocator, args: InitArgs) !PayConfig {
        return .{
            .gpa = gpa,
            .appid = try gpa.dupe(u8, args.appid),
            .mch_id = try gpa.dupe(u8, args.mch_id),
            .mch_key = try gpa.dupe(u8, args.mch_key),
            .sign_type = args.sign_type,
            .notify_url = try gpa.dupe(u8, args.notify_url),
            .refund_notify_url = try gpa.dupe(u8, args.refund_notify_url),
            .api_v3_key = try gpa.dupe(u8, args.api_v3_key),
            .private_key_pem = try gpa.dupe(u8, args.private_key_pem),
            .cert_serial_no = try gpa.dupe(u8, args.cert_serial_no),
            .trade_type = try gpa.dupe(u8, args.trade_type),
            .sub_appid = try gpa.dupe(u8, args.sub_appid),
            .sub_mch_id = try gpa.dupe(u8, args.sub_mch_id),
            .key_string = try gpa.dupe(u8, args.key_string),
        };
    }

    /// 从凭证来源(文件/环境变量/文本)加载 V3 商户私钥 PEM 到 `private_key_pem`,
    /// 替换旧值。对应 Java `WxPayConfig` 从文件/配置中心加载 privateKey。
    /// 加载后由 `sign.KeySigner.fromPem` 消费(见 `service.zig initProduction`),
    /// 使该字段真正参与 V3 请求签名;错误信息只含来源标识,不回显密钥材料。
    pub fn loadPrivateKey(self: *PayConfig, io: std.Io, src: credentials.Source) !void {
        const pem = try credentials.read(self.gpa, io, src);
        self.gpa.free(self.private_key_pem);
        self.private_key_pem = pem;
    }

    pub fn deinit(self: *PayConfig) void {
        const g = self.gpa;
        g.free(self.appid);
        g.free(self.mch_id);
        g.free(self.mch_key);
        g.free(self.notify_url);
        g.free(self.refund_notify_url);
        g.free(self.api_v3_key);
        g.free(self.private_key_pem);
        g.free(self.cert_serial_no);
        g.free(self.trade_type);
        g.free(self.sub_appid);
        g.free(self.sub_mch_id);
        g.free(self.key_string);
    }

    /// 统一下单 trade_type 回退(对应 `WxPayUnifiedOrderRequest.checkAndSign`):
    /// 请求未指定时用 cfg.trade_type,仍为空则骨架默认 JSAPI。
    pub fn effectiveTradeType(self: *const PayConfig) []const u8 {
        return if (self.trade_type.len > 0) self.trade_type else "JSAPI";
    }
};

// ---------------------------------------------------------------------------
// 测试:剩余字段 / SignType 细分 / 消费方回退
// ---------------------------------------------------------------------------

test "SignType.fromStr matches Java ALL_SIGN_TYPES (MD5 / HMAC-SHA256 only)" {
    try std.testing.expectEqual(SignType.md5, SignType.fromStr("MD5").?);
    try std.testing.expectEqual(SignType.hmac_sha256, SignType.fromStr("HMAC-SHA256").?);
    // 非法值(Java `ALL_SIGN_TYPES.contains` 会拒绝) -> null
    try std.testing.expect(SignType.fromStr("SHA256") == null);
    try std.testing.expect(SignType.fromStr("md5") == null); // 大小写敏感
    try std.testing.expect(SignType.fromStr("") == null);
    try std.testing.expect(SignType.isLegalStr("MD5"));
    try std.testing.expect(!SignType.isLegalStr("RSA"));
    try std.testing.expectEqual(@as(usize, 2), SignType.allStrings().len);
    try std.testing.expectEqualStrings("HMAC-SHA256", SignType.hmac_sha256.str());
}

test "PayConfig remaining fields stored/freed + effectiveTradeType fallback" {
    const gpa = std.testing.allocator;
    var cfg = try PayConfig.init(gpa, .{
        .appid = "wxp",
        .mch_id = "1900010",
        .trade_type = "NATIVE",
        .sub_appid = "wxSUB",
        .sub_mch_id = "SUBMCH",
        .key_string = "BASE64_P12",
        .sign_type = .hmac_sha256,
    });
    defer cfg.deinit(); // testing.allocator 兜底:漏 free 会失败

    try std.testing.expectEqualStrings("NATIVE", cfg.trade_type);
    try std.testing.expectEqualStrings("wxSUB", cfg.sub_appid);
    try std.testing.expectEqualStrings("SUBMCH", cfg.sub_mch_id);
    try std.testing.expectEqualStrings("BASE64_P12", cfg.key_string);
    try std.testing.expectEqualStrings("NATIVE", cfg.effectiveTradeType());

    // 未配置 trade_type -> 骨架默认 JSAPI(对应 WxPayUnifiedOrderRequest 回退)
    var cfg2 = try PayConfig.init(gpa, .{ .appid = "a", .mch_id = "m" });
    defer cfg2.deinit();
    try std.testing.expectEqualStrings("JSAPI", cfg2.effectiveTradeType());
    try std.testing.expectEqualStrings("", cfg2.sub_appid);
}

test "PayConfig.loadPrivateKey: from text source, private_key_pem stored + freed" {
    const gpa = std.testing.allocator;
    var cfg = try PayConfig.init(gpa, .{ .appid = "wxp", .mch_id = "1900010" });
    defer cfg.deinit();

    try std.testing.expectEqualStrings("", cfg.private_key_pem);
    // 用内嵌测试密钥材料(非真实凭证),经 Source.text 注入。
    const pem = "-----BEGIN PRIVATE KEY-----\nTEST\n-----END PRIVATE KEY-----\n";
    try cfg.loadPrivateKey(undefined, .{ .text = pem });
    try std.testing.expectEqualStrings(pem, cfg.private_key_pem);
    // 二次加载替换旧值(deinit 只释放最终值,testing.allocator 兜底无泄漏)。
    const pem2 = "-----BEGIN PRIVATE KEY-----\nTEST2\n-----END PRIVATE KEY-----\n";
    try cfg.loadPrivateKey(undefined, .{ .text = pem2 });
    try std.testing.expectEqualStrings(pem2, cfg.private_key_pem);
}
