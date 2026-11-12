//! 公众号「回调闭环」统一处理 —— 把微信服务器回调的 GET 校验 / POST 明文 /
//! POST 兼容/安全(加密) 三种请求,连同验签、解密、默认排重、路由、加密回复,
//! 一次性收敛成纯函数/结构体;不含任何 HTTP 服务器或 socket。
//!
//! 调用方(HTTP 层)协议:把 query 参数与 raw body 填进 `Request`,调
//! `Callback.handle(req)`;返回 `!?[]u8`:
//!   * `error` —— 缺参 / 验签失败 / 解密失败(调用方按失败处理,不崩溃);
//!   * `null`   —— 「不回复」:调用方应答空串 "" 或 "success"(微信约定的
//!                 不回复行为;返回 null 时**不要**加密、不要构造 XML);
//!   * `[]u8`   —— 直接作为响应体的 XML 字节(明文或已加密),gpa 拥有,用毕 free。
//!
//! 排重:`router.zig` 的 `duplicate_checker` 默认 null(不排重),本结构默认注入
//! 自持的 `InMemoryChecker`(键 = MsgId,或 FromUserName+CreateTime,见
//! `Message.dedupKey`),微信 5s 重发时第二条返回 null。可 `useDedup` 换外部版、
//! `disableDedup` 关闭。
//!
//! 地址稳定性:`Callback` 自持 `InMemoryChecker`,`router.duplicate_checker` 内的
//! 指针指向它;故 `Callback` 必须放在**地址稳定的栈帧/堆**上(与项目里
//! `std.Io.Threaded` 的要求同理),init 后不要按值搬运。`WxCrypt` 由调用方持有并
//! 保持地址稳定(它内部也持有 io)。
const std = @import("std");
const testing = std.testing;

const consts = @import("common").consts;
const duplicate = @import("common").duplicate;
const sha1 = @import("common").crypt.sha1;
const wx_crypt = @import("common").crypt.wx_crypt;
pub const WxCrypt = wx_crypt.WxCrypt;
const xml = @import("common").xml;

/// 便捷再导出:业务 handler 用 reply.zig 的构造器产出回复,经本模块闭环返回。
pub const reply = @import("reply.zig");
const router = @import("router.zig");
pub const Router = router.Router;

/// GET 服务器地址(URL)验证:`signature == sha1(token, timestamp, nonce)`,
/// 对应 `WxMpService.checkSignature` / `WxCrypt.checkUrlSignature` 的三串口径。
/// 缺参 / 验签失败 / 分配失败一律 false(失败即拒绝,不抛错)。
pub fn verifyUrl(gpa: std.mem.Allocator, token: []const u8, timestamp: ?[]const u8, nonce: ?[]const u8, signature: ?[]const u8) bool {
    const ts = timestamp orelse return false;
    const n = nonce orelse return false;
    const sig = signature orelse return false;
    return sha1.checkSignature(gpa, token, ts, n, sig) catch false;
}

/// 验签通过后取回显串:返回 gpa 拥有的字节(GET 响应体);echostr 缺失/空返回 null。
pub fn echoStr(gpa: std.mem.Allocator, echostr: ?[]const u8) !?[]u8 {
    const e = echostr orelse return null;
    if (e.len == 0) return null;
    return try gpa.dupe(u8, e);
}

/// 一次回调请求的所有入参(query + raw body),由 HTTP 层填充。
pub const Request = struct {
    method: enum { get, post },
    /// 明文/URL 验签三件套(GET 与明文 POST 共用)
    timestamp: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    /// GET 专用:验证通过后原样回显
    echostr: ?[]const u8 = null,
    /// POST 兼容/安全(加密)模式:消息体签名
    msg_signature: ?[]const u8 = null,
    /// "aes" 表示兼容/安全模式;其余值/缺失按明文处理
    encrypt_type: ?[]const u8 = null,
    /// POST 原始 XML 字节(明文报文,或含 <Encrypt> 的加密报文)
    body: []const u8 = "",
};

