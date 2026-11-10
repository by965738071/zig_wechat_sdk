//! 商户客户端证书 / mTLS 接缝 —— 对应 Java `WxPayConfig.initSSLContext()` +
//! `BaseWxPayServiceImpl.post(url, xml, true)`(useCertificate 布尔位)。
//!
//! ## 调研结论(工具链重核:Zig 0.18.0-dev.954+60635c2bd)
//! V2 refund/reverse 与平台证书下载在 Java 走 `SSLContexts.custom()
//! .loadKeyMaterial(keystore, mchId.toCharArray())` 的**双向 TLS**(客户端 p12 证书)。
//! 核对本版本标准库:
//!  - `std.http.Client` 无任何客户端证书/私钥字段(只有 ca_bundle 服务端校验);
//!  - `std.crypto.tls.Client` 只有 TLS1.3 对称流量密钥(client_key/client_secret),
//!    **没有** client_certificate / 证书私钥签名握手能力。
//! 因此本版本无法用 std 完成 mTLS,也不该伪造一个"已生效"的通道。
//!
//! ## 本轮接口变更:对齐 Java `post(url, xml, boolean useKey)`(显式布尔)
//! 逐字核对 Java:`BaseWxPayServiceImpl.refund/reverseOrder` 调 `post(url, xml, true)`、
//! `unifiedOrder` 调 `post(url, xml, false)`;`WxPayServiceApacheHttpImpl.post` 据此
//! `createHttpClient(useKey)` 选 SSL/普通通道,**从不解析 url/query**。
//! 故 `check(use_key: bool, provider)` 改为由调用点显式传布尔(Java 对齐入口),
//! `Service` 的 refund/reverse/unifiedorder 各自传 true/true/false。
//! `requiresClientCert(url)`/`checkUrl(url, provider)` 作为**保留的纯函数便捷工具**
//! (Zig 侧自创、Java 无对应),其「完整 host URL 命中 / query 夹带不误命中」语义
//! 由既有 characterization 测试守护;生产调用点不再依赖它判定通道。
//!
//! ## 本文件交付(协议层 + 接缝 + 内存/占位实现 + 离线单测)
//!  - `ClientCert`:证书配置接缝(对应 WxPayConfig 的 keyString/keyPath/keyContent/sslContext);
//!  - `check(use_key, provider)`:显式布尔的接缝检查,区分"未配证书/传输层不支持",不伪造成功;
//!  - `requiresClientCert(url)`/`checkUrl(...)`:保留的 URL 便捷工具(非 Java 对齐路径);
//!  - `CertProvider` vtable + `InMemoryCertProvider`:内存/占位实现,可离线单测。
//!
//! ⚠️ 真联调需:真实商户 p12 证书 + 支持客户端证书的 TLS 栈(第三方 crate 或
//! 自行扩展 std.crypto.tls) + 微信支付网络环境。此处不提供、也不宣称已生效。
const std = @import("std");
const v2 = @import("v2.zig");

pub const Error = std.mem.Allocator.Error;

