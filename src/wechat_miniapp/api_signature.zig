//! 服务端 API 签名(加密通道)—— 对应 Java `BaseWxMaServiceImpl#postWithSignature`
//! + `executor.ApiSignaturePostRequestExecutor` + `buildSignaturePayload`。
//!
//! 协议(微信「服务端 API 签名」文档):
//!   1. 请求 JSON 追加 `_n`(30 位随机 hex,对应 Java UUID 前 30 位)、
//!      `_appid`、`_timestamp`(秒);
//!   2. AES-GCM 加密明文:密钥 = `ApiSignatureAesKey` base64 解码(32 字节),
//!      iv = 12 随机字节,AAD = `urlPath|appid|timestamp|aesKeySn`,tag 128 bit;
//!   3. 请求体 = `{"iv":b64,"data":b64,"authtag":b64}`(字段顺序同 Java);
//!   4. RSA-PSS-SHA256(salt 32 = 摘要长度,对应 Java `PSSParameterSpec(…,32,1)`)
//!      对待签名串 `urlpath\nappid\ntimestamp\npostdata` 签名 —— **4 字段格式**:
//!      RSA 序列号走请求头 `Wechatmp-Serial`,**不进签名串**。Java 4.8.0 曾错插
//!      成 5 字段导致所有 API 签名路径(getPhoneNumber、同城配送等)报 40234
//!      invalid signature,见 Java buildSignaturePayload 注释;
//!   5. 请求头:`Wechatmp-Signature` / `Wechatmp-Appid` / `Wechatmp-TimeStamp` /
//!      `Wechatmp-Serial`;
//!   6. 响应同为 `{iv,data,authtag}`,AAD 用**响应头** `Wechatmp-TimeStamp` 重算;
//!      响应头 `Wechatmp-Appid` 必须与请求一致(Java 不符即抛 RuntimeException)。
//!      平台签名验签 Java 亦省略(注释「省略验证平台签名部分」),这里同样省略。
//!
//! 与 Java 的结构对应:Java 在 `post()` 里按 `urlPathSupportApiSignature` 列表
//! 自动切换加密通道;显式调 `postWithSignature` 的接口(同城配送等)不受列表
//! 限制、永远加密。两条路最终都经 `executeWithRetry` → `executeInternal`
//! (附加 access_token、-1 退避、token 失效重试)到签名执行器。
//! Zig 以**执行器装饰器**复刻同一行为:`State.executor(inner)` 包装任意
//! RequestExecutor —— POST 命中列表即透明加密,其余原样透传;Service 的 token
//! 附加 / -1 退避 / token 失效重试协议因此全部复用。唯一差异:解密后明文的
//! errcode==-1 在 Java(错误检查位于 postWithSignature,重试环之内)不重试,
//! Zig(检查在 Service 层)会随协议 1 退避重试,语义上更一致,特此注明。
//!
//! AES 密钥位数:微信签发的 API 签名 AES 密钥为 32 字节(AES-256)。Java
//! `SecretKeySpec` 亦接受 16 字节(AES-128),这里一并支持;AES-192(24 字节)
//! std 无现成 GCM 实现,init 时显式报错(注释保留,按需再补)。
//!
//! 注入点:`MiniappService.enableApiSignature(...)`(见 service.zig)。
const std = @import("std");
const rsa = @import("zig-rsa");
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const json_util = @import("common").json_util;
const mp_http = @import("wechat_mp").http;

const WxError = error_mod.WxError;
const WxResult = result_mod.WxResult;
const Response = result_mod.Response;
const RequestExecutor = mp_http.RequestExecutor;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// PSS salt 长度:32 = SHA-256 摘要长度(对应 Java PSSParameterSpec 第 4 参)。
const PSS_SALT_LEN: isize = 32;

/// Java `BaseWxMaServiceImpl#urlPathSupportApiSignature`(配置了 AES 密钥时,
/// `post()` 对下列 URL 子串自动切换加密通道;逐条对齐,含 datacube 长名)。
const java_auto_urls = [_][]const u8{
    "cgi-bin/clear_quota",
    "cgi-bin/openapi/quota/get",
    "cgi-bin/openapi/rid/get",
    "wxa/getpluginopenpid",
    "wxa/business/checkencryptedmsg",
    "wxa/business/getuserencryptkey",
    "wxa/business/getuserphonenumber",
    "wxa/getwxacode",
    "wxa/getwxacodeunlimit",
    "cgi-bin/wxaapp/createwxaqrcode",
    "cgi-bin/message/custom/send",
    "cgi-bin/message/wxopen/updatablemsg/send",
    "wxaapi/newtmpl/deltemplate",
    "cgi-bin/message/subscribe/send",
    "wxaapi/newtmpl/addtemplate",
    "wxa/msg_sec_check",
    "wxa/media_check_async",
    "wxa/getuserriskrank",
    "datacube/getweanalysisappidweeklyretaininfo",
    "datacube/getweanalysisappidmonthlyretaininfo",
    "datacube/getweanalysisappiddailyretaininfo",
    "datacube/getweanalysisappidmonthlyvisittrend",
    "datacube/getweanalysisappiddailyvisittrend",
    "datacube/getweanalysisappidweeklyvisittrend",
    "datacube/getweanalysisappiddailysummarytrend",
    "datacube/getweanalysisappidvisitpage",
    "datacube/getweanalysisappiduserportrait",
    "wxa/business/performance/boot",
    "datacube/getweanalysisappidvisitdistribution",
    "wxa/getwxadevinfo",
    "wxaapi/log/get_performance",
    "wxaapi/log/jserr_detail",
    "wxaapi/log/jserr_list",
    "wxa/devplugin",
    "wxa/plugin",
    "cgi-bin/express/business/account/getall",
    "cgi-bin/express/business/delivery/getall",
    "cgi-bin/express/business/printer/getall",
    "wxa/servicemarket",
    "cgi-bin/soter/verify_signature",
};