pub const Callback = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// init 内 dupe,gpa 拥有
    token: []u8,
    /// 兼容/安全模式用;调用方持有并保持地址稳定;明文模式可传 null
    crypt: ?*WxCrypt,
    /// 业务路由器(由调用方持有,handle 会默认给它挂排重器)
    router: *Router,
    /// 默认排重器(自持;地址随 Callback 稳定)
    in_memory_checker: duplicate.InMemoryChecker,
    /// 外部注入的排重器(如 Redis 版),覆盖默认内存版
    dedup_override: ?duplicate.Checker = null,
    /// 是否默认注入排重器(默认 true,补齐 router 默认 null 的空缺)
    enable_dedup: bool = true,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, token: []const u8, rt: *Router, crypt: ?*WxCrypt) !Callback {
        return .{
            .gpa = gpa,
            .io = io,
            .token = try gpa.dupe(u8, token),
            .crypt = crypt,
            .router = rt,
            .in_memory_checker = duplicate.InMemoryChecker.init(gpa),
        };
    }

    pub fn deinit(self: *Callback) void {
        // router 的 checker 若指向我们自持的 InMemoryChecker,先清空避免悬垂。
        const self_ptr: *anyopaque = @ptrCast(&self.in_memory_checker);
        if (self.router.duplicate_checker) |c| {
            if (c.ptr == self_ptr) self.router.duplicate_checker = null;
        }
        self.in_memory_checker.deinit();
        self.gpa.free(self.token);
        self.* = undefined;
    }

    /// 注入自定义排重器(覆盖默认内存版),立即挂到 router。
    pub fn useDedup(self: *Callback, c: duplicate.Checker) void {
        self.dedup_override = c;
        self.router.duplicate_checker = c;
    }

    /// 关闭默认排重(回到 router 的 null = 不排重)。
    pub fn disableDedup(self: *Callback) void {
        self.enable_dedup = false;
        self.router.duplicate_checker = null;
    }

    /// 统一入口:GET -> 地址验证回显;POST -> 明文/加密闭环。
    /// 见模块头:`null` = 不回复(应答空串/success),`error` = 校验/解密失败。
    pub fn handle(self: *Callback, req: Request) !?[]u8 {
        return switch (req.method) {
            .get => try self.handleGet(req),
            .post => try self.handlePost(req),
        };
    }

    /// GET:验签通过回显 echostr;否则 error.InvalidSignature(不崩溃)。
    pub fn handleGet(self: *Callback, req: Request) !?[]u8 {
        if (!verifyUrl(self.gpa, self.token, req.timestamp, req.nonce, req.signature)) {
            return error.InvalidSignature;
        }
        return try echoStr(self.gpa, req.echostr);
    }

    /// POST:默认先注入排重器,再按 encrypt_type 分照明文/加密。
    pub fn handlePost(self: *Callback, req: Request) !?[]u8 {
        self.installDedup();
        if (isAes(req.encrypt_type)) {
            return self.handleEncrypted(req);
        }
        return self.handlePlain(req);
    }

    /// 明文模式:验 `signature` -> `Router.routeXml`(handler 用 reply.zig 构造回复)
    /// -> 直接返回明文 XML;null = 不回复 / 排重命中。
    fn handlePlain(self: *Callback, req: Request) !?[]u8 {
        if (!verifyUrl(self.gpa, self.token, req.timestamp, req.nonce, req.signature)) {
            return error.InvalidSignature;
        }
        var cx = router.Context.init(self.gpa);
        defer cx.deinit();
        return try self.router.routeXml(self.io, req.body, &cx);
    }

    /// 兼容/安全(aes)模式:
    /// `decryptXml`(内含 msg_signature 校验 + 解密) -> `routeXml` ->
    /// `encryptMessage` -> `EncryptContext.toXml` -> 返回加密 XML 字节。
    fn handleEncrypted(self: *Callback, req: Request) !?[]u8 {
        const crypt = self.crypt orelse return error.MissingCrypt;
        const msg_sig = req.msg_signature orelse return error.MissingSignature;
        const ts = req.timestamp orelse return error.InvalidSignature;
        const nonce = req.nonce orelse return error.InvalidSignature;

        // decryptXml 用 sha1(token,ts,nonce,Encrypt) 校验 msg_signature 后再解密;
        // 签名不符抛 WxCrypt.Error.SignatureMismatch,appid 不符抛 AppidMismatch。
        const plain_xml = try crypt.decryptXml(msg_sig, ts, nonce, req.body);
        defer self.gpa.free(plain_xml);

        var cx = router.Context.init(self.gpa);
        defer cx.deinit();
        const routed = try self.router.routeXml(self.io, plain_xml, &cx);
        const r = routed orelse return null; // 不回复 -> 空串(不构造加密包)
        defer self.gpa.free(r);

        var ectx = try crypt.encryptMessage(r);
        defer ectx.deinit(self.gpa);
        return try ectx.toXml(self.gpa);
    }

    fn installDedup(self: *Callback) void {
        if (!self.enable_dedup) return;
        if (self.router.duplicate_checker != null) return; // 尊重调用方已注入的
        self.router.duplicate_checker = self.dedup_override orelse self.in_memory_checker.checker();
    }
};

