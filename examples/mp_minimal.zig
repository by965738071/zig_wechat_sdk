//! 公众号（wechat_mp）端到端「接线」最小示例 —— 可离线编译、可 `zig test` 跑通。
//!
//! 目标：给要搭「公众号系统」的同学一份能直接抄的拼装参考，覆盖
//!   1) 初始化（凭证 / 执行器 / 配置回填 / Service / 子服务）
//!   2) 一次离线 API 调用（.ok / .err 两分支 + 正确释放）
//!   3) 微信服务器回调接线（GET 验证 / POST 明文 / POST 加密 / null / error）
//!   4) 内存与生命周期（defer / 地址稳定 / 排重 / deinit）
//!
//! 重要：本 SDK **不含 HTTP 服务器层**。回调部分是「纯 glue」：
//!   由你自己的 HTTP server 把 query 参数与 raw body 填进 `callback.Request`，
//!   调 `Callback.handle(req)`，再把返回的字节写回 HTTP 响应。本示例用伪造的
//!   query/body 演示这段 glue，不监听端口、不发起真实网络请求、不用真实凭证。
//!
//! 编译验证（模块名见 build.zig / src/root.zig；--dep 须在消费模块的 -M 之前）：
//!   zig test \
//!     --dep common --dep wechat_mp -Mroot=examples/mp_minimal.zig \
//!     --dep common -Mwechat_mp=src/wechat_mp/root.zig \
//!     -Mcommon=src/common/root.zig
//! 后续接入 build.zig 时把 examples/mp_minimal.zig 作为 test/exe 入口挂上即可
//! （本任务不改 build.zig）。

const std = @import("std");

const common = @import("common");
const consts = common.consts;
const sha1 = common.crypt.sha1;
const token_mod = common.token;
const error_util = common.error_util;
const sdk = @import("wechat_mp");
const cfg_mod = sdk.config;
const http_mod = sdk.http;
const svc_mod = sdk.service;
const mp_mod = sdk.mp;
const services_a = sdk.services_a;
const router = sdk.router;
const reply = sdk.reply;
const callback = sdk.callback;

// ---------------------------------------------------------------------------
// 占位凭证（全部为假值）。生产请改成真实凭证，并用 credentials.Source.file /
// .env 从文件或环境变量注入，切勿硬编码（见 credentials.zig 的 Source）。
// AES_KEY 必须是 43 位 EncodingAESKey（WxCrypt.init 会校验，见 wx_crypt.zig:41）。
// ---------------------------------------------------------------------------
const APPID = "wxPLACEHOLDER_APPID"; // TODO(生产): 真实 AppID
const SECRET = "PLACEHOLDER_APP_SECRET"; // TODO(生产): 真实 AppSecret
const TOKEN = "PLACEHOLDER_CALLBACK_TOKEN"; // TODO(生产): 真实回调校验 Token
// 43 位；末位取 base64 规范位（末 2 bit 为 0）以通过 std.base64 严格解码，
// 与 callback.zig / wx_crypt.zig 的测试向量一致。TODO(生产): 真实 43 位 EncodingAESKey。
const AES_KEY = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFE";

// ConfigStorage 与 Fetcher 相互引用：initWithCredentials 需要先拿到一个 Fetcher
// 才能构造，真实刷新通道随后回填（"先占坑再回填"，见 mp.zig:49-56 / http.zig:724-741）。
// 这个占位 Fetcher 一旦被调用就报错，保证回填前不会悄悄发请求。
const placeholder_fetcher = token_mod.Fetcher{
    .ptr = undefined,
    .vtable = &.{ .fetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = error_util.WxError.transport(g, "fetcher not wired (placeholder)", .{}) };
        }
    }.f },
};