/// 同城配送(除 apply 外全部要求签名)。Java 侧这些接口显式调
/// `postWithSignature`(不查列表),等价于「永远加密」;Zig 把它们放进装饰器
/// 匹配列表,`IntracityService` 未启用签名时先行快速失败,线上行为一致。
const intracity_force_urls = [_][]const u8{
    "express/intracity/createstore",
    "express/intracity/querystore",
    "express/intracity/updatestore",
    "express/intracity/storecharge",
    "express/intracity/storerefund",
    "express/intracity/queryflow",
    "express/intracity/balancequery",
    "express/intracity/getpaymode",
    "express/intracity/setpaymode",
    "express/intracity/preaddorder",
    "express/intracity/addorder",
    "express/intracity/queryorder",
    "express/intracity/cancelorder",
    "express/intracity/getcity",
};

fn isSignatureUrl(method: RequestExecutor.Method, uri: []const u8) bool {
    if (method != .post) return false; // Java 只在 post() 重载里路由,get() 不加密
    for (java_auto_urls) |u| {
        if (std.mem.indexOf(u8, uri, u) != null) return true;
    }
    for (intracity_force_urls) |u| {
        if (std.mem.indexOf(u8, uri, u) != null) return true;
    }
    return false;
}

/// 对应 Java 静态方法 `buildSignaturePayload`(4 字段,`\n` 分隔,末尾无换行)。
pub fn buildSignaturePayload(gpa: std.mem.Allocator, url_path: []const u8, appid: []const u8, timestamp: i64, postdata: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n{d}\n{s}", .{ url_path, appid, timestamp, postdata });
}

const GcmKey = union(enum) {
    a128: [16]u8,
    a256: [32]u8,
};

fn parseAesKey(raw: []const u8) !GcmKey {
    return switch (raw.len) {
        16 => .{ .a128 = raw[0..16].* },
        32 => .{ .a256 = raw[0..32].* },
        else => error.BadAesKeyLen, // 24 字节(AES-192)std 无现成 GCM,见文件头注
    };
}

/// AES-GCM 加密:返回 gpa 拥有的密文 + 16 字节 tag(对应 Java 里
/// doFinal 结果拆成 encryptedData + authTag)。
fn gcmEncrypt(key: GcmKey, nonce: [12]u8, aad: []const u8, plain: []const u8, gpa: std.mem.Allocator) !struct { ct: []u8, tag: [16]u8 } {
    const ct = try gpa.alloc(u8, plain.len);
    errdefer gpa.free(ct);
    var tag: [16]u8 = undefined;
    switch (key) {
        .a128 => |k| std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(ct, &tag, plain, aad, nonce, k),
        .a256 => |k| std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct, &tag, plain, aad, nonce, k),
    }
    return .{ .ct = ct, .tag = tag };
}

/// AES-GCM 解密(data 与 tag 分离的响应格式)。
fn gcmDecrypt(key: GcmKey, nonce: [12]u8, aad: []const u8, data: []const u8, tag: [16]u8, gpa: std.mem.Allocator) ![]u8 {
    const plain = try gpa.alloc(u8, data.len);
    errdefer gpa.free(plain);
    switch (key) {
        .a128 => |k| try std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(plain, data, tag, aad, nonce, k),
        .a256 => |k| try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plain, data, tag, aad, nonce, k),
    }
    return plain;
}

fn b64Encode(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(raw.len));
    errdefer gpa.free(out);
    _ = enc.encode(out, raw);
    return out;
}

fn b64Decode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return error.BadBase64;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    dec.decode(out, s) catch return error.BadBase64;
    return out;
}

/// 配置参数(对应 WxMaConfig 的四个 apiSignature* 字段 + getWechatMpAppid)。
pub const Args = struct {
    /// `ApiSignatureAesKey`:base64 编码的 AES 密钥(解码后 16/32 字节)。
    aes_key: []const u8,
    /// `ApiSignatureAesKeySn`:AES 密钥序号(进 AAD,不进签名串)。
    aes_key_sn: []const u8,
    /// `ApiSignatureRsaPrivateKey`:PKCS#8 PEM(兼容 PKCS#1,与 pay 的 KeySigner 同)。
    rsa_private_key: []const u8,
    /// `ApiSignatureRsaPrivateKeySn`:RSA 序列号(走请求头 Wechatmp-Serial)。
    rsa_key_sn: []const u8,
    /// `getWechatMpAppid`:普通小程序留 null → 取 ConfigStorage.appid();
    /// 托管第三方平台传 componentAppId。
    appid: ?[]const u8 = null,
};

