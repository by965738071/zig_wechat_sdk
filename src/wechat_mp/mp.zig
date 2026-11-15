//! 公众号服务门面 —— 对应 Java `api.impl.WxMpServiceImpl`
//! (extends BaseWxMpServiceImpl,构造时 eager 创建全部子服务)。
//!
//! Zig 侧用「原地初始化」表达同一组合:子服务持有 `&self.base` 反向引用,
//! 因此 MpService 初始化后**不得再移动**(需要堆上持有就 `create` 后再 init)。
const std = @import("std");
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const service = @import("service.zig");
pub const router = @import("router.zig");
// 35 个子服务(对应 Java WxMpServiceImpl 的子服务字段,eager 创建;
// oauth 拆分、kf_session、jssdk 等为合理拆分后的 Zig 侧命名)
pub const user = @import("services/user.zig");
pub const menu = @import("services/menu.zig");
pub const user_tag = @import("services/user_tag.zig");
pub const qrcode = @import("services/qrcode.zig");
pub const oauth = @import("services/oauth.zig");
pub const jssdk = @import("services/jssdk.zig");
pub const kf_session = @import("services/kf_session.zig");
pub const subscribe_msg = @import("services/subscribe_msg.zig");
pub const comment = @import("services/comment.zig");
pub const user_blacklist = @import("services/user_blacklist.zig");
pub const guide = @import("services/guide.zig");
pub const guide_buyer = @import("services/guide_buyer.zig");
pub const guide_tag = @import("services/guide_tag.zig");
pub const guide_massed_job = @import("services/guide_massed_job.zig");
pub const invoice = @import("services/invoice.zig");
pub const reimburse = @import("services/reimburse.zig");
pub const template_msg = @import("services/template_msg.zig");
pub const kefu = @import("services/kefu.zig");
pub const material = @import("services/material.zig");
pub const mass = @import("services/mass.zig");
pub const datacube = @import("services/datacube.zig");
pub const media = @import("services/media.zig");
pub const draft = @import("services/draft.zig");
pub const free_publish = @import("services/free_publish.zig");
pub const card = @import("services/card.zig");
pub const ai_open = @import("services/ai_open.zig");
pub const device = @import("services/device.zig");
pub const guide_material = @import("services/guide_material.zig");
pub const marketing = @import("services/marketing.zig");
pub const shake = @import("services/shake.zig");
pub const member_card = @import("services/member_card.zig");
pub const store = @import("services/store.zig");
pub const wifi = @import("services/wifi.zig");
pub const ocr = @import("services/ocr.zig");
pub const imgproc = @import("services/imgproc.zig");