/// 需要双向 TLS 的 URL 路径(对应 Java 调用点显式传 `useKey=true` 的端点):
///  - `/secapi/pay/refund`、`/secapi/pay/reverse`:`BaseWxPayServiceImpl.refund /
///    reverseOrder` 走 `post(url, xml, true)`;
///  - `/v3/certificates`:平台证书下载。
/// ⚠️ 这是 Zig 侧自创的「按路径」便捷判定(Java 从不解析 url/query):
///    本轮已把真正的通道判定入口 `check` 改为**显式 bool**(`use_key`),
///    与 Java `post(url, xml, boolean useKey)` 对齐。此函数不再被生产通道
///    判定使用,仅由 `checkUrl` 及既有 characterization 测试保留其语义。
/// 返回 true 表示该请求 path 需携带商户客户端证书。判定步骤:先剥离
/// query/fragment(`?`/`#` 之后),再从完整 URL 里正确取出 path(保留 host 后的
/// 路径),最后按 path 段前缀匹配(后随 `/` 或结束)——故 query/fragment 里夹带
/// 的 secure 路径不会误命中,`/secapi/pay/refundX` 这类前缀也不会误命中。
pub fn requiresClientCert(url_path: []const u8) bool {
    // 1) 剥离 query/fragment:取最早的 '?' 或 '#' 之前的部分。
    var s = url_path;
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '?')) |i| end = @min(end, i);
    if (std.mem.indexOfScalar(u8, s, '#')) |i| end = @min(end, i);
    s = s[0..end];

    // 2) 从完整 URL 里正确取出 path(别把 host 一起剥掉):含 "://" 时,path
    //    起于 authority 之后的第一个 '/';裸 path 则从 0 起。这样完整 host URL
    //    里的 secure path 会落在 path 起始段,不会被 host 前缀挡住。
    var path = s;
    if (std.mem.indexOf(u8, s, "://")) |scheme| {
        const after_scheme = s[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return false;
        path = after_scheme[slash..];
    }

    // 3) 按 path 段前缀匹配:secure path 必须出现在 path 起始段,其后为 '/' 或结束。
    for (knownSecurePaths()) |sp| {
        if (std.mem.startsWith(u8, path, sp)) {
            const rest = path[sp.len..];
            if (rest.len == 0 or rest[0] == '/') return true;
        }
    }
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

/// 协议层接缝(Java 对齐入口,对应 `post(url, xml, boolean useKey)`):
/// `use_key` 由调用点显式传入(true = 需商户证书通道,如 refund/reverse;
/// false = 普通通道,如 unifiedorder),**不再解析 URL**。
/// 纯逻辑、不碰网络,可离线单测。**注意** `cert_present_transport_unsupported`
/// 仅表示"配置齐全",不代表已完成双向 TLS —— 见文件头调研结论;std 无 mTLS
/// 能力时该结果被如实记录(Service.last_mtls_status),不伪造"已生效"。
pub fn check(use_key: bool, provider: CertProvider) CheckOutcome {
    if (!use_key) return .not_required;
    const cert = provider.get() orelse return .missing_cert;
    if (!cert.isConfigured()) return .missing_cert;
    return .{ .cert_present_transport_unsupported = cert };
}

/// 保留的便捷封装(仅当调用方手里只有 URL 时):由 `requiresClientCert(url)`
/// 推断 use_key 再调 `check`。Java 对齐的生产调用点应显式走 `check(true/false)`;
/// 此封装为兼容既有「按 URL」调用方及其 query/fragment 边界语义而保留。
pub fn checkUrl(url: []const u8, provider: CertProvider) CheckOutcome {
    return check(requiresClientCert(url), provider);
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

test "check(use_key): honest outcomes, no fake success (explicit bool, Java-aligned)" {
    var none = InMemoryCertProvider{};
    // use_key=false(Java unifiedorder) -> not_required,与证书无关。
    switch (check(false, none.provider())) {
        .not_required => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // use_key=true(Java refund/reverse) + 未配证书 -> missing_cert。
    switch (check(true, none.provider())) {
        .missing_cert => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 配置了证书 -> 明确标注 transport_unsupported(不伪造"已 mTLS 生效")。
    var has = InMemoryCertProvider{ .cert = .{ .mch_id = "1900010", .key_string = "BASE64_P12" } };
    switch (check(true, has.provider())) {
        .cert_present_transport_unsupported => |c| {
            try std.testing.expectEqualStrings("BASE64_P12", c.key_string);
            try std.testing.expectEqualStrings("1900010", c.mch_id);
        },
        else => return error.UnexpectedMtlsOutcome,
    }
    // use_key=false 即便证书齐全也直接走普通通道(Java createHttpClient(false))。
    switch (check(false, has.provider())) {
        .not_required => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 证书对象存在但内容为空 -> missing_cert(对应 Java 非空校验)。
    var blank = InMemoryCertProvider{ .cert = .{ .mch_id = "1900010" } };
    switch (check(true, blank.provider())) {
        .missing_cert => {},
        else => return error.UnexpectedMtlsOutcome,
    }
}

// ---------------------------------------------------------------------------
// query/fragment 边界(characterization)+ 保留的 URL 便捷工具 checkUrl 回归
// (本轮 check 改显式 bool 后,URL 路由语义转由 checkUrl/requiresClientCert 守护)
// ---------------------------------------------------------------------------

test "requiresClientCert: query/fragment-embedded secure path no longer false-positives" {
    // 逐字核对 Java:WxPayService.post(url, requestStr, boolean useKey) 由调用点
    // 显式传布尔(BaseWxPayServiceImpl.refund 传 true、unifiedorder 传 false),
    // WxPayServiceApacheHttpImpl.post 据此 createHttpClient(useKey) 选通道,
    // 从不解析 url/query —— Zig 侧「按 url 判断」本就是骨架自创的偏差。
    // 本轮最小修:剥离 query/fragment 后按 path 段匹配,故夹带不再误命中。
    try std.testing.expect(!requiresClientCert("/pay/unifiedorder?notify=/secapi/pay/refund"));
    try std.testing.expect(!requiresClientCert("/v3/pay/transactions/jsapi?ref=/v3/certificates"));
    // 反向护栏:真正的 secure path 仍命中,普通 path 仍不命中,防止「修过头」。
    try std.testing.expect(requiresClientCert("/secapi/pay/refund"));
    try std.testing.expect(!requiresClientCert("/pay/orderquery"));
}

test "requiresClientCert: full URL + query/fragment, empty/pure-query, case, path segment boundary" {
    // 完整 host URL(必须仍命中):从完整 URL 里正确取出 path 再判断。
    try std.testing.expect(requiresClientCert("https://api.mch.weixin.qq.com/secapi/pay/refund"));
    // 完整 URL + query:真正的 secure path 带 query 仍命中(query 里即便再夹 URL 也不干扰)。
    try std.testing.expect(requiresClientCert("https://api.mch.weixin.qq.com/secapi/pay/refund?notify_url=http://x"));
    try std.testing.expect(requiresClientCert("https://api.mch.weixin.qq.com/v3/certificates?x=1"));
    // fragment:secure path 带 fragment 仍命中;普通 path 的 fragment 夹带不命中。
    try std.testing.expect(requiresClientCert("/secapi/pay/reverse#frag"));
    try std.testing.expect(!requiresClientCert("/pay/unifiedorder#/secapi/pay/refund"));
    try std.testing.expect(!requiresClientCert("/v3/pay/transactions/jsapi#ref=/v3/certificates"));
    // query + fragment 同时夹带 secure path:普通 path 不命中。
    try std.testing.expect(!requiresClientCert("/pay/unifiedorder?redirect=/secapi/pay/refund#/v3/certificates"));
    // 空串 / 纯 query / 纯 fragment:不命中。
    try std.testing.expect(!requiresClientCert(""));
    try std.testing.expect(!requiresClientCert("?notify=/secapi/pay/refund"));
    try std.testing.expect(!requiresClientCert("#/secapi/pay/refund"));
    // 大小写敏感:大写变体不命中(path 段匹配区分大小写)。
    try std.testing.expect(!requiresClientCert("/SecApi/Pay/Refund"));
    try std.testing.expect(!requiresClientCert("/V3/Certificates"));
    // 路径段边界:`refundX`/`refundv2` 不是 `/secapi/pay/refund` 的段边界延续,不命中。
    try std.testing.expect(!requiresClientCert("/secapi/pay/refundX"));
    try std.testing.expect(!requiresClientCert("/secapi/pay/refundv2"));
    // 段边界延续(子资源,后随 '/')仍命中。
    try std.testing.expect(requiresClientCert("/secapi/pay/refund/sub"));
}

test "checkUrl: query/fragment routing still characterized (legacy URL convenience)" {
    // 保留的 URL 便捷工具:配置齐全的 provider,query 夹带 secure path 的普通接口
    // 仍判 not_required(剥离 query 后按 path 段匹配),完整 host URL 仍命中。
    var has = InMemoryCertProvider{ .cert = .{ .mch_id = "1900010", .key_string = "BASE64_P12" } };
    switch (checkUrl("/pay/unifiedorder?notify=/secapi/pay/refund", has.provider())) {
        .not_required => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 真正的 secure path 带 query 仍走证书逻辑。
    switch (checkUrl("/secapi/pay/refund?foo=bar", has.provider())) {
        .cert_present_transport_unsupported => {},
        else => return error.UnexpectedMtlsOutcome,
    }
    // 未配置 provider 的 secure path 带 fragment 仍 missing_cert。
    var none = InMemoryCertProvider{};
    switch (checkUrl("/secapi/pay/reverse#frag", none.provider())) {
        .missing_cert => {},
        else => return error.UnexpectedMtlsOutcome,
    }
}