/// 签名状态 + 装饰器执行器。由 `MiniappService` 持有(值字段),**MiniappService
/// 初始化后不得再移动**(与子服务同一约束 —— 装饰器 ptr 指向 State)。
pub const State = struct {
    gpa: std.mem.Allocator,
    aes: GcmKey,
    aes_key_sn: []u8,
    rsa_key_sn: []u8,
    appid: []u8,
    sk: rsa.SecretKey,
    inner: RequestExecutor,

    pub const InitError = error{ OutOfMemory, BadAesKeyLen, BadBase64, BadRsaKey };

    pub fn init(gpa: std.mem.Allocator, inner: RequestExecutor, args: Args, fallback_appid: []const u8) InitError!State {
        // raw 的释放收在小块内(defer 块结束即释放),避免 errdefer 活到函数尾
        // 与显式 free 重复。
        const key = key: {
            const raw = b64Decode(gpa, args.aes_key) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadBase64,
            };
            defer gpa.free(raw);
            break :key parseAesKey(raw) catch return error.BadAesKeyLen;
        };

        var st: State = .{
            .gpa = gpa,
            .aes = key,
            .aes_key_sn = try gpa.dupe(u8, args.aes_key_sn),
            .rsa_key_sn = try gpa.dupe(u8, args.rsa_key_sn),
            .appid = try gpa.dupe(u8, args.appid orelse fallback_appid),
            .sk = undefined,
            .inner = inner,
        };
        errdefer {
            gpa.free(st.aes_key_sn);
            gpa.free(st.rsa_key_sn);
            gpa.free(st.appid);
        }
        st.sk = parseRsaSecretKey(gpa, args.rsa_private_key) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadRsaKey,
        };
        return st;
    }

    pub fn deinit(self: *State) void {
        self.sk.deinit(self.gpa);
        self.gpa.free(self.aes_key_sn);
        self.gpa.free(self.rsa_key_sn);
        self.gpa.free(self.appid);
        self.* = undefined;
    }

    /// 装饰器执行器:套在(inner)执行器外层,命中签名列表的 POST 透明加密。
    pub fn executor(self: *State) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        const r = executeWithHeadersImpl(ctx, gpa, io, method, uri, &.{}, body);
        return switch (r) {
            .ok => |resp| .{ .ok = resp.takeBody(gpa) },
            .err => |e| .{ .err = e },
        };
    }

    fn executeExImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult(Response) {
        return executeWithHeadersImpl(ctx, gpa, io, method, uri, &.{}, body);
    }

    fn executeWithHeadersImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: RequestExecutor.Method, uri: []const u8, req_headers: []const result_mod.Header, body: ?[]const u8) WxResult(Response) {
        const st: *State = @ptrCast(@alignCast(ctx));
        if (!isSignatureUrl(method, uri)) return st.inner.executeWithHeaders(gpa, io, method, uri, req_headers, body);
        const b = body orelse "{}";
        return st.signedPost(gpa, io, uri, b);
    }

    const vtable = RequestExecutor.VTable{
        .execute = executeImpl,
        .execute_ex = executeExImpl,
        .execute_with_headers = executeWithHeadersImpl,
    };

    /// 对应 Java `postWithSignature(url, jsonObject)` 的主体:
    /// 注入字段 → AES-GCM 加密 → RSA-PSS 签名 → 带 4 头发送 → 解密响应。
    fn signedPost(st: *State, gpa: std.mem.Allocator, io: std.Io, uri: []const u8, body: []const u8) WxResult(Response) {
        const url_path = urlPathOf(uri);
        const ts: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

        // 1. 注入 _n/_appid/_timestamp(对应 Java jsonObject.addProperty)
        const plain = injectFields(io, gpa, body, st.appid, ts) catch |e| return sigErr(gpa, e);
        defer gpa.free(plain);

        // 2. AES-GCM 加密(iv 随机,AAD=urlPath|appid|ts|aesKeySn)
        var nonce: [12]u8 = undefined;
        std.Io.randomSecure(io, &nonce) catch return sigErr(gpa, error.RngFail);
        const aad = std.fmt.allocPrint(gpa, "{s}|{s}|{d}|{s}", .{ url_path, st.appid, ts, st.aes_key_sn }) catch
            return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(aad);
        const enc = gcmEncrypt(st.aes, nonce, aad, plain, gpa) catch |e| return sigErr(gpa, e);
        defer gpa.free(enc.ct);

        // 3. 请求体 {"iv","data","authtag"}(顺序同 Java)
        const iv_b64 = b64Encode(gpa, &nonce) catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(iv_b64);
        const data_b64 = b64Encode(gpa, enc.ct) catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(data_b64);
        const tag_b64 = b64Encode(gpa, &enc.tag) catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(tag_b64);
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("iv", iv_b64) catch return sigErr(gpa, error.OutOfMemory);
        ob.putStr("data", data_b64) catch return sigErr(gpa, error.OutOfMemory);
        ob.putStr("authtag", tag_b64) catch return sigErr(gpa, error.OutOfMemory);
        const req_json = ob.toJson() catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(req_json);

        // 4. RSA-PSS 签名(4 字段待签名串;rsaKeySn 不进签名串)
        const payload = buildSignaturePayload(gpa, url_path, st.appid, ts, req_json) catch
            return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(payload);
        // 本版 std 已删 std.crypto.random，用 std.Random.IoSource 适配 io
        const io_src = std.Random.IoSource{ .io = io };
        const sig = rsa.signPss(gpa, io_src.interface(), st.sk, Sha256, payload, .{ .salt_leng = PSS_SALT_LEN }) catch
            return sigErr(gpa, error.RsaSign);
        defer gpa.free(sig);
        const sig_b64 = b64Encode(gpa, sig) catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(sig_b64);
        const ts_str = std.fmt.allocPrint(gpa, "{d}", .{ts}) catch return sigErr(gpa, error.OutOfMemory);
        defer gpa.free(ts_str);

        // 5. 四个 Wechatmp-* 头;uri 原样(Service 层已附加 access_token,同 Java)
        const headers = [_]result_mod.Header{
            .{ .name = "Wechatmp-Signature", .value = sig_b64 },
            .{ .name = "Wechatmp-Appid", .value = st.appid },
            .{ .name = "Wechatmp-TimeStamp", .value = ts_str },
            .{ .name = "Wechatmp-Serial", .value = st.rsa_key_sn },
        };
        const resp = switch (st.inner.executeWithHeaders(gpa, io, .post, uri, &headers, req_json)) {
            .ok => |r| r,
            .err => |e| return .{ .err = e }, // 网络层错误原样上抛(-1 退避在 Service 层)
        };
        // resp 的 body/headers 由 gpa 拥有;以下失败路径显式 deinit

        // 6. 校验响应头 + 解密(AAD 用响应头里的 Wechatmp-TimeStamp 重算)
        const resp_appid = resp.header("Wechatmp-Appid") orelse {
            resp.deinit(gpa);
            return sigErr(gpa, error.ResponseNoHeaders);
        };
        if (!std.mem.eql(u8, resp_appid, st.appid)) {
            resp.deinit(gpa);
            return sigErr(gpa, error.AppidMismatch);
        }
        const resp_ts = resp.header("Wechatmp-TimeStamp") orelse {
            resp.deinit(gpa);
            return sigErr(gpa, error.ResponseNoHeaders);
        };
        const plain_out = decryptResponse(gpa, st.aes, url_path, st.appid, resp_ts, st.aes_key_sn, resp.body) catch |e| {
            resp.deinit(gpa);
            return sigErr(gpa, e);
        };
        gpa.free(resp.body);
        // 响应头所有权随 Response 转移(明文 + 原始响应头)
        return .{ .ok = .{ .body = plain_out, .headers = resp.headers } };
    }
};