pub const MpService = struct {
    base: service.Service,
    /// 子服务(对应 Java WxMpServiceImpl 的同名字段,持 `&base` 反向引用)
    user_service: user.UserService,
    menu_service: menu.MenuService,
    user_tag_service: user_tag.UserTagService,
    qrcode_service: qrcode.QrcodeService,
    oauth_service: oauth.OauthService,
    jssdk_service: jssdk.JssdkService,
    kf_session_service: kf_session.KfSessionService,
    subscribe_msg_service: subscribe_msg.SubscribeMsgService,
    comment_service: comment.CommentService,
    user_blacklist_service: user_blacklist.UserBlacklistService,
    guide_service: guide.GuideService,
    guide_buyer_service: guide_buyer.GuideBuyerService,
    guide_tag_service: guide_tag.GuideTagService,
    guide_massed_job_service: guide_massed_job.GuideMassedJobService,
    invoice_service: invoice.InvoiceService,
    reimburse_service: reimburse.ReimburseService,
    template_msg_service: template_msg.TemplateMsgService,
    kefu_service: kefu.KefuService,
    material_service: material.MaterialService,
    mass_service: mass.MassService,
    data_cube_service: datacube.DataCubeService,
    media_service: media.MediaService,
    draft_service: draft.DraftService,
    free_publish_service: free_publish.FreePublishService,
    card_service: card.CardService,
    ai_open_service: ai_open.AiOpenService,
    device_service: device.DeviceService,
    guide_material_service: guide_material.GuideMaterialService,
    marketing_service: marketing.MarketingService,
    shake_service: shake.ShakeService,
    member_card_service: member_card.MemberCardService,
    store_service: store.StoreService,
    wifi_service: wifi.WifiService,
    ocr_service: ocr.OcrService,
    imgproc_service: imgproc.ImgProcService,

    /// 对应 `new WxMpServiceImpl()`:注入配置与执行器,原地组合全部 35 个子服务。
    /// 子服务持 `&self.base` 反向引用,初始化后不得移动本结构。
    /// 用法:
    /// ```zig
    /// var mp: MpService = undefined;
    /// mp.init(gpa, cfg.config(), exec.executor());
    /// mp.user_service.userInfo(io, "openid", null);
    /// ```
    pub fn init(self: *MpService, gpa: std.mem.Allocator, cfg: config.ConfigStorage, exec: http.RequestExecutor) void {
        self.* = .{
            .base = service.Service.init(gpa, cfg, exec),
            .user_service = undefined,
            .menu_service = undefined,
            .user_tag_service = undefined,
            .qrcode_service = undefined,
            .oauth_service = undefined,
            .jssdk_service = undefined,
            .kf_session_service = undefined,
            .subscribe_msg_service = undefined,
            .comment_service = undefined,
            .user_blacklist_service = undefined,
            .guide_service = undefined,
            .guide_buyer_service = undefined,
            .guide_tag_service = undefined,
            .guide_massed_job_service = undefined,
            .invoice_service = undefined,
            .reimburse_service = undefined,
            .template_msg_service = undefined,
            .kefu_service = undefined,
            .material_service = undefined,
            .mass_service = undefined,
            .data_cube_service = undefined,
            .media_service = undefined,
            .draft_service = undefined,
            .free_publish_service = undefined,
            .card_service = undefined,
            .ai_open_service = undefined,
            .device_service = undefined,
            .guide_material_service = undefined,
            .marketing_service = undefined,
            .shake_service = undefined,
            .member_card_service = undefined,
            .store_service = undefined,
            .wifi_service = undefined,
            .ocr_service = undefined,
            .imgproc_service = undefined,
        };
        self.user_service = .{ .svc = &self.base };
        self.menu_service = .{ .svc = &self.base };
        self.user_tag_service = .{ .svc = &self.base };
        self.qrcode_service = .{ .svc = &self.base };
        self.oauth_service = .{ .svc = &self.base };
        self.jssdk_service = .{ .svc = &self.base };
        self.kf_session_service = .{ .svc = &self.base };
        self.subscribe_msg_service = .{ .svc = &self.base };
        self.comment_service = .{ .svc = &self.base };
        self.user_blacklist_service = .{ .svc = &self.base };
        self.guide_service = .{ .svc = &self.base };
        self.guide_buyer_service = .{ .svc = &self.base };
        self.guide_tag_service = .{ .svc = &self.base };
        self.guide_massed_job_service = .{ .svc = &self.base };
        self.invoice_service = .{ .svc = &self.base };
        self.reimburse_service = .{ .svc = &self.base };
        self.template_msg_service = .{ .svc = &self.base };
        self.kefu_service = .{ .svc = &self.base };
        self.material_service = .{ .svc = &self.base };
        self.mass_service = .{ .svc = &self.base };
        self.data_cube_service = .{ .svc = &self.base };
        self.media_service = .{ .svc = &self.base };
        self.draft_service = .{ .svc = &self.base };
        self.free_publish_service = .{ .svc = &self.base };
        self.card_service = .{ .svc = &self.base };
        self.ai_open_service = .{ .svc = &self.base };
        self.device_service = .{ .svc = &self.base };
        self.guide_material_service = .{ .svc = &self.base };
        self.marketing_service = .{ .svc = &self.base };
        self.shake_service = .{ .svc = &self.base };
        self.member_card_service = .{ .svc = &self.base };
        self.store_service = .{ .svc = &self.base };
        self.wifi_service = .{ .svc = &self.base };
        self.ocr_service = .{ .svc = &self.base };
        self.imgproc_service = .{ .svc = &self.base };
    }
};

// ---------------------------------------------------------------------------

// 端到端骨架链路:StubExecutor 同时喂 token 与业务接口。
test "mp service full chain (stubbed)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http.StubExecutor.init(gpa, &.{
        .{ .match = "cgi-bin/token", .response = "{\"access_token\":\"AT1\",\"expires_in\":7200}" },
        .{ .match = "cgi-bin/user/info", .response = "{\"openid\":\"oX\",\"subscribe\":1}" },
    });

    var cfg = try config.InMemoryConfigStorage.init(gpa, undefined_fetcher, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tfetch = http.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = stub.executor(),
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = tfetch.fetcher();

    var mp: MpService = undefined;
    mp.init(gpa, cfg.config(), stub.executor());

    const r = mp.user_service.userInfo(io, "oX", null);
    switch (r) {
        .ok => |*u| {
            var usr = u.*;
            defer usr.deinit();
            try std.testing.expectEqualStrings("oX", usr.openid);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("mp err: {s}\n", .{err.error_msg});
            return error.Unexpected;
        },
    }
}

