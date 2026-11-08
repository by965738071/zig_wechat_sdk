//! 商户客户端证书 / mTLS 接缝 —— 对应 Java `WxPayConfig.initSSLContext()` +
//! `BaseWxPayServiceImpl.post(url, xml, true)`(useCertificate 布尔位)。
//!
//! ## 调研结论(Zig 0.18.0-dev.935)
//! V2 refund/reverse 与平台证书下载在 Java 走 `SSLContexts.custom()
//! .loadKeyMaterial(keystore, mchId.toCharArray())` 的**双向 TLS**(客户端 p12 证书)。
//! 核对本版本标准库:
//!  - `std.http.Client` 无任何客户端证书/私钥字段(只有 ca_bundle 服务端校验);
//!  - `std.crypto.tls.Client` 只有 TLS1.3 对称流量密钥(client_key/client_secret),
//!    **没有** client_certificate / 证书私钥签名握手能力。
//! 因此本版本无法用 std 完成 mTLS,也不该伪造一个"已生效"的通道。
//!
//! ## 本文件交付(协议层 + 接缝 + 内存/占位实现 + 离线单测)
//!  - `ClientCert`:证书配置接缝(对应 WxPayConfig 的 keyString/keyPath/keyContent/sslContext);
//!  - `requiresClientCert(path)`:协议层——哪些 URL 需客户端证书(逐字对照 Java);
//!  - `CertProvider` vtable + `InMemoryCertProvider`:内存/占位实现,可离线单测;
//!  - `check()`:发请求前的接缝检查,明确区分"未配证书/传输层不支持",不伪造成功。
//!
//! ⚠️ 真联调需:真实商户 p12 证书 + 支持客户端证书的 TLS 栈(第三方 crate 或
//! 自行扩展 std.crypto.tls) + 微信支付网络环境。此处不提供、也不宣称已生效。
const std = @import("std");
const v2 = @import("v2.zig");

pub const Error = std.mem.Allocator.Error;

/// 需要双向 TLS 的 URL 路径(逐字对照 Java):
///  - `/secapi/pay/refund`、`/secapi/pay/reverse`:Java `post(url, xml, true)`;
///  - `/v3/certificates`:`AutoUpdateCertificatesVerifier.CERT_DOWNLOAD_PATH`(平台证书下载)。
/// 注意:Java `WxPayConfig` 用 `useCertificate` 布尔位逐个判定;这里用路径前缀集中判定,
/// 语义等价且可离线单测。返回 true 表示该请求必须携带商户客户端证书。
pub fn requiresClientCert(url_path: []const u8) bool {
    // 只看 path(去掉可能的 host 前缀/query)
    const p = url_path;
    if (std.mem.indexOf(u8, p, "/secapi/pay/refund") != null) return true;
    if (std.mem.indexOf(u8, p, "/secapi/pay/reverse") != null) return true;
    if (std.mem.indexOf(u8, p, "/v3/certificates") != null) return true;
    return false;
}

/// 证书配置接缝 —— 对应 Java `WxPayConfig` 的证书相关字段:
///  - `keyString`:p12 证书 base64;
///  - `keyPath`:p12 文件路径;
///  - `keyContent`:证书字节内容(Java 另有此字段);
///  - `mchId`:同时作为 PKCS12 keystore 密码(`mchId.toCharArray()`)。
/// 字段为借用切片;真实证书/口令属敏感凭证,SDK 不内嵌、不伪造。
pub const ClientCert = struct {
    /// 商户号,Java 用它作 p12 keystore 密码
    mch_id: []const u8 = "",
    /// p12 证书 base64(对应 keyString)
    key_string: []const u8 = "",
    /// p12 文件路径(对应 keyPath)
    key_path: []const u8 = "",
    /// 证书字节(对应 keyContent)
    key_content: []const u8 = "",

    /// 是否至少配置了一种证书来源(对应 Java initSSLContext 前的非空校验)。
    pub fn isConfigured(self: ClientCert) bool {
        return self.key_string.len > 0 or self.key_path.len > 0 or self.key_content.len > 0;
    }
};

/// 证书提供者 vtable(接缝):真实实现可换成从磁盘/KMS/配置中心加载。
pub const CertProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回当前可用的证书配置;null = 未配置。
        get: *const fn (ctx: *anyopaque) ?ClientCert,
    };

    pub fn get(self: CertProvider) ?ClientCert {
        return self.vtable.get(self.ptr);
    }
};