const SigError = error{
    OutOfMemory,
    NotJsonObject,
    BadAesKeyLen,
    RsaSign,
    RngFail,
    ResponseNoHeaders,
    AppidMismatch,
    BadResponseFormat,
    AuthFailed,
};

/// 注：入参用 anyerror 承接 injectFields/decryptResponse 的宽错误集(JSON 解析、
/// 随机数等)，具名分支逐一映射，其余折叠为通用内部错误。
fn sigErr(gpa: std.mem.Allocator, e: anyerror) WxResult(Response) {
    const we: WxError = switch (e) {
        error.OutOfMemory => WxError.internal(gpa, "oom", .{}),
        error.NotJsonObject => WxError.internal(gpa, "签名请求体必须是 JSON 对象", .{}),
        error.BadAesKeyLen => WxError.configError(gpa, "ApiSignatureAesKey 需为 16/32 字节(AES-128/256)", .{}),
        error.RsaSign => WxError.internal(gpa, "RSA-PSS 签名失败", .{}),
        error.RngFail, error.EntropyUnavailable => WxError.internal(gpa, "获取随机数失败", .{}),
        error.ResponseNoHeaders => WxError.internal(gpa, "执行器未回传响应头,无法解密签名响应", .{}),
        error.AppidMismatch => WxError.internal(gpa, "响应的 appId 不符", .{}),
        error.BadResponseFormat => WxError.internal(gpa, "签名响应不是合法的 iv/data/authtag", .{}),
        error.AuthFailed => WxError.internal(gpa, "签名响应解密失败(authtag 校验不过)", .{}),
        else => WxError.internal(gpa, "签名请求体不是合法 JSON", .{}),
    };
    return .{ .err = we };
}

