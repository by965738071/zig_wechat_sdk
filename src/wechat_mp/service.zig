//! 公众号服务基类 —— 对应 Java `api.impl.BaseWxMpServiceImpl`。
//!
//! 复刻三条核心协议(全部是 Java 里踩坑打磨出的行为,逐条对齐):
//! 1. `execute`:errcode==-1(系统繁忙/传输错误)按 `retrySleepMillis * 2^n`
//!    指数退避,最多 `maxRetryTimes` 次;
//! 2. `executeInternal`:拒绝自带 access_token 的 uri → 取 token → 拼 url →
//!    执行;业务错误码 ∈ ACCESS_TOKEN_ERROR_CODES 且未禁用自动刷新时,
//!    expireAccessToken(比对旧 token)+ **仅重试一次**(do_not_auto_refresh
//!    防递归,对应 Java 的 ThreadLocal doNotAutoRefreshToken);
//! 3. token 获取协议本身在 `common/token.zig`(tryLock 自旋双重检查)。
//!
//! 子服务(UserService 等)组合在本结构之上,不继承 —— 与 Java 的
//! 「子服务持 parent 引用」组合方式一致。
const std = @import("std");
const testing = std.testing;

const consts = @import("common").consts;
const error_mod = @import("common").error_util;
pub const WxError = error_mod.WxError;
const json_util = @import("common").json_util;
const random_mod = @import("common").random;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
const sha1 = @import("common").crypt.sha1;
const token_mod = @import("common").token;

const config_mod = @import("config.zig");
pub const ConfigStorage = config_mod.ConfigStorage;
const http_mod = @import("http.zig");
pub const RequestExecutor = http_mod.RequestExecutor;

