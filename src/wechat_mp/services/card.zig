//! 卡券服务(纯 JSON 子集) —— 对应 Java `api.WxMpCardService` +
//! `api.impl.WxMpCardServiceImpl`,端点常量取自 `enums/WxMpApiUrl.Card`。
//!
//! 样板见 `services/user.zig`,复用 `sub_util.zig`。逐字对照 WxMpCardServiceImpl
//! (全部 POST;只收录纯拼 JSON、不需图片上传/不需 api ticket 的端点):
//!   decryptCardCode   CARD_CODE_DECRYPT     /card/code/decrypt
//!                     {"encrypt_code"} → getAsJsonPrimitive("code")
//!   queryCardCode     CARD_CODE_GET         /card/code/get
//!                     {"card_id","code","check_consume"} → WxMpCardResult(原样返回)
//!   consumeCardCode   CARD_CODE_CONSUME     /card/code/consume
//!                     {"code"[,"card_id"?]} → 原样返回 String
//!   markCardCode      CARD_CODE_MARK        /card/code/mark
//!                     {"code","card_id","openid","is_mark"} → void(Java 仅解析 log)
//!   getCardDetail     CARD_GET              /card/get
//!                     {"card_id"} → 原样返回 String(Java 校验 errcode 后返回 responseContent)
//!   addTestWhiteList  CARD_TEST_WHITELIST   /card/testwhitelist/set
//!                     {"openid":[...]} → 原样返回 String
//!   unavailableCardCode CARD_CODE_UNAVAILABLE /card/code/unavailable
//!                     {"card_id","code","reason"} → 原样返回 String
//!   deleteCard        CARD_DELETE           /card/delete
//!                     {"card_id"} → WxMpCardDeleteResult(原样返回)
//!   cardCodeDeposit   CARD_CODE_DEPOSIT     /card/code/deposit
//!                     {"card_id","code":[...]} → 原样返回
//!   cardCodeDepositCount CARD_CODE_DEPOSIT_COUNT /card/code/getdepositcount
//!                     {"card_id"} → 原样返回
//!   cardCodeCheckcode CARD_CODE_CHECKCODE   /card/code/checkcode
//!                     {"card_id","code":[...]} → 原样返回
//!   cardModifyStock   CARD_MODIFY_STOCK     /card/modifystock
//!                     {"card_id","increase_stock_value"|"reduce_stock_value"} → void
//!   cardCodeUpdate    CARD_CODE_UPDATE      /card/code/update
//!                     {"card_id","code","new_code"} → void
//!   cardPaycellSet    CARD_PAYCELL_SET      /card/paycell/set
//!                     {"card_id","is_open"} → void
//!   cardMpnewsGethtml CARD_MPNEWS_GETHTML   /card/mpnews/gethtml
//!                     {"card_id"} → WxMpCardMpnewsGethtmlResult(原样返回;bean 字段 @SerializedName("content"))
//!   cardSelfConsumeCellSet CARD_SELF_CONSUME_CELL_SET /card/selfconsumecell/set
//!                     {"card_id","is_open","need_verify_cod","need_remark_amount"} → void
//!   getUserCardList   CARD_USER_CARD_LIST   /card/user/getcardlist
//!                     {"openid","card_id"} → WxUserCardListResult(原样返回;bean 字段 @SerializedName("card_list")/"has_share_card")
//!   getCardApiTicket  CARD_GET_TICKET      /cgi-bin/ticket/getticket?type=wx_card
//!                     (GET,SimpleGetRequestExecutor)→ ticket
//!   createCardApiSignature         (无端点;本地计算)
//!                     signParams = optional ++ [timestamp,nonceStr,cardApiTicket]
//!                     → Arrays.sort → **无分隔符拼接** → SHA1 小写 hex
//!                     → WxCardApiSignature{timestamp,nonceStr,signature}
//!   createQrcodeCard  CARD_QRCODE_CREATE   /card/qrcode/create
//!                     {"action_name":"QR_CARD","expire_seconds"?(>0 才发),
//!                      "action_info":{"card":{"openid"?,"code"?,
//!                      "is_unique_code","card_id","outer_str"}}}
//!                     → WxMpCardQrcodeCreateResult(ticket/expire_seconds/url/show_qrcode_url)
//!                     (Java 3 个重载 → QrcodeOptions 默认值表达)
//!   createLandingPage CARD_LANDING_PAGE_CREATE /card/landingpage/create
//!                     {"banner","page_title","can_share","scene","card_list":<数组>}
//!                     → WxMpCardLandingPageCreateResult(url/page_id)
//!
//! Java↔Zig 差异:
//!   - getCardApiTicket:Java 按 TicketType.WX_CARD 槽缓存(expireTicket/
//!     isTicketExpired/updateTicket + 锁);Zig 侧 config 仅 jsapi ticket 槽,
//!     本版每次现取不缓存,`force_refresh` 参数保留但不生效
//!     (Java forceRefresh=false 时若缓存未过期也走缓存,不现取——语义差异见上);
//!   - createLandingPage 的 card_list:Java JsonArray → 原始 JSON 数组文本
//!     `card_list_json`(调用方拼接,原样内嵌,不做转义);
//!   - createCard/createCardSeries 等请求体为大型复杂 bean(WxMpCardCreateRequest
//!     全字段嵌套)仍未收录,后续按需补。返回 WxResult([]u8) 的端点与 Java 返回
//!     String 的方法同口径:原样返回响应 body。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const api_url = @import("../api_url.zig");
const sha1 = @import("common").crypt.sha1;
const random_mod = @import("common").random;
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