/// 归一化 URL → 签名口径的 path:去 `scheme://host`(若带)并去 query。
/// Service 层可能传完整 URL 或纯路径,AAD/验签必须与呈现形式无关。
pub fn urlPathOf(uri: []const u8) []const u8 {
    var p = uri;
    if (std.mem.indexOf(u8, uri, "://")) |i| {
        const rest = uri[i + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
        p = rest[slash..];
    }
    return p[0..(std.mem.indexOfScalar(u8, p, '?') orelse p.len)];
}

/// 注入 `_n`/`_appid`/`_timestamp`(对应 Java `jsonObject.addProperty`,追加在
/// 原 object 末尾;`_n` = 15 随机字节的 30 位小写 hex)。body 为空串/空白 → `{}`。
fn injectFields(io: std.Io, gpa: std.mem.Allocator, body: []const u8, appid: []const u8, ts: i64) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    var parsed = try json_util.parse(gpa, if (trimmed.len == 0) "{}" else trimmed);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotJsonObject,
    };
    // 不能直接向解析产物(arena 承载)的 map 上 put(gpa):扩容时会用 gpa free
    // arena 内存。重建一份 gpa 拥有的 map 再注入(键/值仅借用 parsed 的生存期,
    // stringify 在 parsed.deinit 之前完成)。
    var out: json_util.ObjectMap = .empty;
    defer out.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |e| try out.put(gpa, e.key_ptr.*, e.value_ptr.*);
    var rnd: [15]u8 = undefined;
    try std.Io.randomSecure(io, &rnd);
    const n_hex = std.fmt.bytesToHex(rnd, .lower);
    try out.put(gpa, "_n", .{ .string = &n_hex });
    try out.put(gpa, "_appid", .{ .string = appid });
    try out.put(gpa, "_timestamp", .{ .integer = ts });
    return json_util.stringify(gpa, json_util.Value{ .object = out });
}

/// 解密响应体 `{iv,data,authtag}`(AAD 用响应头 ts 重算)。返回 gpa 拥有的明文。
fn decryptResponse(gpa: std.mem.Allocator, key: GcmKey, url_path: []const u8, appid: []const u8, resp_ts: []const u8, aes_key_sn: []const u8, body: []const u8) ![]u8 {
    const parsed = json_util.parse(gpa, body) catch return error.BadResponseFormat;
    defer parsed.deinit();
    const iv_s = json_util.getStr(parsed.value, "iv") orelse return error.BadResponseFormat;
    const data_s = json_util.getStr(parsed.value, "data") orelse return error.BadResponseFormat;
    const tag_s = json_util.getStr(parsed.value, "authtag") orelse return error.BadResponseFormat;

    const iv_raw = b64Decode(gpa, iv_s) catch return error.BadResponseFormat;
    defer gpa.free(iv_raw);
    if (iv_raw.len != 12) return error.BadResponseFormat;
    const data_raw = b64Decode(gpa, data_s) catch return error.BadResponseFormat;
    defer gpa.free(data_raw);
    const tag_raw = b64Decode(gpa, tag_s) catch return error.BadResponseFormat;
    defer gpa.free(tag_raw);
    if (tag_raw.len != 16) return error.BadResponseFormat;

    const aad = std.fmt.allocPrint(gpa, "{s}|{s}|{s}|{s}", .{ url_path, appid, resp_ts, aes_key_sn }) catch return error.OutOfMemory;
    defer gpa.free(aad);
    return gcmDecrypt(key, iv_raw[0..12].*, aad, data_raw, tag_raw[0..16].*, gpa) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AuthFailed,
    };
}

/// PEM(PKCS#8 `PRIVATE KEY` / PKCS#1 `RSA PRIVATE KEY`)→ `rsa.SecretKey`。
/// 与 `wechat_pay/sign.zig` 的 `pemBodyToDer` + `KeySigner.fromPem` 同构
/// (彼处为私有,模块间不互通,故复制;改动需两处同步)。
pub fn parseRsaSecretKey(gpa: std.mem.Allocator, pem: []const u8) !rsa.SecretKey {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return error.BadRsaKey;
    const nl = std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return error.BadRsaKey;
    const end = std.mem.indexOfPos(u8, pem, nl, "-----END") orelse return error.BadRsaKey;

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(gpa);
    for (pem[nl + 1 .. end]) |ch| {
        if (!std.ascii.isWhitespace(ch)) try list.append(gpa, ch);
    }
    const b64 = try list.toOwnedSlice(gpa);
    defer gpa.free(b64);

    const cap = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.BadRsaKey;
    const der = try gpa.alloc(u8, cap);
    defer gpa.free(der);
    std.base64.standard.Decoder.decode(der, b64) catch return error.BadRsaKey;

    return rsa.SecretKey.fromDerAuto(gpa, der) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.BadRsaKey;
    };
}

// ---------------------------------------------------------------------------

test "buildSignaturePayload: 4 字段格式" {
    const gpa = std.testing.allocator;
    const p = try buildSignaturePayload(gpa, "/cgi-bin/express/intracity/createstore", "wxAPP", 1700000000, "{\"a\":1}");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/cgi-bin/express/intracity/createstore\nwxAPP\n1700000000\n{\"a\":1}", p);
}

test "injectFields: _n 30 位 hex + _appid/_timestamp 注入在原字段之后" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out = try injectFields(io, gpa, "{\"out_store_id\":\"S1\"}", "wxAPP", 1700000000);
    defer gpa.free(out);
    const parsed = try json_util.parse(gpa, out);
    defer parsed.deinit();
    const n = json_util.getStr(parsed.value, "_n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 30), n.len);
    for (n) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    try std.testing.expectEqualStrings("wxAPP", json_util.getStr(parsed.value, "_appid").?);
    try std.testing.expectEqual(@as(i64, 1700000000), json_util.getInt(parsed.value, "_timestamp").?);
    try std.testing.expectEqualStrings("S1", json_util.getStr(parsed.value, "out_store_id").?);

    // 空体 → {}
    const empty = try injectFields(io, gpa, "", "wxAPP", 1);
    defer gpa.free(empty);
    const p2 = try json_util.parse(gpa, empty);
    defer p2.deinit();
    try std.testing.expect(json_util.getStr(p2.value, "_n") != null);
}