/// 一个业务 handler：用 reply.text / reply.news 构造被动回复。
/// 被动回复必须「交换收发方」：ToUserName = 原 FromUserName，FromUserName = 原 ToUserName。
/// 返回 gpa 拥有的 []u8；null 表示不回复（见 router.zig:146-159）。
const DemoHandler = struct {
    fn handle(ctx: *anyopaque, msg: *router.Message, cx: *router.Context) router.Error!?[]u8 {
        _ = ctx;
        const content = msg.content() orelse return null;
        const to_user = msg.fromUser() orelse "";
        const from_user = msg.toUser() orelse "";
        const create_time = if (cx.io) |i| reply.nowSeconds(i) else 0; // 真实时钟；离线固定 0 亦可
        if (std.mem.eql(u8, content, "news")) {
            // 图文回复：reply.news
            return try reply.news(cx.gpa, to_user, from_user, create_time, &.{
                .{ .title = "动手搭公众号", .description = "zig_wechat_sdk 端到端示例", .url = "https://example.com" },
            });
        }
        // 文本回复：reply.text（回显用户消息）
        return try reply.text(cx.gpa, to_user, from_user, create_time, content);
    }
    const vtable = router.Handler.VTable{ .handle = handle };
};

/// 伪造一条微信下发的文本消息 XML（query/body 由你的 HTTP server 提供）。
fn textPostBody(gpa: std.mem.Allocator, msg_id: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "<xml><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[{s}]]></Content>" ++
            "<FromUserName><![CDATA[oUser]]></FromUserName><ToUserName><![CDATA[gh_mp]]></ToUserName>" ++
            "<MsgId>{s}</MsgId><CreateTime>1700000000</CreateTime></xml>",
        .{ content, msg_id },
    );
}

/// 命令行占位：本文件是「接线参考」，全部逻辑在下面的 test 块里（zig test 会执行）。
/// 真实系统请把伪造的 query/body 换成你的 HTTP server 实际收到的内容。
pub fn main() void {}