/// 对应 Java `api.impl.WxMpServiceImpls`/枚举 `ApiUrl`(骨架收录代表性接口)。
pub const ApiUrl = enum {
    // token(通常由 AccessTokenFetcher 走,列在此处保持目录完整)
    access_token,
    stable_token,
    // 用户
    user_info,
    user_get,
    user_tagging,
    user_info_batch,
    // 菜单
    menu_create,
    menu_delete,
    menu_get,
    // 消息
    custom_send,
    template_send,
    // 二维码 / ticket
    qrcode_create,
    ticket_get,
    // OAuth
    oauth_access_token,
    oauth_refresh_token,
    // 长链接转短链接(挂主接口 BaseWxMpServiceImpl.shortUrl)
    shorturl,
    // 基础能力(对应 Java BaseWxMpServiceImpl 的 URL-only 方法)
    get_callback_ip, // getCallbackIP -> GET /cgi-bin/getcallbackip
    get_current_autoreply_info, // getCurrentAutoReplyInfo
    clear_quota, // clearQuota(appid)
    net_check, // netCheck(action, operator)
    // 用户黑名单 —— enums/WxMpApiUrl.UserBlacklist(3)
    blacklist_get,
    blacklist_batch,
    blacklist_unbatch,
    // 图文评论 —— enums/WxMpApiUrl.Comment(8)
    comment_open,
    comment_close,
    comment_list,
    comment_mark_elect,
    comment_unmark_elect,
    comment_delete,
    comment_reply_add,
    comment_reply_delete,
    // 草稿箱 —— enums/WxMpApiUrl.Draft(6)
    draft_add,
    draft_update,
    draft_get,
    draft_delete,
    draft_batchget,
    draft_count,
    // 发布能力 —— enums/WxMpApiUrl.FreePublish(5)
    freepublish_submit,
    freepublish_getarticle,
    freepublish_get,
    freepublish_delete,
    freepublish_batchget,
    // 对话能力(顾问) —— enums/WxMpApiUrl.Guide,WxMpGuideServiceImpl 子集(19)
    guide_add,
    guide_set_config,
    guide_set_acct_config,
    guide_update,
    guide_get,
    guide_del,
    guide_list,
    guide_create_qrcode,
    guide_chat_record,
    guide_get_config,
    guide_get_acct_config,
    guide_push_wxa_path,
    guide_new_group,
    guide_group_list,
    guide_group_info,
    guide_add_to_group,
    guide_del_from_group,
    guide_group_by_guide,
    guide_del_group,
    // 顾问·客户(Buyer) —— enums/WxMpApiUrl.Guide,WxMpGuideBuyerServiceImpl(7)
    guide_add_buyer_relation,
    guide_del_buyer_relation,
    guide_get_buyer_relation_list,
    guide_rebind_buyer,
    guide_update_buyer_relation,
    guide_get_buyer_relation_by_buyer,
    guide_get_buyer_relation,
    // 顾问·标签(Tag) —— enums/WxMpApiUrl.Guide,WxMpGuideTagServiceImpl(10)
    guide_new_tag_option,
    guide_del_tag_option,
    guide_add_tag_option,
    guide_get_tag_option,
    guide_add_buyer_tag,
    guide_get_buyer_tag,
    guide_query_buyer_by_tag,
    guide_del_buyer_tag,
    guide_add_buyer_display_tag,
    guide_get_buyer_display_tag,
    // 顾问·群发任务(MassedJob) —— enums/WxMpApiUrl.Guide,WxMpGuideMassedJobServiceImpl(5)
    guide_add_massed_job,
    guide_get_massed_job_list,
    guide_get_massed_job,
    guide_update_massed_job,
    guide_cancel_massed_job,
    // 卡券 —— enums/WxMpApiUrl.Card,WxMpCardServiceImpl 纯 JSON 子集(17)
    card_code_decrypt,
    card_code_get,
    card_code_consume,
    card_code_mark,
    card_get,
    card_test_whitelist,
    card_code_unavailable,
    card_delete,
    card_code_deposit,
    card_code_deposit_count,
    card_code_checkcode,
    card_modify_stock,
    card_code_update,
    card_paycell_set,
    card_mpnews_gethtml,
    card_self_consume_cell_set,
    card_user_card_list,
    // 电子发票 —— enums/WxMpApiUrl.Invoice,字段可逐字确定的子集(4)
    invoice_query_info,
    invoice_get_contact,
    invoice_get_auth_field,
    invoice_get_pay_mch,

    pub fn asUri(self: ApiUrl) []const u8 {
        return switch (self) {
            .access_token => "cgi-bin/token",
            .stable_token => "cgi-bin/stable_token",
            .user_info => "cgi-bin/user/info",
            .user_get => "cgi-bin/user/get",
            .user_tagging => "cgi-bin/tags/members/batchtagging",
            .user_info_batch => "cgi-bin/user/info/batchget",
            .menu_create => "cgi-bin/menu/create",
            .menu_delete => "cgi-bin/menu/delete",
            .menu_get => "cgi-bin/menu/get",
            .custom_send => "cgi-bin/message/custom/send",
            .template_send => "cgi-bin/message/template/send",
            .qrcode_create => "cgi-bin/qrcode/create",
            .ticket_get => "cgi-bin/ticket/getticket",
            .oauth_access_token => "sns/oauth2/access_token",
            .oauth_refresh_token => "sns/oauth2/refresh_token",
            .shorturl => "cgi-bin/shorturl",
            // 逐字对照 WxMpApiUrl.java 常量
            .get_callback_ip => "cgi-bin/getcallbackip",
            .get_current_autoreply_info => "cgi-bin/get_current_autoreply_info",
            .clear_quota => "cgi-bin/clear_quota",
            .net_check => "cgi-bin/callback/check",
            // 逐字对照 WxMpApiUrl.java(UserBlacklist / Comment / Draft / FreePublish)
            .blacklist_get => "cgi-bin/tags/members/getblacklist",
            .blacklist_batch => "cgi-bin/tags/members/batchblacklist",
            .blacklist_unbatch => "cgi-bin/tags/members/batchunblacklist",
            .comment_open => "cgi-bin/comment/open",
            .comment_close => "cgi-bin/comment/close",
            .comment_list => "cgi-bin/comment/list",
            .comment_mark_elect => "cgi-bin/comment/markelect",
            .comment_unmark_elect => "cgi-bin/comment/unmarkelect",
            .comment_delete => "cgi-bin/comment/delete",
            .comment_reply_add => "cgi-bin/comment/reply/add",
            .comment_reply_delete => "cgi-bin/comment/reply/delete",
            .draft_add => "cgi-bin/draft/add",
            .draft_update => "cgi-bin/draft/update",
            .draft_get => "cgi-bin/draft/get",
            .draft_delete => "cgi-bin/draft/delete",
            .draft_batchget => "cgi-bin/draft/batchget",
            .draft_count => "cgi-bin/draft/count",
            .freepublish_submit => "cgi-bin/freepublish/submit",
            .freepublish_getarticle => "cgi-bin/freepublish/getarticle",
            .freepublish_get => "cgi-bin/freepublish/get",
            .freepublish_delete => "cgi-bin/freepublish/delete",
            .freepublish_batchget => "cgi-bin/freepublish/batchget",
            // 逐字对照 WxMpApiUrl.java(Guide / Card / Invoice)
            .guide_add => "cgi-bin/guide/addguideacct",
            .guide_set_config => "cgi-bin/guide/setguideconfig",
            .guide_set_acct_config => "cgi-bin/guide/setguideacctconfig",
            .guide_update => "cgi-bin/guide/updateguideacct",
            .guide_get => "cgi-bin/guide/getguideacct",
            .guide_del => "cgi-bin/guide/delguideacct",
            .guide_list => "cgi-bin/guide/getguideacctlist",
            .guide_create_qrcode => "cgi-bin/guide/guidecreateqrcode",
            .guide_chat_record => "cgi-bin/guide/getguidebuyerchatrecord",
            .guide_get_config => "cgi-bin/guide/getguideconfig",
            .guide_get_acct_config => "cgi-bin/guide/getguideacctconfig",
            .guide_push_wxa_path => "cgi-bin/guide/pushshowwxapathmenu",
            .guide_new_group => "cgi-bin/guide/newguidegroup",
            .guide_group_list => "cgi-bin/guide/getguidegrouplist",
            .guide_group_info => "cgi-bin/guide/getgroupinfo",
            .guide_add_to_group => "cgi-bin/guide/addguide2guidegroup",
            .guide_del_from_group => "cgi-bin/guide/delguide2guidegroup",
            .guide_group_by_guide => "cgi-bin/guide/getgroupbyguide",
            .guide_del_group => "cgi-bin/guide/delguidegroup",
            // 逐字对照 WxMpApiUrl.Guide(WxMpGuideBuyerServiceImpl,7)
            .guide_add_buyer_relation => "cgi-bin/guide/addguidebuyerrelation",
            .guide_del_buyer_relation => "cgi-bin/guide/delguidebuyerrelation",
            .guide_get_buyer_relation_list => "cgi-bin/guide/getguidebuyerrelationlist",
            .guide_rebind_buyer => "cgi-bin/guide/rebindguideacctforbuyer",
            .guide_update_buyer_relation => "cgi-bin/guide/updateguidebuyerrelation",
            .guide_get_buyer_relation_by_buyer => "cgi-bin/guide/getguidebuyerrelationbybuyer",
            .guide_get_buyer_relation => "cgi-bin/guide/getguidebuyerrelation",
            // 逐字对照 WxMpApiUrl.Guide(WxMpGuideTagServiceImpl,10)
            .guide_new_tag_option => "cgi-bin/guide/newguidetagoption",
            .guide_del_tag_option => "cgi-bin/guide/delguidetagoption",
            .guide_add_tag_option => "cgi-bin/guide/addguidetagoption",
            .guide_get_tag_option => "cgi-bin/guide/getguidetagoption",
            .guide_add_buyer_tag => "cgi-bin/guide/addguidebuyertag",
            .guide_get_buyer_tag => "cgi-bin/guide/getguidebuyertag",
            .guide_query_buyer_by_tag => "cgi-bin/guide/queryguidebuyerbytag",
            .guide_del_buyer_tag => "cgi-bin/guide/delguidebuyertag",
            .guide_add_buyer_display_tag => "cgi-bin/guide/addguidebuyerdisplaytag",
            .guide_get_buyer_display_tag => "cgi-bin/guide/getguidebuyerdisplaytag",
            // 逐字对照 WxMpApiUrl.Guide(WxMpGuideMassedJobServiceImpl,5)
            .guide_add_massed_job => "cgi-bin/guide/addguidemassendjob",
            .guide_get_massed_job_list => "cgi-bin/guide/getguidemassendjoblist",
            .guide_get_massed_job => "cgi-bin/guide/getguidemassendjob",
            .guide_update_massed_job => "cgi-bin/guide/updateguidemassendjob",
            .guide_cancel_massed_job => "cgi-bin/guide/cancelguidemassendjob",
            .card_code_decrypt => "card/code/decrypt",
            .card_code_get => "card/code/get",
            .card_code_consume => "card/code/consume",
            .card_code_mark => "card/code/mark",
            .card_get => "card/get",
            .card_test_whitelist => "card/testwhitelist/set",
            .card_code_unavailable => "card/code/unavailable",
            .card_delete => "card/delete",
            .card_code_deposit => "card/code/deposit",
            .card_code_deposit_count => "card/code/getdepositcount",
            .card_code_checkcode => "card/code/checkcode",
            .card_modify_stock => "card/modifystock",
            .card_code_update => "card/code/update",
            .card_paycell_set => "card/paycell/set",
            .card_mpnews_gethtml => "card/mpnews/gethtml",
            .card_self_consume_cell_set => "card/selfconsumecell/set",
            .card_user_card_list => "card/user/getcardlist",
            .invoice_query_info => "card/invoice/queryinvoceinfo",
            .invoice_get_contact => "card/invoice/setbizattr?action=get_contact",
            .invoice_get_auth_field => "card/invoice/setbizattr?action=get_auth_field",
            .invoice_get_pay_mch => "card/invoice/setbizattr?action=get_pay_mch",
        };
    }
};