test "AES-GCM encrypt/decrypt roundtrip(16/32 字节密钥)" {
    const gpa = std.testing.allocator;
    inline for (.{ 16, 32 }) |klen| {
        // 固定模式填充即可:roundtrip 只验证加解密互逆,不需要真随机
        var key: [klen]u8 = undefined;
        @memset(&key, 0x5a);
        var nonce: [12]u8 = undefined;
        @memset(&nonce, 0xa5);
        const plain = "同城配送加密通道 plaintext 中文";
        const enc = try gcmEncrypt(parseAesKey(&key) catch unreachable, nonce, "aad|data", plain, gpa);
        defer gpa.free(enc.ct);
        const dec = try gcmDecrypt(parseAesKey(&key) catch unreachable, nonce, "aad|data", enc.ct, enc.tag, gpa);
        defer gpa.free(dec);
        try std.testing.expectEqualStrings(plain, dec);

        // AAD 不符 → 认证失败
        const bad = gcmDecrypt(parseAesKey(&key) catch unreachable, nonce, "wrong", enc.ct, enc.tag, gpa);
        try std.testing.expectError(error.AuthenticationFailed, bad);
    }
    // 24 字节 → BadAesKeyLen
    try std.testing.expectError(error.BadAesKeyLen, parseAesKey("0123456789abcdef012345"));
}

// ---- 全链路测试(SigMock 服务端对端;测试密钥见 _sig_mock.zig)--------------------

const sig_mock = @import("_sig_mock.zig");
const service_mod = @import("service.zig");
const intracity = @import("intracity.zig");
const mock_mod = @import("_mock.zig");

const PLAIN_QUERYSTORE = "{\"store_list\":[{\"wx_store_id\":\"WS1\",\"store_name\":\"同城门店\"}]}";