fn oom(gpa: std.mem.Allocator) result_mod.WxError {
    return result_mod.WxError.internal(gpa, "oom", .{});
}

fn strOf(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) ![]u8 {
    return gpa.dupe(u8, json_util.getStrOr(v, key, ""));
}

/// card_list 原样内嵌的手写 JSON 转义写串(与 `datacube.zig` 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

pub const CardService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *CardService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,errcode==0 即完成。
    fn postDone(self: *CardService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    /// 对应 `WxMpCardServiceImpl#decryptCardCode`(impl:100-108):{"encrypt_code"} → "code"。
    pub fn decryptCardCode(self: *CardService, io: std.Io, encrypt_code: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const resp = switch (self.post(io, .card_code_decrypt, .{ .encrypt_code = encrypt_code })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.strField(gpa, resp, "code");
    }

    /// 对应 `WxMpCardServiceImpl#queryCardCode`(impl:110-121)。
    pub fn queryCardCode(self: *CardService, io: std.Io, card_id: []const u8, code: []const u8, check_consume: bool) WxResult([]u8) {
        return self.post(io, .card_code_get, .{
            .card_id = card_id,
            .code = code,
            .check_consume = check_consume,
        });
    }

    /// 对应 `WxMpCardServiceImpl#consumeCardCode`(impl:128-138):
    /// `card_id` 仅在非空时 addProperty,故用 ObjectBuilder 表达可选字段。
    pub fn consumeCardCode(self: *CardService, io: std.Io, code: []const u8, card_id: ?[]const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("code", code) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        if (card_id) |c| ob.putStr("card_id", c) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, service_mod.ApiUrl.card_code_consume.asUri(), body);
    }

    /// 对应 `WxMpCardServiceImpl#markCardCode`(impl:140-155)。
    pub fn markCardCode(self: *CardService, io: std.Io, code: []const u8, card_id: []const u8, openid: []const u8, is_mark: bool) Done {
        return self.postDone(io, .card_code_mark, .{
            .code = code,
            .card_id = card_id,
            .openid = openid,
            .is_mark = is_mark,
        });
    }

    /// 对应 `WxMpCardServiceImpl#getCardDetail`(impl:157-174)。
    pub fn getCardDetail(self: *CardService, io: std.Io, card_id: []const u8) WxResult([]u8) {
        return self.post(io, .card_get, .{ .card_id = card_id });
    }

    /// 对应 `WxMpCardServiceImpl#addTestWhiteList`(impl:176-183):
    /// JsonArray 加单个 openid → {"openid":[openid]}。
    pub fn addTestWhiteList(self: *CardService, io: std.Io, openid: []const u8) WxResult([]u8) {
        return self.post(io, .card_test_whitelist, .{ .openid = [_][]const u8{openid} });
    }

    /// 对应 `WxMpCardServiceImpl#unavailableCardCode`(impl:235-245)。
    pub fn unavailableCardCode(self: *CardService, io: std.Io, card_id: []const u8, code: []const u8, reason: []const u8) WxResult([]u8) {
        return self.post(io, .card_code_unavailable, .{
            .card_id = card_id,
            .code = code,
            .reason = reason,
        });
    }

    /// 对应 `WxMpCardServiceImpl#deleteCard`(impl:247-254)。
    pub fn deleteCard(self: *CardService, io: std.Io, card_id: []const u8) WxResult([]u8) {
        return self.post(io, .card_delete, .{ .card_id = card_id });
    }

    /// 对应 `WxMpCardServiceImpl#cardCodeDeposit`(impl:257-270):{"card_id","code":[...]}。
    pub fn cardCodeDeposit(self: *CardService, io: std.Io, card_id: []const u8, code_list: []const []const u8) WxResult([]u8) {
        return self.post(io, .card_code_deposit, .{ .card_id = card_id, .code = code_list });
    }

    /// 对应 `WxMpCardServiceImpl#cardCodeDepositCount`(impl:273-280)。
    pub fn cardCodeDepositCount(self: *CardService, io: std.Io, card_id: []const u8) WxResult([]u8) {
        return self.post(io, .card_code_deposit_count, .{ .card_id = card_id });
    }

    /// 对应 `WxMpCardServiceImpl#cardCodeCheckcode`(impl:283-296):{"card_id","code":[...]}。
    pub fn cardCodeCheckcode(self: *CardService, io: std.Io, card_id: []const u8, code_list: []const []const u8) WxResult([]u8) {
        return self.post(io, .card_code_checkcode, .{ .card_id = card_id, .code = code_list });
    }

    /// 对应 `WxMpCardServiceImpl#cardModifyStock`(impl:309-320):
    /// changeValue>0 → increase_stock_value,否则 reduce_stock_value=Math.abs。
    pub fn cardModifyStock(self: *CardService, io: std.Io, card_id: []const u8, change_value: i64) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("card_id", card_id) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        if (change_value > 0) {
            ob.putInt("increase_stock_value", change_value) catch
                return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        } else {
            ob.putInt("reduce_stock_value", 0 - change_value) catch
                return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        }
        const body = ob.toJson() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.card_modify_stock.asUri(), body);
    }

    /// 对应 `WxMpCardServiceImpl#cardCodeUpdate`(impl:323-331):
    /// {"card_id","code":oldCode,"new_code":newCode}。
    pub fn cardCodeUpdate(self: *CardService, io: std.Io, card_id: []const u8, old_code: []const u8, new_code: []const u8) Done {
        return self.postDone(io, .card_code_update, .{
            .card_id = card_id,
            .code = old_code,
            .new_code = new_code,
        });
    }

    /// 对应 `WxMpCardServiceImpl#cardPaycellSet`(impl:334-341)。
    pub fn cardPaycellSet(self: *CardService, io: std.Io, card_id: []const u8, is_open: bool) Done {
        return self.postDone(io, .card_paycell_set, .{ .card_id = card_id, .is_open = is_open });
    }

    /// 对应 `WxMpCardServiceImpl#cardMpnewsGethtml`(impl:300-306):
    /// {"card_id"} → `WxMpCardMpnewsGethtmlResult.fromJson(response)`。
    /// 该 bean 仅 `@SerializedName("content")` 一个字段,按 Java 返回对象的口径
    /// 原样返回响应 body(与 queryCardCode/deleteCard 同口径,不臆造字段解析)。
    pub fn cardMpnewsGethtml(self: *CardService, io: std.Io, card_id: []const u8) WxResult([]u8) {
        return self.post(io, .card_mpnews_gethtml, .{ .card_id = card_id });
    }

    /// 对应 `WxMpCardServiceImpl#cardSelfConsumeCellSet`(impl:344-354):
    /// {"card_id","is_open","need_verify_cod","need_remark_amount"} → void。
    pub fn cardSelfConsumeCellSet(self: *CardService, io: std.Io, card_id: []const u8, is_open: bool, need_verify_cod: bool, need_remark_amount: bool) Done {
        return self.postDone(io, .card_self_consume_cell_set, .{
            .card_id = card_id,
            .is_open = is_open,
            .need_verify_cod = need_verify_cod,
            .need_remark_amount = need_remark_amount,
        });
    }

    /// 对应 `WxMpCardServiceImpl#getUserCardList`(impl:358-364):
    /// {"openid","card_id"} → `WxUserCardListResult.fromJson(response)`,原样返回 body。
    pub fn getUserCardList(self: *CardService, io: std.Io, openid: []const u8, card_id: []const u8) WxResult([]u8) {
        return self.post(io, .card_user_card_list, .{ .openid = openid, .card_id = card_id });
    }

    // -----------------------------------------------------------------------
    // api ticket + 签名(WxMpCardServiceImpl:22-67)
    // -----------------------------------------------------------------------

    /// 对应 `#getCardApiTicket(boolean)`(impl:31-61):GET CARD_GET_TICKET
    /// (SimpleGetRequestExecutor)→ ticket/expires_in。`force_refresh` 保留
    /// 但不生效:Zig config 仅 jsapi ticket 槽,本版每次现取(见头注释)。
    pub fn getCardApiTicket(self: *CardService, io: std.Io, force_refresh: bool) WxResult([]u8) {
        _ = force_refresh;
        const resp = switch (h.apiGet(self.svc, io, api_url.Card.card_get_ticket)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer self.svc.gpa.free(resp);
        // Java `tmpJsonObject.get("ticket").getAsString()` → h.strField
        return h.strField(self.svc.gpa, resp, "ticket");
    }

    /// 对应 Java bean `WxCardApiSignature` 的对外三字段
    /// (appId/cardId/cardType/locationId/code/openId 是调用方可选入参,不回传)。
    pub const ApiSignature = struct {
        gpa: std.mem.Allocator,
        timestamp: i64,
        nonce_str: []u8,
        signature: []u8,

        pub fn deinit(self: *ApiSignature) void {
            self.gpa.free(self.nonce_str);
            self.gpa.free(self.signature);
            self.* = undefined;
        }
    };

    /// 注入量(测试确定性):对应 Java 的 RandomUtils.getRandomStr() 与
    /// System.currentTimeMillis()/1000(生产传 null)。
    pub const Inject = struct { nonce_str: []const u8, timestamp: i64 };

    /// 对应 `#createCardApiSignature(String...)`(impl:63-89):
    /// signParams = optional ++ [timestamp, nonceStr, cardApiTicket] →
    /// Arrays.sort → **无分隔符拼接** → SHA1 小写 hex
    /// (`common.sha1.gen` 即排序+无分隔拼接+小写 hex,同构)。
    pub fn createCardApiSignature(self: *CardService, io: std.Io, optional_params: []const []const u8, inject: ?Inject) WxResult(ApiSignature) {
        const gpa = self.svc.gpa;
        const ticket = switch (self.getCardApiTicket(io, false)) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(ticket);

        var nonce_buf: [16]u8 = undefined;
        var ts: i64 = undefined;
        var nonce: []const u8 = undefined;
        if (inject) |inj| {
            nonce = inj.nonce_str;
            ts = inj.timestamp;
        } else {
            random_mod.randomStr(io, &nonce_buf) catch |e|
                return .{ .err = result_mod.WxError.transport(gpa, "nonce: {s}", .{@errorName(e)}) };
            nonce = &nonce_buf;
            ts = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        }
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{ts}) catch unreachable;

        const parts = gpa.alloc([]const u8, optional_params.len + 3) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(parts);
        @memcpy(parts[0..optional_params.len], optional_params);
        parts[optional_params.len] = ts_str;
        parts[optional_params.len + 1] = nonce;
        parts[optional_params.len + 2] = ticket;
        const signature = sha1.gen(gpa, parts) catch
            return .{ .err = oom(gpa) };
        errdefer gpa.free(signature);

        const nonce_copy = gpa.dupe(u8, nonce) catch
            return .{ .err = oom(gpa) };
        return .{ .ok = .{ .gpa = gpa, .timestamp = ts, .nonce_str = nonce_copy, .signature = signature } };
    }

    // -----------------------------------------------------------------------
    // 复杂嵌套端点(WxMpCardServiceImpl:169-238)
    // -----------------------------------------------------------------------

    /// 对应 Java `WxMpCardQrcodeCreateResult`(ticket/expire_seconds/url/
    /// show_qrcode_url;errcode/errmsg 由 Service 折叠,不建模)。
    pub const QrcodeCreateResult = struct {
        gpa: std.mem.Allocator,
        ticket: []u8,
        expire_seconds: i64,
        url: []u8,
        show_qrcode_url: []u8,

        pub fn deinit(self: *QrcodeCreateResult) void {
            self.gpa.free(self.ticket);
            self.gpa.free(self.url);
            self.gpa.free(self.show_qrcode_url);
            self.* = undefined;
        }

        pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !QrcodeCreateResult {
            return .{
                .gpa = gpa,
                .ticket = try strOf(gpa, v, "ticket"),
                .expire_seconds = json_util.getIntOr(v, "expire_seconds", 0),
                .url = try strOf(gpa, v, "url"),
                .show_qrcode_url = try strOf(gpa, v, "show_qrcode_url"),
            };
        }
    };

    /// Java 3 个 createQrcodeCard 重载的参数包(cardId/outerStr 必填,其余默认:
    /// expiresIn=0 不发 expire_seconds;openid/code=null 不入 body;
    /// isUniqueCode=false)。
    pub const QrcodeOptions = struct {
        expire_seconds: i64 = 0,
        openid: ?[]const u8 = null,
        code: ?[]const u8 = null,
        is_unique_code: bool = false,
    };

    /// 对应 `#createQrcodeCard(cardId,outerStr,expiresIn,openid,code,isUniqueCode)`
    /// (impl:199-231):三层嵌套 body(action_name/expire_seconds?/action_info.card)
    /// → POST CARD_QRCODE_CREATE → QrcodeCreateResult.fromJson。
    pub fn createQrcodeCard(self: *CardService, io: std.Io, card_id: []const u8, outer_str: []const u8, opts: QrcodeOptions) WxResult(QrcodeCreateResult) {
        const gpa = self.svc.gpa;
        // 一次性嵌套容器走 arena(字符串借用自入参)
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var card_map: json_util.ObjectMap = .empty;
        if (opts.openid) |o| card_map.put(a, "openid", .{ .string = o }) catch
            return .{ .err = oom(gpa) };
        if (opts.code) |c| card_map.put(a, "code", .{ .string = c }) catch
            return .{ .err = oom(gpa) };
        card_map.put(a, "is_unique_code", .{ .bool = opts.is_unique_code }) catch
            return .{ .err = oom(gpa) };
        card_map.put(a, "card_id", .{ .string = card_id }) catch
            return .{ .err = oom(gpa) };
        card_map.put(a, "outer_str", .{ .string = outer_str }) catch
            return .{ .err = oom(gpa) };
        var action_info: json_util.ObjectMap = .empty;
        action_info.put(a, "card", .{ .object = card_map }) catch
            return .{ .err = oom(gpa) };
        var root: json_util.ObjectMap = .empty;
        root.put(a, "action_name", .{ .string = "QR_CARD" }) catch
            return .{ .err = oom(gpa) };
        if (opts.expire_seconds > 0) root.put(a, "expire_seconds", .{ .integer = opts.expire_seconds }) catch
            return .{ .err = oom(gpa) };
        root.put(a, "action_info", .{ .object = action_info }) catch
            return .{ .err = oom(gpa) };
        // 必须传 Value(匿名 struct 会按字段序列化 ObjectMap 内部)
        const body = json_util.stringify(gpa, json_util.Value{ .object = root }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(body);

        const resp = switch (h.apiPost(self.svc, io, api_url.Card.card_qrcode_create, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "qrcode create response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = QrcodeCreateResult.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.transport(gpa, "qrcode create response parse failed", .{}) } };
    }

    /// 对应 Java bean `WxMpCardLandingPageCreateRequest`
    /// (banner/page_title/can_share/scene/card_list);card_list 是 JsonArray,
    /// Zig 侧传原始 JSON 数组文本 `card_list_json`(原样内嵌,不转义)。
    pub const LandingPageCreateRequest = struct {
        banner: []const u8,
        page_title: []const u8,
        can_share: bool = false,
        scene: []const u8,
        card_list_json: []const u8,
    };

    /// 对应 Java bean `WxMpCardLandingPageCreateResult`(url/page_id;
    /// errcode/errmsg 由 Service 折叠,不建模)。
    pub const LandingPageCreateResult = struct {
        gpa: std.mem.Allocator,
        url: []u8,
        page_id: i64,

        pub fn deinit(self: *LandingPageCreateResult) void {
            self.gpa.free(self.url);
            self.* = undefined;
        }

        pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !LandingPageCreateResult {
            return .{
                .gpa = gpa,
                .url = try strOf(gpa, v, "url"),
                .page_id = json_util.getIntOr(v, "page_id", 0),
            };
        }
    };

    /// 对应 `#createLandingPage(request)`(impl:233-238):
    /// POST CARD_LANDING_PAGE_CREATE → LandingPageCreateResult.fromJson。
    pub fn createLandingPage(self: *CardService, io: std.Io, req: LandingPageCreateRequest) WxResult(LandingPageCreateResult) {
        const gpa = self.svc.gpa;
        const body = landingPageBody(gpa, req) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Card.card_landing_page_create, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = result_mod.WxError.transport(gpa, "landingpage response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = LandingPageCreateResult.fromJson(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.transport(gpa, "landingpage response parse failed", .{}) } };
    }
};

/// 手写 body(字段序逐字对齐 Java bean 声明序):
/// {"banner":..,"page_title":..,"can_share":bool,"scene":..,"card_list":<原样内嵌>}。
fn landingPageBody(gpa: std.mem.Allocator, req: CardService.LandingPageCreateRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"banner\":");
    try jw.str(w, req.banner);
    try w.writeAll(",\"page_title\":");
    try jw.str(w, req.page_title);
    try w.writeAll(",\"can_share\":");
    try w.print("{}", .{req.can_share});
    try w.writeAll(",\"scene\":");
    try jw.str(w, req.scene);
    try w.writeAll(",\"card_list\":");
    try w.writeAll(req.card_list_json);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// 契约测试:14 端点 URL/method/请求体 + decryptCardCode 响应字段
// (逐字对照 WxMpApiUrl.Card + WxMpCardServiceImpl)
// ---------------------------------------------------------------------------

test "Card 契约: 14 端点 URL/method/请求体 + 响应字段 (WxMpApiUrl.Card)" {
    const gpa = testing.allocator;
    // 兜底响应:errcode=0 有效;含 decryptCardCode 的 "code"、bean 顶层 "card_id"。
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "/card/", .response = "{\"errcode\":0,\"code\":\"CODE123\",\"card_id\":\"CARD1\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = CardService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 CARD_CODE_DECRYPT: {"encrypt_code"} → "code"
    switch (svc.decryptCardCode(io, "ENC")) {
        .ok => |c| {
            defer gpa.free(c);
            try testing.expectEqualStrings("CODE123", c);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardDecrypt;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/decrypt") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"encrypt_code\":\"ENC\"") != null);

    // 2 CARD_CODE_GET: {"card_id","code","check_consume"}
    switch (svc.queryCardCode(io, "CARD1", "C1", true)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardCodeGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"code\":\"C1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"check_consume\":true") != null);

    // 3 CARD_CODE_CONSUME: {"code","card_id"} (带 card_id 分支)
    switch (svc.consumeCardCode(io, "C1", "CARD1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardConsume;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/consume") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"code\":\"C1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);

    // 3b CARD_CODE_CONSUME: 无 card_id → 不应出现 "card_id" 字段
    switch (svc.consumeCardCode(io, "C1", null)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardConsumeNull;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\"") == null);

    // 4 CARD_CODE_MARK: {"code","card_id","openid","is_mark"}
    switch (svc.markCardCode(io, "C1", "CARD1", "oABC", false)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardMark;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/mark") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_mark\":false") != null);

    // 5 CARD_GET: {"card_id"}
    switch (svc.getCardDetail(io, "CARD1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "/card/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);

    // 6 CARD_TEST_WHITELIST: {"openid":[openid]} (JsonArray)
    switch (svc.addTestWhiteList(io, "oABC")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardWhiteList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/testwhitelist/set") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":[\"oABC\"]") != null);

    // 7 CARD_CODE_UNAVAILABLE: {"card_id","code","reason"}
    switch (svc.unavailableCardCode(io, "CARD1", "C1", "作废")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardUnavailable;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"reason\":\"作废\"") != null);

    // 8 CARD_DELETE: {"card_id"}
    switch (svc.deleteCard(io, "CARD1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardDelete;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "/card/delete") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);

    // 9 CARD_CODE_DEPOSIT: {"card_id","code":[...]} (code 是数组)
    const codes = [_][]const u8{ "A1", "A2" };
    switch (svc.cardCodeDeposit(io, "CARD1", &codes)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardDeposit;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/deposit") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"code\":[\"A1\",\"A2\"]") != null);

    // 10 CARD_CODE_DEPOSIT_COUNT: {"card_id"} (注意 URL 是 getdepositcount)
    switch (svc.cardCodeDepositCount(io, "CARD1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardDepositCount;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/getdepositcount") != null);

    // 11 CARD_CODE_CHECKCODE: {"card_id","code":[...]}
    switch (svc.cardCodeCheckcode(io, "CARD1", &codes)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardCheckcode;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/checkcode") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"code\":[\"A1\",\"A2\"]") != null);

    // 12 CARD_MODIFY_STOCK increase 分支: changeValue>0 → increase_stock_value
    switch (svc.cardModifyStock(io, "CARD1", 5)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardModifyStockInc;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/modifystock") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"increase_stock_value\":5") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "reduce_stock_value") == null);

    // 12b CARD_MODIFY_STOCK reduce 分支: changeValue<=0 → reduce_stock_value=abs
    switch (svc.cardModifyStock(io, "CARD1", -3)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardModifyStockDec;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"reduce_stock_value\":3") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "increase_stock_value") == null);

    // 13 CARD_CODE_UPDATE: {"card_id","code","new_code"}
    switch (svc.cardCodeUpdate(io, "CARD1", "OLD", "NEW")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardCodeUpdate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/code/update") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"code\":\"OLD\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"new_code\":\"NEW\"") != null);

    // 14 CARD_PAYCELL_SET: {"card_id","is_open"}
    switch (svc.cardPaycellSet(io, "CARD1", true)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardPaycellSet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/paycell/set") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_open\":true") != null);

    // 14 端点 + consume(null 分支) + modifyStock(reduce 分支) = 16 次 POST
    try testing.expectEqual(@as(usize, 16), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}