/// 对应 Java `WxMpService.API_HOST_URL`("https://api.weixin.qq.com/%s")。
pub const api_host_url = "https://api.weixin.qq.com/";

pub const Query = struct { key: []const u8, value: []const u8 };

/// URL 百分号编码(骨架版:安全字符集外一律 %XX,对应 URLEncoder 语义)。
pub fn urlEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(gpa, c),
            ' ' => try out.append(gpa, '+'),
            else => {
                var esc: [3]u8 = undefined;
                const part = try std.fmt.bufPrint(&esc, "%{X:0>2}", .{c});
                try out.appendSlice(gpa, part);
            },
        }
    }
    return try out.toOwnedSlice(gpa); // 0.18-dev:ArrayList.toOwnedSlice 需传 allocator
}

/// base?k1=v1&k2=v2(&access_token=...)
fn buildUrl(gpa: std.mem.Allocator, base: []const u8, query: []const Query, access_token: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    var sep: u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) '&' else '?';
    for (query) |q| {
        const v = try urlEncode(gpa, q.value);
        defer gpa.free(v);
        const part = try std.fmt.allocPrint(gpa, "{c}{s}={s}", .{ sep, q.key, v });
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
        if(sep == '?') {
             sep = '&';
        }
    }
    if (access_token) |t| {
        const part = try std.fmt.allocPrint(gpa, "{c}access_token={s}", .{ sep, t });
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    return try out.toOwnedSlice(gpa);
}