test "api signature: 装饰器全链路 加密→签名→对端验签解密→响应解密" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sk = try parseRsaSecretKey(gpa, sig_mock.TEST_PRIV_PEM);
    defer sk.deinit(gpa);
    var mock = sig_mock.SigMock.init(gpa, sig_mock.TEST_AES_KEY[0..32].*, sig_mock.AES_KEY_SN, sig_mock.RSA_KEY_SN, sig_mock.TEST_APPID, sk.public_key, &.{
        .{ .match = "express/intracity/querystore", .response = PLAIN_QUERYSTORE },
    });
    defer mock.deinit();

    var st = try State.init(gpa, mock.executor(), .{
        .aes_key = sig_mock.TEST_AES_KEY_B64,
        .aes_key_sn = sig_mock.AES_KEY_SN,
        .rsa_private_key = sig_mock.TEST_PRIV_PEM,
        .rsa_key_sn = sig_mock.RSA_KEY_SN,
        .appid = sig_mock.TEST_APPID,
    }, "FALLBACK_APP");
    defer st.deinit();

    var resp = switch (st.executor().executeWithHeaders(gpa, io, .post, "https://api.weixin.qq.com/cgi-bin/express/intracity/querystore?access_token=TOK", &.{}, "{\"out_store_id\":\"OUT1\"}")) {
        .ok => |r| r,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer resp.deinit(gpa);

    // 对端:验签/头校验全部通过;uri 原样透传(access_token 由 Service 层附加)
    try std.testing.expect(mock.signature_verified);
    try std.testing.expect(mock.serial_ok);
    try std.testing.expect(mock.appid_ok);
    try std.testing.expect(mock.header_ts_ok);
    try std.testing.expectEqualStrings("/cgi-bin/express/intracity/querystore", mock.urlPath());

    // 请求明文 = 业务字段 + 注入字段(_n 30 位小写 hex)
    const p = try json_util.parse(gpa, mock.last_plain.?);
    defer p.deinit();
    try std.testing.expectEqualStrings("OUT1", json_util.getStr(p.value, "out_store_id").?);
    try std.testing.expectEqualStrings(sig_mock.TEST_APPID, json_util.getStr(p.value, "_appid").?);
    const n = json_util.getStr(p.value, "_n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 30), n.len);
    try std.testing.expect(json_util.getInt(p.value, "_timestamp") != null);

    // 响应 = 路由表明文(mock 用请求头之外的响应侧 ts 加密,证明解密读响应头);
    // 响应头原样保留。
    try std.testing.expectEqualStrings(PLAIN_QUERYSTORE, resp.body);
    try std.testing.expectEqualStrings("1700000001", resp.header("Wechatmp-TimeStamp").?);
    try std.testing.expectEqualStrings(sig_mock.TEST_APPID, resp.header("Wechatmp-Appid").?);
}

test "api signature: 非签名路径透传(GET 与未列 URL 的 POST 均明文)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sk = try parseRsaSecretKey(gpa, sig_mock.TEST_PRIV_PEM);
    defer sk.deinit(gpa);
    var mock = sig_mock.SigMock.init(gpa, sig_mock.TEST_AES_KEY[0..32].*, sig_mock.AES_KEY_SN, sig_mock.RSA_KEY_SN, sig_mock.TEST_APPID, sk.public_key, &.{
        .{ .match = "express/intracity/apply", .response = "{\"errcode\":0}" },
        .{ .match = "express/intracity/querystore", .response = "{\"errcode\":0}" },
    });
    defer mock.deinit();

    var st = try State.init(gpa, mock.executor(), .{
        .aes_key = sig_mock.TEST_AES_KEY_B64,
        .aes_key_sn = sig_mock.AES_KEY_SN,
        .rsa_private_key = sig_mock.TEST_PRIV_PEM,
        .rsa_key_sn = sig_mock.RSA_KEY_SN,
        .appid = sig_mock.TEST_APPID,
    }, "FB");
    defer st.deinit();
    const exec = st.executor();

    // POST 未列入强制/自动列表(apply,同 Java)→ 透传明文
    const r1 = switch (exec.execute(gpa, io, .post, "https://api.weixin.qq.com/cgi-bin/express/intracity/apply?access_token=TOK", "{}")) {
        .ok => |b| b,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(r1);
    try std.testing.expect(!mock.signature_verified);
    try std.testing.expectEqualStrings("{}", mock.saw_plain_body.?);
    try std.testing.expectEqualStrings("{\"errcode\":0}", r1);

    // GET 命中签名 URL → 仍明文(Java 只在 post() 重载里路由)
    const r2 = switch (exec.execute(gpa, io, .get, "https://api.weixin.qq.com/cgi-bin/express/intracity/querystore?access_token=TOK", "{}")) {
        .ok => |b| b,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(r2);
    try std.testing.expect(!mock.signature_verified);
    try std.testing.expectEqualStrings("{}", mock.saw_plain_body.?);
    try std.testing.expectEqualStrings("{\"errcode\":0}", r2);
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
}

test "api signature: Java 自动列表 URL(getuserphonenumber)POST 透明加密" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sk = try parseRsaSecretKey(gpa, sig_mock.TEST_PRIV_PEM);
    defer sk.deinit(gpa);
    var mock = sig_mock.SigMock.init(gpa, sig_mock.TEST_AES_KEY[0..32].*, sig_mock.AES_KEY_SN, sig_mock.RSA_KEY_SN, sig_mock.TEST_APPID, sk.public_key, &.{
        .{ .match = "getuserphonenumber", .response = "{\"errcode\":0,\"phone_info\":{\"purePhoneNumber\":\"13800138000\"}}" },
    });
    defer mock.deinit();

    var st = try State.init(gpa, mock.executor(), .{
        .aes_key = sig_mock.TEST_AES_KEY_B64,
        .aes_key_sn = sig_mock.AES_KEY_SN,
        .rsa_private_key = sig_mock.TEST_PRIV_PEM,
        .rsa_key_sn = sig_mock.RSA_KEY_SN,
        .appid = sig_mock.TEST_APPID,
    }, "FB");
    defer st.deinit();

    const b = switch (st.executor().execute(gpa, io, .post, "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=TOK", "{\"code\":\"CODE1\"}")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(b);
    try std.testing.expect(mock.signature_verified);
    try std.testing.expectEqualStrings("{\"errcode\":0,\"phone_info\":{\"purePhoneNumber\":\"13800138000\"}}", b);
    const p = try json_util.parse(gpa, mock.last_plain.?);
    defer p.deinit();
    try std.testing.expectEqualStrings("CODE1", json_util.getStr(p.value, "code").?);
    try std.testing.expectEqualStrings(sig_mock.TEST_APPID, json_util.getStr(p.value, "_appid").?);
}

test "api signature: State.init 参数校验(密钥长度/base64/PEM)与 appid 回退" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sk = try parseRsaSecretKey(gpa, sig_mock.TEST_PRIV_PEM);
    defer sk.deinit(gpa);
    var mock = sig_mock.SigMock.init(gpa, sig_mock.TEST_AES_KEY[0..32].*, sig_mock.AES_KEY_SN, sig_mock.RSA_KEY_SN, "FB_APP", sk.public_key, &.{
        .{ .match = "express/intracity/getcity", .response = "{\"errcode\":0}" },
    });
    defer mock.deinit();

    const ok_args = Args{
        .aes_key = sig_mock.TEST_AES_KEY_B64,
        .aes_key_sn = sig_mock.AES_KEY_SN,
        .rsa_private_key = sig_mock.TEST_PRIV_PEM,
        .rsa_key_sn = sig_mock.RSA_KEY_SN,
    };

    // AES-192(24 字节)→ BadAesKeyLen;坏 base64 → BadBase64;坏 PEM → BadRsaKey
    var b64_buf: [64]u8 = undefined;
    const b64_24 = std.base64.standard.Encoder.encode(&b64_buf, "0123456789abcdef012345");
    try std.testing.expectError(error.BadAesKeyLen, State.init(gpa, mock.executor(), .{ .aes_key = b64_24, .aes_key_sn = "k", .rsa_private_key = sig_mock.TEST_PRIV_PEM, .rsa_key_sn = "r" }, "FB_APP"));
    try std.testing.expectError(error.BadBase64, State.init(gpa, mock.executor(), .{ .aes_key = "not-base64!!", .aes_key_sn = "k", .rsa_private_key = sig_mock.TEST_PRIV_PEM, .rsa_key_sn = "r" }, "FB_APP"));
    try std.testing.expectError(error.BadRsaKey, State.init(gpa, mock.executor(), .{ .aes_key = sig_mock.TEST_AES_KEY_B64, .aes_key_sn = "k", .rsa_private_key = "junk", .rsa_key_sn = "r" }, "FB_APP"));
    try std.testing.expectEqual(@as(usize, 0), mock.calls);

    // args.appid = null → 回退 fallback_appid(签名头/明文均用回退值)
    var st = try State.init(gpa, mock.executor(), .{ .aes_key = ok_args.aes_key, .aes_key_sn = ok_args.aes_key_sn, .rsa_private_key = ok_args.rsa_private_key, .rsa_key_sn = ok_args.rsa_key_sn }, "FB_APP");
    defer st.deinit();
    const b = switch (st.executor().execute(gpa, io, .post, "https://api.weixin.qq.com/cgi-bin/express/intracity/getcity?access_token=TOK", "{}")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(b);
    try std.testing.expect(mock.signature_verified);
    try std.testing.expect(mock.appid_ok);
    const p = try json_util.parse(gpa, mock.last_plain.?);
    defer p.deinit();
    try std.testing.expectEqualStrings("FB_APP", json_util.getStr(p.value, "_appid") orelse return error.TestUnexpectedResult);
}

test "api signature: createStore 全链路经 Service(签名/头/明文组包/wx_store_id 解析)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/createstore", .response = "{\"errcode\":0,\"wx_store_id\":\"WS_NEW\"}" },
    });
    defer h.deinit();

    var store = intracity.Store{
        .out_store_id = "OUT1",
        .store_name = "同城门店",
        .city_id = "C1",
        .address_info = .{ .province = "广东", .city = "深圳", .lat = 22.5, .lng = 114.05 },
    };
    const wx_store_id = switch (h.ma.intracity().createStore(io, &store)) {
        .ok => |id| id,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(wx_store_id);
    try std.testing.expectEqualStrings("WS_NEW", wx_store_id);

    try std.testing.expect(h.mock.signature_verified);
    try std.testing.expect(h.mock.serial_ok);
    try std.testing.expect(h.mock.appid_ok);
    try std.testing.expect(h.mock.header_ts_ok);

    // 明文 = 业务字段(含恒序列化的 order_pattern)+ 注入字段
    const p = try json_util.parse(gpa, h.mock.last_plain.?);
    defer p.deinit();
    try std.testing.expectEqualStrings("OUT1", json_util.getStr(p.value, "out_store_id").?);
    try std.testing.expectEqualStrings("同城门店", json_util.getStr(p.value, "store_name").?);
    try std.testing.expectEqual(@as(i64, 1), json_util.getInt(p.value, "order_pattern").?);
    try std.testing.expectEqualStrings(sig_mock.TEST_APPID, json_util.getStr(p.value, "_appid").?);
    try std.testing.expect(json_util.getStr(p.value, "_n") != null);
    try std.testing.expect(json_util.getInt(p.value, "_timestamp") != null);
}