// ---------------------------------------------------------------------------
// 契约测试:本轮新增 3 端点 URL/method/请求体 + 响应 bean 字段名
// (逐字对照 WxMpApiUrl.Card + WxMpCardServiceImpl + 两个结果 bean 的 @SerializedName)
// ---------------------------------------------------------------------------

test "Card 契约: 3 端点 (mpnewsGethtml/selfConsumeCellSet/userCardList)" {
    const gpa = testing.allocator;
    // 兜底响应含三个 bean 的响应字段名:content / card_list / has_share_card。
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "/card/", .response = "{\"errcode\":0,\"content\":\"<p>HTML</p>\",\"card_list\":[{\"code\":\"C1\"}],\"has_share_card\":true}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = CardService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 CARD_MPNEWS_GETHTML: POST {"card_id"} → 原样返回 body(bean 字段 content)
    switch (svc.cardMpnewsGethtml(io, "CARD1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"content\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardMpnews;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/mpnews/gethtml") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);

    // 2 CARD_SELF_CONSUME_CELL_SET: POST 四个字段(3 个 bool) → void
    switch (svc.cardSelfConsumeCellSet(io, "CARD1", true, false, true)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardSelfConsume;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/selfconsumecell/set") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_open\":true") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"need_verify_cod\":false") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"need_remark_amount\":true") != null);

    // 3 CARD_USER_CARD_LIST: POST {"openid","card_id"} → 原样返回 body
    //   (bean 字段 card_list / has_share_card)
    switch (svc.getUserCardList(io, "oABC", "CARD1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"card_list\"") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "\"has_share_card\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedCardUserList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/user/getcardlist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"oABC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"CARD1\"") != null);

    try testing.expectEqual(@as(usize, 3), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}