// 公众号端到端接线：初始化 / 离线调用 / 微信回调（GET + POST 明文/加密）/ 生命周期。
test "example: mp end-to-end wiring (init / offline call / callback)" {
    // 生产换 GeneralPurposeAllocator / arena；这里用 testing.allocator 以便自动检测内存泄漏。
    const gpa = std.testing.allocator;

    // ① std.Io.Threaded 必须放在稳定栈帧，且活得最久：SDK 曾有「按值搬运 Threaded
    //    导致 io.userdata 悬垂」的真实缺陷（见 wx_crypt.zig:203-205）。第一个声明，
    //    其 defer 最后执行，确保所有用到 io 的对象先于它释放。
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ===================== 1. 初始化 =====================
    // 离线传输桩：按 uri 子串返回预置响应，让整条链路不发真实网络请求。
    var stub = http_mod.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "{\"access_token\":\"AT1\",\"expires_in\":7200}" },
        .{ .match = "cgi-bin/user/info", .response = "{\"openid\":\"oX\",\"subscribe\":1}" },
        .{ .match = "getcallbackip", .response = "{\"ip_list\":[\"1.2.3.4\"]}" },
    });

    // 真实 std.http 执行器（生产接线用）。TODO(生产): 把下面所有 stub.executor()
    // 换成 http_exec.executor() 即接真实网络；离线示例不通过它发请求。
    var http_exec = http_mod.HttpExecutor.init(gpa, io);

    // 配置：initWithCredentials(占位 Fetcher) → 再回填真实 AccessTokenFetcher /
    // JsapiTicketFetcher 到 cfg.fetcher / cfg.ticket_fetcher（见 config.zig:93/99）。
    var cfg = try cfg_mod.InMemoryConfigStorage.initWithCredentials(gpa, placeholder_fetcher, io, .{
        .appid = .{ .text = APPID }, // credentials.Source.text（生产改 .file/.env）
        .secret = .{ .text = SECRET },
        .token = TOKEN,
        .aes_key = AES_KEY,
    });
    defer cfg.deinit();

    // 回填 access_token 刷新通道：用「真实 AccessTokenFetcher」但走 stub 传输（离线）。
    var at_fetch = http_mod.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = stub.executor(), // TODO(生产): 改 http_exec.executor()
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = at_fetch.fetcher();

    // 回填 jsapi_ticket 刷新通道（真实 JsapiTicketFetcher；本例不触发网络调用）。
    var js_fetch = http_mod.JsapiTicketFetcher{
        .cfg = cfg.config(),
        .exec = stub.executor(),
        .ticket_url = "https://api.weixin.qq.com/cgi-bin/ticket/getticket?type=jsapi",
    };
    cfg.ticket_fetcher = js_fetch.fetcher();

    // 生产接线：Service.initWithRealHttp 注入真实 std.http 执行器。
    // TODO(生产): 这条 Service 才会发真实网络请求，需真凭证；离线仅编译验证接线形状。
    const prod_svc = svc_mod.Service.initWithRealHttp(gpa, cfg.config(), &http_exec);
    try std.testing.expect(prod_svc.executor.vtable.execute_ex != null); // 真实执行器可回传响应头

    // 门面 MpService（本例实际发调用用它，走 Stub 离线链路）。
    // 子服务持 &self.base 反向引用 → 初始化后不得移动本结构（见 mp.zig:13-32）。
    var mp_svc: mp_mod.MpService = undefined;
    mp_svc.init(gpa, cfg.config(), stub.executor());

    // 组合若干子服务：XxxService{ .svc = &svc }（见 user.zig:161 / menu.zig:192）。
    // mp_svc.user_service 本身就是同款 UserService{ .svc = &mp_svc.base }，下面直接用它。
    var menus = services_a.menu.MenuService{ .svc = &mp_svc.base };
    _ = &menus; // 仅演示组合；本例不触发它的网络方法

    // ===================== 2. 一次离线 API 调用（StubExecutor）=====================
    // (a) 结构化结果 WxResult(User)：.ok → 结构体 deinit()；.err → WxError.deinit()。
    switch (mp_svc.user_service.userInfo(io, "oX", null)) {
        .ok => |*u| {
            var usr = u.*;
            defer usr.deinit(); // 结构化结果：用毕 deinit（见 user.zig:34）
            try std.testing.expectEqualStrings("oX", usr.openid);
        },
        .err => |e| {
            var err = e;
            defer err.deinit(); // .err 分支：WxError 拥有 error_msg/raw，必须 deinit
        },
    }
    // (b) 原始 body 结果 WxResult([]u8)：.ok → gpa.free(body)；.err → WxError.deinit()。
    switch (mp_svc.base.get(io, "https://api.weixin.qq.com/cgi-bin/getcallbackip", &.{})) {
        .ok => |body| {
            defer gpa.free(body); // gpa 拥有的响应体：用毕 free（见 result.zig / service.zig）
            try std.testing.expect(std.mem.indexOf(u8, body, "ip_list") != null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
        },
    }

    // ============ 3. 微信服务器回调接线（纯 glue，无 HTTP server）============
    // 你的 HTTP server 协议（见 callback.zig:1-20）：
    //   收到 GET/POST /callback 后，把 query 参数与 raw body 填进 callback.Request，
    //   调 Callback.handle(req) 得 !?[]u8，然后：
    //     · []u8  → 直接作为 XML 响应体（明文或已加密），gpa 拥有、用毕 free；
    //     · null  → 不回复：应答空串 "" 或 "success"，不要构造/加密 XML；
    //     · error → 验签/解密失败：按失败处理（如 4xx），不崩溃。
    // 地址稳定：WxCrypt(内部持有 io)、Router、Callback(自持排重器) 都不得按值搬运。
    var crypt = try callback.WxCrypt.init(gpa, io, TOKEN, AES_KEY, APPID);
    defer crypt.deinit();
    var rt = router.Router.init(gpa);
    defer rt.deinit();
    // 注册至少一个 handler；规则按注册顺序匹配，最后一个非空回复生效。
    try rt.rule(.{ .msg_type = consts.XmlMsgType.text }, .{ .ptr = undefined, .vtable = &DemoHandler.vtable });
    var cb = try callback.Callback.init(gpa, io, TOKEN, &rt, &crypt);
    defer cb.deinit(); // 会清空 router 里指向自身排重器的指针，避免悬垂（见 callback.zig:97-106）
    // 默认启用内存排重（微信 5s 重发第二条返回 null）；可用 useDedup 换外部版、
    // disableDedup 关闭（见 callback.zig:109-118）。

    const ts = "1700000000";
    const nonce = "nonce_demo";
    const sig = try sha1.gen(gpa, &.{ TOKEN, ts, nonce }); // GET 与明文 POST 共用三件套签名
    defer gpa.free(sig);

    // --- GET：服务器地址验证（verifyUrl → 回显 echostr）---
    // 你的 server 收到 GET /callback?signature=..&timestamp=..&nonce=..&echostr=.. 后：
    const url_ok = callback.verifyUrl(gpa, TOKEN, ts, nonce, sig);
    try std.testing.expect(url_ok); // 验签失败即拒绝，不回显
    const echo = try callback.echoStr(gpa, "ECHO_FROM_WECHAT");
    defer if (echo) |b| gpa.free(b);
    try std.testing.expectEqualStrings("ECHO_FROM_WECHAT", echo.?); // 写回 HTTP 响应体
    // 或走 Callback 一站式入口 handle(.get)（内部即 verifyUrl + echoStr）：
    const get_out = try cb.handle(.{
        .method = .get,
        .timestamp = ts,
        .nonce = nonce,
        .signature = sig,
        .echostr = "ECHO_FROM_WECHAT",
    });
    defer if (get_out) |b| gpa.free(b);
    try std.testing.expectEqualStrings("ECHO_FROM_WECHAT", get_out.?);

    // --- POST：明文模式（signature 三件套）---
    const body_text = try textPostBody(gpa, "1001", "hi");
    defer gpa.free(body_text);
    const out_text = try cb.handle(.{
        .method = .post,
        .timestamp = ts,
        .nonce = nonce,
        .signature = sig,
        .body = body_text,
    });
    try std.testing.expect(out_text != null); // []u8 = 回复 XML
    defer if (out_text) |b| gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, out_text.?, "<![CDATA[hi]]>") != null); // reply.text 回显

    // 再来一条走 reply.news 分支（图文回复；不同 MsgId 不会被排重）：
    const body_news = try textPostBody(gpa, "1002", "news");
    defer gpa.free(body_news);
    const out_news = try cb.handle(.{
        .method = .post,
        .timestamp = ts,
        .nonce = nonce,
        .signature = sig,
        .body = body_news,
    });
    try std.testing.expect(out_news != null);
    defer if (out_news) |b| gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, out_news.?, "<![CDATA[news]]></MsgType>") != null);

    // --- POST：兼容/安全(加密)模式（encrypt_type=aes + msg_signature + <Encrypt> body）---
    // 真实回调由微信加密下发；这里用同一把 WxCrypt 造一条密文来演示入站形状。
    const enc_inbound = try textPostBody(gpa, "2001", "secret");
    defer gpa.free(enc_inbound);
    const cipher = try crypt.encrypt("aaaabbbbccccdddd", enc_inbound); // 16 字节随机串
    defer gpa.free(cipher);
    const msg_sig = try sha1.gen(gpa, &.{ TOKEN, ts, nonce, cipher });
    defer gpa.free(msg_sig);
    const enc_body = try std.fmt.allocPrint(gpa, "<xml><ToUserName><![CDATA[gh_mp]]></ToUserName><Encrypt><![CDATA[{s}]]></Encrypt></xml>", .{cipher});
    defer gpa.free(enc_body);
    const enc_out = try cb.handle(.{
        .method = .post,
        .encrypt_type = "aes",
        .msg_signature = msg_sig,
        .timestamp = ts,
        .nonce = nonce,
        .body = enc_body,
    });
    try std.testing.expect(enc_out != null); // 已是「验签+解密 → 路由 → 加密回复」后的 XML
    defer if (enc_out) |b| gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, enc_out.?, "<Encrypt><![CDATA[") != null);

    // --- null：不回复（同一 MsgId 重发，被默认排重命中）---
    const dup_out = try cb.handle(.{
        .method = .post,
        .timestamp = ts,
        .nonce = nonce,
        .signature = sig,
        .body = body_text,
    });
    try std.testing.expect(dup_out == null); // server 应答 "" / "success"

    // --- error：校验失败 → 拒绝（不崩溃）---
    try std.testing.expectError(error.InvalidSignature, cb.handle(.{
        .method = .post,
        .timestamp = ts,
        .nonce = nonce,
        .signature = "bad",
        .body = body_text,
    }));
}