test "api signature: 签名响应 errcode≠0 经解密后折叠为 .err(wechat_api)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/querystore", .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" },
    });
    defer h.deinit();

    switch (h.ma.intracity().listAllStores(io)) {
        .ok => return error.Unexpected,
        .err => |e0| {
            var e = e0;
            defer e.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.wechat_api, e.source);
            try std.testing.expectEqual(@as(i64, 40001), e.error_code);
        },
    }
}

test "api signature: 未启用签名 intracity 快速失败;重复 enable 报 AlreadyEnabled;disable 恢复" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var ma: service_mod.MiniappService = undefined;
    ma.init(gpa, cfg.config(), m.executor());

    // 未启用:intracity 立即 configError,不发起任何 HTTP
    switch (ma.intracity().listAllStores(io)) {
        .ok => return error.Unexpected,
        .err => |e0| {
            var e = e0;
            defer e.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.config, e.source);
        },
    }
    try std.testing.expectEqual(@as(usize, 0), m.calls);

    const args = Args{
        .aes_key = sig_mock.TEST_AES_KEY_B64,
        .aes_key_sn = sig_mock.AES_KEY_SN,
        .rsa_private_key = sig_mock.TEST_PRIV_PEM,
        .rsa_key_sn = sig_mock.RSA_KEY_SN,
    };
    try ma.enableApiSignature(args);
    try std.testing.expectError(error.AlreadyEnabled, ma.enableApiSignature(args));
    ma.disableApiSignature();

    // 恢复:装饰器已摘除,回到未启用(configError);且可重新启用
    switch (ma.intracity().listAllStores(io)) {
        .ok => return error.Unexpected,
        .err => |e0| {
            var e = e0;
            defer e.deinit();
            try std.testing.expectEqual(error_mod.WxError.Source.config, e.source);
        },
    }
    try ma.enableApiSignature(args);
    ma.disableApiSignature();
}
