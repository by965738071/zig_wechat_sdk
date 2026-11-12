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
//!
//! 未收录(下一轮):createQrcodeCard/createLandingPage/createCard 等 body 为复杂 bean/
//! 多层嵌套对象的端点;getCardApiTicket + createCardApiSignature 依赖真实 api ticket
//! (GET /cgi-bin/ticket/getticket)与 SHA1 签名,归入「含真实凭证依赖、不可离线测」,不伪造。
//! 返回 WxResult([]u8) 的端点与 Java 返回 String 的方法同口径:原样返回响应 body。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

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
};

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