/// 内存/占位实现:持有一份 `ClientCert`(借用),可离线单测。
pub const InMemoryCertProvider = struct {
    cert: ?ClientCert = null,

    pub fn provider(self: *InMemoryCertProvider) CertProvider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn getImpl(ctx: *anyopaque) ?ClientCert {
        const self: *InMemoryCertProvider = @ptrCast(@alignCast(ctx));
        return self.cert;
    }

    const vtable = CertProvider.VTable{ .get = getImpl };
};

/// 发请求前的接缝检查结论。显式区分各类失败,绝不把"没证书/不支持"当成成功。
pub const CheckOutcome = union(enum) {
    /// 该路径不需要客户端证书,可走普通通道。
    not_required,
    /// 需要证书且已配置;但 std.http 无 mTLS 能力,真实握手仍需外部 TLS 栈。
    cert_present_transport_unsupported: ClientCert,
    /// 需要证书但未配置(对应 Java initSSLContext 抛 WxPayException)。
    missing_cert,
};

/// 协议层接缝:给定 URL 与证书提供者,判断该请求能否按 mTLS 要求继续。
/// 纯逻辑、不碰网络,可离线单测。**注意** `cert_present_transport_unsupported`
/// 仅表示"配置齐全",不代表已完成双向 TLS —— 见文件头调研结论。
pub fn check(path: []const u8, provider: CertProvider) CheckOutcome {
    if (!requiresClientCert(path)) return .not_required;
    const cert = provider.get() orelse return .missing_cert;
    if (!cert.isConfigured()) return .missing_cert;
    return .{ .cert_present_transport_unsupported = cert };
}

/// 便捷:`v2.url.refund` / `v2.url.reverse` 是否都需证书(供 Service 注释/自检)。
pub fn knownSecurePaths() []const []const u8 {
    return &.{ v2.url.refund, v2.url.reverse, "/v3/certificates" };
}

// ---------------------------------------------------------------------------
// 离线单测
// ---------------------------------------------------------------------------

test "requiresClientCert: Java secapi refund/reverse + v3 certificates only" {
    // 逐字对照 Java 需证书的路径
    try std.testing.expect(requiresClientCert("/secapi/pay/refund"));
    try std.testing.expect(requiresClientCert("https://api.mch.weixin.qq.com/secapi/pay/refund"));
    try std.testing.expect(requiresClientCert("/secapi/pay/reverse"));
    try std.testing.expect(requiresClientCert("/v3/certificates"));
    // 普通 V2/V3 接口不需要
    try std.testing.expect(!requiresClientCert("/pay/unifiedorder"));
    try std.testing.expect(!requiresClientCert("/pay/orderquery"));
    try std.testing.expect(!requiresClientCert("/v3/pay/transactions/jsapi"));
    // v2 常量本身一致
    for (knownSecurePaths()) |p| try std.testing.expect(requiresClientCert(p));
}

test "ClientCert.isConfigured: keyString/keyPath/keyContent 任一即可, mchId 作密码" {
    try std.testing.expect(!(ClientCert{}).isConfigured());
    try std.testing.expect((ClientCert{ .key_string = "BASE64" }).isConfigured());
    try std.testing.expect((ClientCert{ .key_path = "/tmp/cert.p12" }).isConfigured());
    try std.testing.expect((ClientCert{ .key_content = "DERBYTES" }).isConfigured());
    const c = ClientCert{ .mch_id = "1900010", .key_string = "BASE64" };
    try std.testing.expectEqualStrings("1900010", c.mch_id);
}

test "InMemoryCertProvider + check: honest outcomes, no fake success" {
    // 未配置证书
    var none = InMemoryCertProvider{};
    switch (check("/secapi/pay/refund", none.provider())) {
        .missing_cert => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 普通路径:not_required(与证书无关)
    switch (check("/pay/unifiedorder", none.provider())) {
        .not_required => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 配置了证书 -> 明确标注 transport_unsupported(不伪造"已 mTLS 生效")
    var has = InMemoryCertProvider{ .cert = .{ .mch_id = "1900010", .key_string = "BASE64_P12" } };
    switch (check("/secapi/pay/refund", has.provider())) {
        .cert_present_transport_unsupported => |c| {
            try std.testing.expectEqualStrings("BASE64_P12", c.key_string);
            try std.testing.expectEqualStrings("1900010", c.mch_id);
        },
        else => return error.UnexpectedMtlsOutcome,
    }
    // 证书对象存在但内容为空 -> missing_cert(对应 Java 非空校验)
    var blank = InMemoryCertProvider{ .cert = .{ .mch_id = "1900010" } };
    switch (check("/secapi/pay/reverse", blank.provider())) {
        .missing_cert => {},
        else => return error.UnexpectedMtlsOutcome,
    }
}