fn isAes(encrypt_type: ?[]const u8) bool {
    const e = encrypt_type orelse return false;
    return std.mem.eql(u8, e, "aes");
}

// ---- 测试 ------------------------------------------------------------------

/// 文本回显 handler:被动回复须交换 To/From;用 reply.zig 构造器,固定 CreateTime。
const EchoHandler = struct {
    fn handle(ctx: *anyopaque, msg: *router.Message, cx: *router.Context) router.Error!?[]u8 {
        _ = ctx;
        const content = msg.content() orelse return null;
        return try reply.text(cx.gpa, msg.fromUser() orelse "", msg.toUser() orelse "", 1700000000, content);
    }
    const vtable = router.Handler.VTable{ .handle = handle };
};

/// 无条件回复(用于事件消息排重观察)。
const AlwaysHandler = struct {
    fn handle(ctx: *anyopaque, msg: *router.Message, cx: *router.Context) router.Error!?[]u8 {
        _ = ctx;
        _ = msg;
        return try reply.text(cx.gpa, "to", "from", 1, "ok");
    }
    const vtable = router.Handler.VTable{ .handle = handle };
};

/// 显式返回 null 的 handler(用于「不回复」路径)。
const NullHandler = struct {
    fn handle(ctx: *anyopaque, msg: *router.Message, cx: *router.Context) router.Error!?[]u8 {
        _ = ctx;
        _ = msg;
        _ = cx;
        return null;
    }
    const vtable = router.Handler.VTable{ .handle = handle };
};

/// 永不判重的自定义排重器(验证 useDedup 注入生效)。
const NeverDup = struct {
    fn isdup(ctx: *anyopaque, io: std.Io, id: []const u8) bool {
        _ = ctx;
        _ = io;
        _ = id;
        return false;
    }
    const vtable = duplicate.Checker.VTable{ .is_duplicate = isdup };
};

const k_aes_key = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFE";
const k_token = "pamtest";
const k_appid = "wxb11529c136998cb6";

fn textBody(msg_id: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "<xml><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[{s}]]></Content>" ++
            "<FromUserName><![CDATA[oU1]]></FromUserName><ToUserName><![CDATA[gh1]]></ToUserName>" ++
            "<MsgId>{s}</MsgId><CreateTime>1409304348</CreateTime></xml>",
        .{ content, msg_id },
    );
}

test "callback: GET 服务器地址验证 success/failure + echostr" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var rt = Router.init(gpa);
    defer rt.deinit();
    var cb = try Callback.init(gpa, threaded.io(), k_token, &rt, null);
    defer cb.deinit();

    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx" });
    defer gpa.free(sig);

    // verifyUrl 直接可用
    try testing.expect(verifyUrl(gpa, k_token, "1409304348", "xxxxxx", sig));
    try testing.expect(!verifyUrl(gpa, k_token, "1409304348", "xxxxxx", "deadbeef"));
    try testing.expect(!verifyUrl(gpa, k_token, null, "xxxxxx", sig)); // 缺参

    // 成功:回显 echostr
    const ok = try cb.handle(.{ .method = .get, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .echostr = "ECHO123" });
    try testing.expect(ok != null);
    defer if (ok) |b| gpa.free(b);
    try testing.expectEqualStrings("ECHO123", ok.?);

    // 失败:错误签名 / 缺签名 -> error.InvalidSignature(不崩溃)
    try testing.expectError(error.InvalidSignature, cb.handle(.{
        .method = .get,
        .signature = "bad",
        .timestamp = "1409304348",
        .nonce = "xxxxxx",
        .echostr = "ECHO123",
    }));
    try testing.expectError(error.InvalidSignature, cb.handle(.{ .method = .get, .echostr = "ECHO123" }));

    // echoStr:缺失/空 -> null
    const e1 = try echoStr(gpa, null);
    try testing.expect(e1 == null);
    const e2 = try echoStr(gpa, "");
    try testing.expect(e2 == null);
}