/// 对应 `BaseWxMpServiceImpl`。
pub const Service = struct {
    gpa: std.mem.Allocator,
    config: ConfigStorage,
    executor: RequestExecutor,
    /// 对应 retrySleepMillis / maxRetryTimes
    retry_sleep_ms: u64 = consts.DEFAULT_RETRY_SLEEP_MS,
    max_retry_times: u32 = consts.DEFAULT_MAX_RETRY_TIMES,
    wx_type: error_mod.WxType = .mp,

    pub fn init(gpa: std.mem.Allocator, cfg: ConfigStorage, exec: RequestExecutor) Service {
        return .{ .gpa = gpa, .config = cfg, .executor = exec };
    }

    /// 生产接线:注入**真实 std.http 执行器**(调用方持有 `http_exec`,须比 Service
    /// 活得久)。提供一条不再只有 mock 可用的构造路径;真实网络调用仍需真凭证/环境,
    /// 离线不可测,故此处只做接线(见 service.zig 的 initWithRealHttp 单测)。
    pub fn initWithRealHttp(gpa: std.mem.Allocator, cfg: ConfigStorage, http_exec: *http_mod.HttpExecutor) Service {
        return .{ .gpa = gpa, .config = cfg, .executor = http_exec.executor() };
    }

    /// 对应 `getAccessToken()` / `getAccessToken(boolean forceRefresh)`。
    pub fn getAccessToken(self: *Service, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        return self.config.acquireAccessToken(io, buf, force_refresh);
    }

    /// 对应 `BaseWxMpServiceImpl#getJsapiTicket()` / `getTicket(TicketType.JSAPI, ...)`:
    /// 结果拷贝进 buf(≥256 字节),完整缓存/过期/锁协议在 ConfigStorage 的 ticket 槽。
    pub fn getJsapiTicket(self: *Service, io: std.Io, buf: []u8, force_refresh: bool) WxResult([]const u8) {
        return self.config.acquireJsapiTicket(io, buf, force_refresh);
    }

    /// JSSDK 签名(对应 Java `WxJsapiSignature`,字段 gpa 拥有,用毕 deinit)。
    pub const JsapiSignature = struct {
        gpa: std.mem.Allocator,
        appid: []u8,
        noncestr: []u8,
        timestamp: i64,
        url: []u8,
        signature: []u8,

        pub fn deinit(self: *JsapiSignature) void {
            const g = self.gpa;
            g.free(self.appid);
            g.free(self.noncestr);
            g.free(self.url);
            g.free(self.signature);
            self.* = undefined;
        }
    };

    /// 注入量(测试确定性):生产传 null 自动生成随机 noncestr 与秒级时间戳。
    pub const JsapiInject = struct { noncestr: []const u8, timestamp: i64 };

    /// 对应 `BaseWxMpServiceImpl#createJsapiSignature(String url)`:
    /// `SHA1.genWithAmple("jsapi_ticket="+ticket, "noncestr="+nonce,
    ///  "timestamp="+ts, "url="+url)`(排序后 & 连接,见 SHA1.java)。
    /// 先取 jsapi ticket(带缓存),再做纯 SHA1,无需联调。
    pub fn createJsapiSignature(self: *Service, io: std.Io, url: []const u8, inject: ?JsapiInject) WxResult(JsapiSignature) {
        const gpa = self.gpa;
        var tbuf: [256]u8 = undefined;
        const ticket = switch (self.getJsapiTicket(io, &tbuf, false)) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };

        var nonce_buf: [16]u8 = undefined;
        var nonce: []const u8 = undefined;
        var ts: i64 = undefined;
        if (inject) |inj| {
            nonce = inj.noncestr;
            ts = inj.timestamp;
        } else {
            random_mod.randomStr(io, &nonce_buf) catch |e|
                return .{ .err = WxError.transport(gpa, "nonce: {s}", .{@errorName(e)}) };
            nonce = &nonce_buf;
            ts = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        }

        const p1 = std.fmt.allocPrint(gpa, "jsapi_ticket={s}", .{ticket}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(p1);
        const p2 = std.fmt.allocPrint(gpa, "noncestr={s}", .{nonce}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(p2);
        const p3 = std.fmt.allocPrint(gpa, "timestamp={d}", .{ts}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(p3);
        const p4 = std.fmt.allocPrint(gpa, "url={s}", .{url}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(p4);

        const signature = sha1.genWithAmple(gpa, &.{ p1, p2, p3, p4 }) catch |e|
            return .{ .err = WxError.cryptoError(gpa, "jsapi signature: {s}", .{@errorName(e)}) };
        const appid = gpa.dupe(u8, self.config.appid()) catch {
            gpa.free(signature);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        errdefer gpa.free(appid);
        const noncestr = gpa.dupe(u8, nonce) catch {
            gpa.free(signature);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        errdefer gpa.free(noncestr);
        const url_copy = gpa.dupe(u8, url) catch {
            gpa.free(signature);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        return .{ .ok = .{
            .gpa = gpa,
            .appid = appid,
            .noncestr = noncestr,
            .timestamp = ts,
            .url = url_copy,
            .signature = signature,
        } };
    }

    /// GET(JSON API 常用),对应 `String get(String url)`。
    pub fn get(self: *Service, io: std.Io, uri: []const u8, query: []const Query) WxResult([]u8) {
        return self.call(io, uri, query, null);
    }

    /// POST(JSON/XML),对应 `String post(String url, String postData)`。
    pub fn post(self: *Service, io: std.Io, uri: []const u8, query: []const Query, data: []const u8) WxResult([]u8) {
        return self.call(io, uri, query, data);
    }

    /// 带自定义请求头的 POST(对应 Java `MaterialUploadRequestExecutor` 设置
    /// `Content-Type: multipart/form-data`)。与 post 同链路(token 附加 + errcode
    /// 折叠 + 重试),额外把 req_headers 交给 header-capable 执行器。
    pub fn postWithHeaders(self: *Service, io: std.Io, uri: []const u8, query: []const Query, data: []const u8, req_headers: []const result_mod.Header) WxResult([]u8) {
        return self.callWithHeaders(io, uri, query, data, req_headers);
    }

    /// 拼 query 后走 execute。
    pub fn call(self: *Service, io: std.Io, uri: []const u8, query: []const Query, body: ?[]const u8) WxResult([]u8) {
        return self.callWithHeaders(io, uri, query, body, &.{});
    }

    fn callWithHeaders(self: *Service, io: std.Io, uri: []const u8, query: []const Query, body: ?[]const u8, req_headers: []const result_mod.Header) WxResult([]u8) {
        if (query.len == 0) return self.executeWithHeaders(io, uri, body, req_headers);
        const full = buildUrl(self.gpa, uri, query, null) catch |e|
            return .{ .err = WxError.internal(self.gpa, "build url: {s}", .{@errorName(e)}) };
        defer self.gpa.free(full);
        return self.executeWithHeaders(io, full, body, req_headers);
    }

    /// 协议 1:系统繁忙指数退避。
    pub fn execute(self: *Service, io: std.Io, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        return self.executeWithHeaders(io, uri, body, &.{});
    }

    /// 与 execute 同,但携带自定义请求头(重试/token 协议完全一致)。执行器未实现
    /// `execute_with_headers` 时由 wrapper 回退、忽略请求头,行为与旧版一致。
    pub fn executeWithHeaders(self: *Service, io: std.Io, uri: []const u8, body: ?[]const u8, req_headers: []const result_mod.Header) WxResult([]u8) {
        var attempt: u32 = 0;
        while (true) {
            const r = self.executeInternal(io, uri, body, false, req_headers);
            switch (r) {
                .ok => return r,
                .err => |e| {
                    // transport 错误也折叠为 code=-1,与 Java 相同走退避重试
                    if (e.error_code != consts.SYSTEM_BUSY_CODE or attempt >= self.max_retry_times) return r;
                    var err = e;
                    err.deinit();
                    const backoff_ms: i64 = @intCast(self.retry_sleep_ms << @as(u5, @intCast(attempt)));
                    std.Io.sleep(io, .fromMilliseconds(backoff_ms), .real) catch {};
                    attempt += 1;
                },
            }
        }
    }

    /// 协议 2:token 附加 + token 失效自动刷新(仅一次)。
    fn executeInternal(self: *Service, io: std.Io, uri: []const u8, body: ?[]const u8, do_not_auto_refresh: bool, req_headers: []const result_mod.Header) WxResult([]u8) {
        // 对应 Java 直接抛 RuntimeException 的防御:防止 token 泄漏到外部可控 url
        if (std.mem.indexOf(u8, uri, "access_token=") != null) {
            return .{ .err = WxError.internal(self.gpa, "uri 不能自带 access_token: {s}", .{uri}) };
        }

        var tbuf: [256]u8 = undefined;
        const tok = switch (self.getAccessToken(io, &tbuf, false)) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };

        const full = buildUrl(self.gpa, uri, &.{}, tok) catch |e|
            return .{ .err = WxError.internal(self.gpa, "build url: {s}", .{@errorName(e)}) };
        defer self.gpa.free(full);

        // 走 header-capable 执行器(真实 http 会发送 req_headers 并回传响应头);
        // 未实现的 mock 由 executeWithHeaders 回退到 execute,行为不变。
        const resp = self.executor.executeWithHeaders(
            self.gpa,
            io,
            if (body != null) .post else .get,
            full,
            req_headers,
            body,
        );
        switch (resp) {
            .err => |e| return .{ .err = e }, // 传输错误:交给 execute 的 -1 退避
            .ok => |r| {
                const b = r.takeBody(self.gpa); // 释放响应头、取回 gpa 拥有的 body
                var we = WxError.fromJson(self.gpa, b, self.wx_type) catch {
                    // 非 JSON 响应(如 "ok")按成功透传,对应 Java 的宽容解析
                    return .{ .ok = b };
                };
                if (we.error_code == 0) {
                    we.deinit();
                    return .{ .ok = b };
                }
                if (consts.isAccessTokenError(we.error_code) and !do_not_auto_refresh) {
                    // 对应 Java:equals 命中才 expire,但无论是否命中都强制刷新重试一次
                    _ = self.config.expireAccessToken(io, tok);
                    we.deinit();
                    self.gpa.free(b);
                    return self.executeInternal(io, uri, body, true, req_headers);
                }
                self.gpa.free(b); // WxError.raw 已持有副本
                return .{ .err = we };
            },
        }
    }

    /// 无 token 通道:对应 Java 走 `SimpleGet/PostRequestExecutor` 且不附加 access_token
    /// 的接口(sns/jscode2session 等)。仍按 `handleResponse` 语义折叠 errcode,
    /// 但不取 token、也不做 token 失效自动刷新。
    pub fn executeNoToken(self: *Service, io: std.Io, uri: []const u8, query: []const Query, body: ?[]const u8) WxResult([]u8) {
        if (query.len == 0) return self.postNoToken(io, uri, body);
        const full = buildUrl(self.gpa, uri, query, null) catch |e|
            return .{ .err = WxError.internal(self.gpa, "build url: {s}", .{@errorName(e)}) };
        defer self.gpa.free(full);
        return self.postNoToken(io, full, body);
    }

    fn postNoToken(self: *Service, io: std.Io, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        const resp = self.executor.execute(
            self.gpa,
            io,
            if (body != null) .post else .get,
            uri,
            body,
        );
        switch (resp) {
            .err => |e| return .{ .err = e },
            .ok => |b| {
                var we = WxError.fromJson(self.gpa, b, self.wx_type) catch
                    return .{ .ok = b };
                if (we.error_code == 0) {
                    we.deinit();
                    return .{ .ok = b };
                }
                self.gpa.free(b);
                return .{ .err = we };
            },
        }
    }

    /// 对应 Java `BaseWxMpServiceImpl.shortUrl(longUrl)`:POST /cgi-bin/shorturl,
    /// 请求体 {"action":"long2short","long_url":...},响应取 short_url 字段。
    /// 微信接口 bug:longUrl 含 "&access_token=" 会报错,Java 显式拒绝该输入。
    /// 返回 gpa 拥有的短链,调用方 free。
    pub fn shortUrl(self: *Service, io: std.Io, long_url: []const u8) WxResult([]u8) {
        if (std.mem.indexOf(u8, long_url, "&access_token=") != null) {
            return .{ .err = WxError.configError(self.gpa, "要转换的网址含非法字符 &access_token=(微信接口 bug)", .{}) };
        }
        var ob = json_util.ObjectBuilder.init(self.gpa);
        defer ob.deinit();
        ob.putStr("action", "long2short") catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        ob.putStr("long_url", long_url) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        defer self.gpa.free(body);

        const uri = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ api_host_url, ApiUrl.shorturl.asUri() }) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        defer self.gpa.free(uri);

        const resp = switch (self.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(resp);

        const parsed = json_util.parse(self.gpa, resp) catch
            return .{ .err = WxError.transport(self.gpa, "shorturl response not json", .{}) };
        defer parsed.deinit();
        const short = json_util.getStr(parsed.value, "short_url") orelse
            return .{ .err = WxError.transport(self.gpa, "shorturl response missing short_url", .{}) };
        return .{ .ok = self.gpa.dupe(u8, short) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) } };
    }

    // -----------------------------------------------------------------------
    // 基础能力:只拼 URL/参数、无需联调的子服务端点
    // (逐字对照 `WxMpApiUrl.java` 常量 + `BaseWxMpServiceImpl` 对应方法)。
    // 均复用 get/post(自带 access_token 附加 + errcode 折叠 + 重试)。
    // -----------------------------------------------------------------------

    fn apiUri(self: *Service, which: ApiUrl) WxResult([]u8) {
        return .{ .ok = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ api_host_url, which.asUri() }) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) } };
    }

    fn apiGet(self: *Service, io: std.Io, which: ApiUrl) WxResult([]u8) {
        const uri = switch (self.apiUri(which)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(uri);
        return self.get(io, uri, &.{});
    }

    fn apiPost(self: *Service, io: std.Io, which: ApiUrl, body: []const u8) WxResult([]u8) {
        const uri = switch (self.apiUri(which)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(uri);
        return self.post(io, uri, &.{}, body);
    }

    /// 微信服务器 IP 列表 —— 对应 `getCallbackIP()`:
    /// GET /cgi-bin/getcallbackip -> {"ip_list":[...]},字段 gpa 拥有,用毕 deinit。
    pub const CallbackIpResult = struct {
        gpa: std.mem.Allocator,
        ips: [][]u8 = &.{},

        pub fn deinit(self: *CallbackIpResult) void {
            for (self.ips) |ip| self.gpa.free(ip);
            if (self.ips.len > 0) self.gpa.free(self.ips);
            self.* = undefined;
        }
    };

    pub fn getCallbackIP(self: *Service, io: std.Io) WxResult(CallbackIpResult) {
        const gpa = self.gpa;
        const resp = switch (self.apiGet(io, .get_callback_ip)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getcallbackip response not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "ip_list") orelse
            return .{ .err = WxError.transport(gpa, "getcallbackip response missing ip_list", .{}) };
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |ip| gpa.free(ip);
            list.deinit(gpa);
        }
        for (arr.items) |v| {
            const s = switch (v) {
                .string => |x| x,
                else => continue,
            };
            const ip = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            list.append(gpa, ip) catch {
                gpa.free(ip); // 尚未纳入 list
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        return .{ .ok = .{ .gpa = gpa, .ips = list.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } } };
    }

    /// 当前自动回复配置 —— 对应 `getCurrentAutoReplyInfo()`:
    /// GET /cgi-bin/get_current_autoreply_info,原样返回响应 body(gpa 拥有)。
    pub fn getCurrentAutoReplyInfo(self: *Service, io: std.Io) WxResult([]u8) {
        return self.apiGet(io, .get_current_autoreply_info);
    }

    /// 接口调用频次清零 —— 对应 `clearQuota(appid)`:
    /// POST /cgi-bin/clear_quota {"appid":...}。
    pub fn clearQuota(self: *Service, io: std.Io, appid: []const u8) result_mod.Done {
        var ob = json_util.ObjectBuilder.init(self.gpa);
        defer ob.deinit();
        ob.putStr("appid", appid) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        defer self.gpa.free(body);
        const resp = switch (self.apiPost(io, .clear_quota, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        self.gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 网络检测 —— 对应 `netCheck(action, operator)`:
    /// POST /cgi-bin/callback/check {"action":...,"check_operator":...},原样返回 body。
    pub fn netCheck(self: *Service, io: std.Io, action: []const u8, operator: []const u8) WxResult([]u8) {
        var ob = json_util.ObjectBuilder.init(self.gpa);
        defer ob.deinit();
        ob.putStr("action", action) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        ob.putStr("check_operator", operator) catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(self.gpa, "oom", .{}) };
        defer self.gpa.free(body);
        return self.apiPost(io, .net_check, body);
    }
};

// ---------------------------------------------------------------------------
// 测试:URL-only 端点 + JSSDK 签名(离线,记录型 executor)
// ---------------------------------------------------------------------------

/// 记录型 executor:捕获 method/uri/body,按 uri 子串返回预置响应。
const SvcRecorder = struct {
    const Reply = struct { match: []const u8, response: []const u8 };
    gpa: std.mem.Allocator,
    replies: []const Reply,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: []u8 = &.{},
    last_body: []u8 = &.{},

    fn deinit(self: *SvcRecorder) void {
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
    }
    fn uri(self: *const SvcRecorder) []const u8 {
        return self.last_uri;
    }
    fn body(self: *const SvcRecorder) []const u8 {
        return self.last_body;
    }
    fn executor(self: *SvcRecorder) RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = execImpl } };
    }
    fn execImpl(ctx: *anyopaque, g: std.mem.Allocator, i: std.Io, m: RequestExecutor.Method, u: []const u8, b: ?[]const u8) WxResult([]u8) {
        _ = i;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = @tagName(m);
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        self.last_uri = g.dupe(u8, u) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        const bb = b orelse "";
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
        self.last_body = g.dupe(u8, bb) catch return .{ .err = WxError.transport(g, "oom", .{}) };
        for (self.replies) |r| {
            if (std.mem.indexOf(u8, u, r.match) != null)
                return .{ .ok = g.dupe(u8, r.response) catch return .{ .err = WxError.transport(g, "oom", .{}) } };
        }
        return .{ .err = WxError.transport(g, "svc stub miss: {s}", .{u}) };
    }
};