test "Card 契约: ticket/签名/QR_CARD/landingpage (WxMpCardServiceImpl:22-238)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/qrcode/create", .response = "{\"errcode\":0,\"ticket\":\"QR_TICKET\",\"expire_seconds\":120,\"url\":\"http://u\",\"show_qrcode_url\":\"http://q\"}" },
        .{ .match = "card/landingpage/create", .response = "{\"errcode\":0,\"url\":\"http://lp\",\"page_id\":9}" },
        .{ .match = "ticket/getticket", .response = "{\"errcode\":0,\"ticket\":\"CARD_TICKET\",\"expires_in\":7200}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = CardService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 CARD_GET_TICKET: GET → ticket(force_refresh 本版不生效,现取)
    switch (svc.getCardApiTicket(io, true)) {
        .ok => |t| {
            defer gpa.free(t);
            try testing.expectEqualStrings("CARD_TICKET", t);
        },
        .err => return error.UnexpectedTicket,
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/ticket/getticket?type=wx_card") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

    // 2 createCardApiSignature: optional ++ [ts,nonce,ticket] → sort → 无分隔拼接 SHA1
    var sig = switch (svc.createCardApiSignature(io, &.{ "APPID", "OPENID" }, .{
        .nonce_str = "NONCE",
        .timestamp = 1700000000,
    })) {
        .ok => |s| s,
        .err => return error.UnexpectedSignature,
    };
    defer sig.deinit();
    var expect_buf: [40]u8 = undefined;
    // 排序后 digits < 大写字母:1700000000 < APPID < CARD_TICKET < NONCE < OPENID
    // (用 hex 而非 gen 避免循环验证)
    const expected = sha1.hex(&expect_buf, "1700000000APPIDCARD_TICKETNONCEOPENID");
    try testing.expectEqualStrings(expected, sig.signature);
    try testing.expectEqual(@as(i64, 1700000000), sig.timestamp);
    try testing.expectEqualStrings("NONCE", sig.nonce_str);
    try testing.expectEqual(@as(usize, 2), mock.calls); // 签名内部又取了一次 ticket

    // 3 createQrcodeCard(全参数): QR_CARD + expire_seconds + action_info.card
    var qr = switch (svc.createQrcodeCard(io, "CARD_ID", "OUTER", .{
        .expire_seconds = 120,
        .openid = "oX",
        .code = "CD",
        .is_unique_code = true,
    })) {
        .ok => |r| r,
        .err => return error.UnexpectedQrcode,
    };
    defer qr.deinit();
    try testing.expectEqualStrings("QR_TICKET", qr.ticket);
    try testing.expectEqual(@as(i64, 120), qr.expire_seconds);
    try testing.expectEqualStrings("http://u", qr.url);
    try testing.expectEqualStrings("http://q", qr.show_qrcode_url);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/qrcode/create") != null);
    var body = mock.body();
    try testing.expect(std.mem.indexOf(u8, body, "\"action_name\":\"QR_CARD\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"expire_seconds\":120") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"openid\":\"oX\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"code\":\"CD\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"is_unique_code\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"card_id\":\"CARD_ID\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"outer_str\":\"OUTER\"") != null);

    // 4 createQrcodeCard(默认值): expire_seconds=0 不发,openid/code 缺省,is_unique_code:false
    var qr2 = switch (svc.createQrcodeCard(io, "CARD_ID", "OUTER", .{})) {
        .ok => |r| r,
        .err => return error.UnexpectedQrcode2,
    };
    defer qr2.deinit();
    body = mock.body();
    try testing.expect(std.mem.indexOf(u8, body, "expire_seconds") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"openid\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"code\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"is_unique_code\":false") != null);

    // 5 createLandingPage: 字段序逐字对齐 Java bean 声明序;card_list 原样内嵌
    var lp = switch (svc.createLandingPage(io, .{
        .banner = "BAN",
        .page_title = "TIT",
        .can_share = true,
        .scene = "SC",
        .card_list_json = "[{\"card_id\":\"C1\"}]",
    })) {
        .ok => |r| r,
        .err => return error.UnexpectedLandingPage,
    };
    defer lp.deinit();
    try testing.expectEqualStrings("http://lp", lp.url);
    try testing.expectEqual(@as(i64, 9), lp.page_id);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/landingpage/create") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"banner\":\"BAN\",\"page_title\":\"TIT\",\"can_share\":true,\"scene\":\"SC\",\"card_list\":[{\"card_id\":\"C1\"}]}") != null);

    // ticket + 签名内部 ticket + qr + qr2 + lp
    try testing.expectEqual(@as(usize, 5), mock.calls);
}