test "callback: 明文 POST 闭环(验签 -> routeXml -> reply.text)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var rt = Router.init(gpa);
    defer rt.deinit();
    try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &EchoHandler.vtable });
    var cb = try Callback.init(gpa, threaded.io(), k_token, &rt, null);
    defer cb.deinit();

    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx" });
    defer gpa.free(sig);
    const body = try textBody("1001", "hi");
    defer gpa.free(body);

    const out = try cb.handle(.{ .method = .post, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .body = body });
    try testing.expect(out != null);
    defer if (out) |b| gpa.free(b);
    const s = out.?;
    try testing.expect(std.mem.indexOf(u8, s, "<ToUserName><![CDATA[oU1]]></ToUserName>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<FromUserName><![CDATA[gh1]]></FromUserName>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[text]]></MsgType>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Content><![CDATA[hi]]></Content>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<CreateTime>1700000000</CreateTime>") != null); // 固定时间戳

    // 明文模式错签名 -> error.InvalidSignature
    try testing.expectError(error.InvalidSignature, cb.handle(.{
        .method = .post,
        .signature = "bad",
        .timestamp = "1409304348",
        .nonce = "xxxxxx",
        .body = body,
    }));
}

test "callback: 加密(aes) POST 闭环(验签+解密 -> routeXml -> 加密回复)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var crypt = try WxCrypt.init(gpa, io, k_token, k_aes_key, k_appid);
    defer crypt.deinit();

    var rt = Router.init(gpa);
    defer rt.deinit();
    try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &EchoHandler.vtable });
    var cb = try Callback.init(gpa, io, k_token, &rt, &crypt);
    defer cb.deinit();

    const ts = "1409304348";
    const nonce = "xxxxxx";
    const inbound =
        \\<xml><ToUserName><![CDATA[gh1]]></ToUserName><FromUserName><![CDATA[oU1]]></FromUserName>
        \\<CreateTime>1409304348</CreateTime><MsgType><![CDATA[text]]></MsgType>
        \\<Content><![CDATA[hi-secret]]></Content><MsgId>3001</MsgId></xml>
    ;
    const cipher = try crypt.encrypt("aaaabbbbccccdddd", inbound);
    defer gpa.free(cipher);
    const msg_sig = try sha1.gen(gpa, &.{ k_token, ts, nonce, cipher });
    defer gpa.free(msg_sig);
    const body = try std.fmt.allocPrint(gpa, "<xml><ToUserName><![CDATA[gh1]]></ToUserName><Encrypt><![CDATA[{s}]]></Encrypt></xml>", .{cipher});
    defer gpa.free(body);

    const out = try cb.handle(.{
        .method = .post,
        .encrypt_type = "aes",
        .msg_signature = msg_sig,
        .timestamp = ts,
        .nonce = nonce,
        .body = body,
    });
    try testing.expect(out != null);
    defer if (out) |b| gpa.free(b);
    const s = out.?;
    // 出站为加密包(EncryptContext.toXml 形状)
    try testing.expect(std.mem.indexOf(u8, s, "<Encrypt><![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<MsgSignature><![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<TimeStamp>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Nonce><![CDATA[") != null);

    // extractTag 返回借用 s 的切片,不要 free。
    const out_cipher = xml.extractTag(gpa, s, "Encrypt") orelse return error.MissingEncryptTag;
    const out_sig = xml.extractTag(gpa, s, "MsgSignature") orelse return error.MissingSigTag;
    const out_ts = xml.extractTag(gpa, s, "TimeStamp") orelse return error.MissingTsTag;
    const out_nonce = xml.extractTag(gpa, s, "Nonce") orelse return error.MissingNonceTag;

    // 校验 MsgSignature = sha1(token, ts, nonce, encrypt)
    const expect_sig = try sha1.gen(gpa, &.{ k_token, out_ts, out_nonce, out_cipher });
    defer gpa.free(expect_sig);
    try testing.expectEqualStrings(expect_sig, out_sig);

    // 解出明文回复,验证内容与交换后的收发方
    const plain_reply = try crypt.decrypt(out_cipher);
    defer gpa.free(plain_reply);
    try testing.expect(std.mem.indexOf(u8, plain_reply, "<Content><![CDATA[hi-secret]]></Content>") != null);
    try testing.expect(std.mem.indexOf(u8, plain_reply, "<ToUserName><![CDATA[oU1]]></ToUserName>") != null);
    try testing.expect(std.mem.indexOf(u8, plain_reply, "<FromUserName><![CDATA[gh1]]></FromUserName>") != null);
    try testing.expect(std.mem.indexOf(u8, plain_reply, "<MsgType><![CDATA[text]]></MsgType>") != null);

    // 缺 msg_signature -> error.MissingSignature
    try testing.expectError(error.MissingSignature, cb.handle(.{
        .method = .post,
        .encrypt_type = "aes",
        .timestamp = ts,
        .nonce = nonce,
        .body = body,
    }));
    // 错 msg_signature -> decryptXml 内部抛 SignatureMismatch
    try testing.expectError(error.SignatureMismatch, cb.handle(.{
        .method = .post,
        .encrypt_type = "aes",
        .msg_signature = "deadbeef",
        .timestamp = ts,
        .nonce = nonce,
        .body = body,
    }));
    // 声明 aes 但未配 crypt -> error.MissingCrypt
    var rt2 = Router.init(gpa);
    defer rt2.deinit();
    var cb2 = try Callback.init(gpa, io, k_token, &rt2, null);
    defer cb2.deinit();
    try testing.expectError(error.MissingCrypt, cb2.handle(.{
        .method = .post,
        .encrypt_type = "aes",
        .msg_signature = msg_sig,
        .timestamp = ts,
        .nonce = nonce,
        .body = body,
    }));
}