const AF = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = c;
        _ = i;
        return .{ .ok = .{ .token = g.dupe(u8, "AT") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
    }
};
const TF = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = c;
        _ = i;
        return .{ .ok = .{ .token = g.dupe(u8, "JSAPI_TICKET") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) }, .expires_in = 7200 } };
    }
};

fn mkCfg(gpa: std.mem.Allocator, with_ticket: bool) !config_mod.InMemoryConfigStorage {
    const tfa: ?token_mod.Fetcher = if (with_ticket) .{ .ptr = undefined, .vtable = &.{ .fetch = TF.f } } else null;
    return config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = AF.f } }, .{
        .appid = "wxAPP",
        .secret = "SEC",
        .ticket_fetcher = tfa,
    });
}

test "URL-only endpoints: getCallbackIP / clearQuota / netCheck / autoreply" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rec = SvcRecorder{ .gpa = gpa, .replies = &.{
        .{ .match = "getcallbackip", .response = "{\"ip_list\":[\"1.2.3.4\",\"5.6.7.8\"]}" },
        .{ .match = "get_current_autoreply_info", .response = "{\"is_add_friend_reply_open\":1}" },
        .{ .match = "clear_quota", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "callback/check", .response = "{\"errcode\":0}" },
    } };
    defer rec.deinit();
    var cfg = try mkCfg(gpa, false);
    defer cfg.deinit();
    var svc = Service.init(gpa, cfg.config(), rec.executor());

    // getCallbackIP:GET,解析 ip_list
    switch (svc.getCallbackIP(io)) {
        .ok => |*r| {
            var ips = r.*;
            defer ips.deinit();
            try testing.expectEqual(@as(usize, 2), ips.ips.len);
            try testing.expectEqualStrings("1.2.3.4", ips.ips[0]);
            try testing.expectEqualStrings("5.6.7.8", ips.ips[1]);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedCallbackIpError;
        },
    }
    try testing.expectEqualStrings("get", rec.last_method);
    try testing.expect(std.mem.indexOf(u8, rec.uri(), "cgi-bin/getcallbackip") != null);
    try testing.expect(std.mem.indexOf(u8, rec.uri(), "access_token=AT") != null);

    // getCurrentAutoReplyInfo:GET,原样透传
    switch (svc.getCurrentAutoReplyInfo(io)) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expect(std.mem.indexOf(u8, b, "is_add_friend_reply_open") != null);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedAutoreplyError;
        },
    }

    // clearQuota:POST {"appid":...}
    switch (svc.clearQuota(io, "wxAPP")) {
        .ok => {},
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedClearQuotaError;
        },
    }
    try testing.expectEqualStrings("post", rec.last_method);
    try testing.expect(std.mem.indexOf(u8, rec.uri(), "cgi-bin/clear_quota") != null);
    try testing.expect(std.mem.indexOf(u8, rec.body(), "\"appid\":\"wxAPP\"") != null);

    // netCheck:POST {"action","check_operator"}
    switch (svc.netCheck(io, "dns", "OPER")) {
        .ok => |b| gpa.free(b),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedNetCheckError;
        },
    }
    try testing.expect(std.mem.indexOf(u8, rec.uri(), "cgi-bin/callback/check") != null);
    try testing.expect(std.mem.indexOf(u8, rec.body(), "\"action\":\"dns\"") != null);
    try testing.expect(std.mem.indexOf(u8, rec.body(), "\"check_operator\":\"OPER\"") != null);
}