// 结构性验证:init 后全部子服务(32 个 *_service 字段)都指向同一个 base。
test "MpService: all sub-services wired to base" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stub = http.StubExecutor.init(gpa, &.{});
    var cfg = try config.InMemoryConfigStorage.init(gpa, undefined_fetcher, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tfetch = http.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = stub.executor(),
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = tfetch.fetcher();

    var mp: MpService = undefined;
    mp.init(gpa, cfg.config(), stub.executor());
    _ = io;

    var wired: usize = 0;
    const info = @typeInfo(MpService).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime std.mem.endsWith(u8, fname, "_service")) {
            const sub: *ftype = &@field(mp, fname);
            try std.testing.expect(sub.svc == &mp.base);
            wired += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 35), wired);
}

// access_token 错误码 → 自动刷新 → 重试一次(核心协议验证)。
test "token error triggers auto refresh retry" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 可编程 stub:第 1 次 token 返回 AT1;业务第 1 次回 40001,之后成功;
    // token 第 2 次返回 AT2。
    const Scripted = struct {
        token_calls: usize = 0,
        api_calls: usize = 0,

        fn execute(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, method: http.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) service.WxResult([]u8) {
            _ = i;
            _ = method;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, uri, "cgi-bin/token") != null) {
                self.token_calls += 1;
                // 槽里已预置过期 AT1,所以任何一次真实 fetch 都是新 token AT2
                const resp = "{\"access_token\":\"AT2\",\"expires_in\":7200}";
                return .{ .ok = g.dupe(u8, resp) catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
            }
            self.api_calls += 1;
            if (std.mem.indexOf(u8, uri, "AT1") != null) {
                // 旧 token 已失效
                return .{ .ok = g.dupe(u8, "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}") catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
            }
            return .{ .ok = g.dupe(u8, "{\"openid\":\"oZ\"}") catch return .{ .err = @import("common").error_util.WxError.transport(g, "oom", .{}) } };
        }
    };
    var script = Scripted{};
    const exec = http.RequestExecutor{ .ptr = @ptrCast(&script), .vtable = &.{ .execute = Scripted.execute } };

    var cfg = try config.InMemoryConfigStorage.init(gpa, undefined_fetcher, .{ .appid = "A", .secret = "S" });
    defer cfg.deinit();
    var tfetch = http.AccessTokenFetcher{
        .cfg = cfg.config(),
        .exec = exec,
        .token_url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential",
    };
    cfg.fetcher = tfetch.fetcher();

    var svc = service.Service.init(gpa, cfg.config(), exec);
    // 预先塞入 AT1(模拟缓存里躺着过期 token)
    try cfg.slot.update(io, "AT1", 7200);

    var uri_buf = std.ArrayList(u8).empty;
    defer uri_buf.deinit(gpa);
    try uri_buf.appendSlice(gpa, "https://api.weixin.qq.com/cgi-bin/user/info?openid=oZ");

    const r = svc.get(io, uri_buf.items, &.{});
    switch (r) {
        .ok => |b| {
            defer gpa.free(b);
            try std.testing.expect(std.mem.indexOf(u8, b, "oZ") != null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            std.debug.print("retry err: [{d}] {s}\n", .{ err.error_code, err.error_msg });
            return error.Unexpected;
        },
    }
    try std.testing.expectEqual(@as(usize, 1), script.token_calls); // 旧 token 预置在槽里,失效后自动刷新了一次
    try std.testing.expectEqual(@as(usize, 2), script.api_calls); // 业务重试了一次
}

/// 未注入真实 fetcher 前的占位(任何调用都会报错)。
const undefined_fetcher = @import("common").token.Fetcher{
    .ptr = undefined,
    .vtable = &.{ .fetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) @import("common").token.FetchOutcome {
            _ = c;
            _ = i;
            return .{ .err = @import("common").error_util.WxError.transport(g, "fetcher not wired", .{}) };
        }
    }.f },
};