test "callback: 默认排重丢弃重复消息(MsgId / FromUserName+CreateTime)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx" });
    defer gpa.free(sig);

    // 普通消息:按 MsgId 排重
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &EchoHandler.vtable });
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        const body = try textBody("2001", "hi");
        defer gpa.free(body);
        const req = Request{ .method = .post, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .body = body };

        const out1 = try cb.handle(req);
        try testing.expect(out1 != null);
        defer if (out1) |b| gpa.free(b);
        const out2 = try cb.handle(req); // 微信 5s 重发,同一 MsgId
        try testing.expect(out2 == null); // 默认排重命中 -> 不回复
    }

    // 事件消息(无 MsgId):按 FromUserName+CreateTime 排重
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        try rt.rule(.{}, .{ .ptr = undefined, .vtable = &AlwaysHandler.vtable }); // 无条件回复
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        const ev =
            \\<xml><MsgType><![CDATA[event]]></MsgType><Event><![CDATA[CLICK]]></Event>
            \\<FromUserName><![CDATA[oEV]]></FromUserName><ToUserName><![CDATA[gh1]]></ToUserName>
            \\<CreateTime>1409304348</CreateTime></xml>
        ;
        const req = Request{ .method = .post, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .body = ev };
        const out1 = try cb.handle(req);
        try testing.expect(out1 != null);
        defer if (out1) |b| gpa.free(b);
        const out2 = try cb.handle(req);
        try testing.expect(out2 == null); // FromUserName+CreateTime 命中
    }
}

test "callback: disableDedup / useDedup 切换排重策略" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx" });
    defer gpa.free(sig);
    const body = try textBody("5001", "hi");
    defer gpa.free(body);
    const req = Request{ .method = .post, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .body = body };

    // 关闭默认排重 -> 重复消息仍回复
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &EchoHandler.vtable });
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        cb.disableDedup();
        const a = try cb.handle(req);
        try testing.expect(a != null);
        defer if (a) |b| gpa.free(b);
        const b = try cb.handle(req);
        try testing.expect(b != null);
        if (b) |x| gpa.free(x);
    }

    // 注入外部「永不判重」checker -> 重复消息仍回复
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &EchoHandler.vtable });
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        cb.useDedup(.{ .ptr = undefined, .vtable = &NeverDup.vtable });
        const a = try cb.handle(req);
        try testing.expect(a != null);
        defer if (a) |b| gpa.free(b);
        const b = try cb.handle(req);
        try testing.expect(b != null);
        if (b) |x| gpa.free(x);
    }
}

test "callback: 无回复返回 null(调用方应答空串/success)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx" });
    defer gpa.free(sig);
    const body = try textBody("4001", "hi");
    defer gpa.free(body);
    const req = Request{ .method = .post, .signature = sig, .timestamp = "1409304348", .nonce = "xxxxxx", .body = body };

    // (a) 空路由:无匹配 handler -> null
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        const out = try cb.handle(req);
        try testing.expect(out == null);
    }
    // (b) handler 显式返回 null -> null
    {
        var rt = Router.init(gpa);
        defer rt.deinit();
        try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &NullHandler.vtable });
        var cb = try Callback.init(gpa, io, k_token, &rt, null);
        defer cb.deinit();
        const out = try cb.handle(req);
        try testing.expect(out == null);
    }
}