test "createJsapiSignature: SHA1.genWithAmple over ticket/noncestr/timestamp/url" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rec = SvcRecorder{ .gpa = gpa, .replies = &.{} };
    defer rec.deinit();
    var cfg = try mkCfg(gpa, true);
    defer cfg.deinit();
    var svc = Service.init(gpa, cfg.config(), rec.executor());

    const url = "https://example.com/page?x=1";
    switch (svc.createJsapiSignature(io, url, .{ .noncestr = "NONCE", .timestamp = 1700000000 })) {
        .ok => |*r| {
            var sig = r.*;
            defer sig.deinit();
            try testing.expectEqualStrings("wxAPP", sig.appid);
            try testing.expectEqualStrings("NONCE", sig.noncestr);
            try testing.expectEqualStrings(url, sig.url);
            try testing.expectEqual(@as(i64, 1700000000), sig.timestamp);
            // 期望:对 4 串排序后用 & 连接再 SHA1(与 Java SHA1.genWithAmple 一致)
            const parts = [_][]const u8{
                "jsapi_ticket=JSAPI_TICKET",
                "noncestr=NONCE",
                "timestamp=1700000000",
                "url=https://example.com/page?x=1",
            };
            const expect = try sha1.genWithAmple(gpa, &parts);
            defer gpa.free(expect);
            try testing.expectEqualStrings(expect, sig.signature);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.UnexpectedJsapiSigError;
        },
    }
    // 签名只取 ticket(走缓存),不触发网络请求
    try testing.expectEqual(@as(usize, 0), rec.calls);
}

test "Service.initWithRealHttp: mp call wired to real std.http executor" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try mkCfg(gpa, false);
    defer cfg.deinit();
    var http = http_mod.HttpExecutor.init(gpa, io);
    const svc = Service.initWithRealHttp(gpa, cfg.config(), &http);

    // 注入的是真实执行器(回传响应头 + 接受请求头),而非只有 mock 可用;
    // 不发起真实网络请求(离线),仅验证构造路径已接通。
    try testing.expect(svc.executor.vtable.execute_ex != null);
    try testing.expect(svc.executor.vtable.execute_with_headers != null);
}
