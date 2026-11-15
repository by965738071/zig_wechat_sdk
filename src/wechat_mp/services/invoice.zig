//! 电子发票服务(请求体可逐字确定的子集) —— 对应 Java
//! `api.WxMpMerchantInvoiceService` + `api.impl.WxMpMerchantInvoiceServiceImpl`,
//! 端点常量取自 `enums/WxMpApiUrl.Invoice`。
//!
//! `WxMpMerchantInvoiceServiceImpl#doCommonInvoiceHttpPost`(impl:99-111):
//!   data==null → json="" (POST 空串);data!=null → json=gson.toJson(data);
//!   gson 用 FieldNamingPolicy.LOWER_CASE_WITH_UNDERSCORES,但 Map/JsonObject 的
//!   key 原样输出。逐字对照后只收录 body 无需读 bean 的 4 个端点:
//!   queryInvoiceInfo          QUERY_INVOICE_INFO          /card/invoice/queryinvoceinfo
//!     ImmutableMap.of("fpqqlsh",..,"nsrsbh",..) → {"fpqqlsh","nsrsbh"} → InvoiceResult(原样返回)
//!   getMerchantContactInfo    GET_CONTACT_SET_BIZ_ATTR     /card/invoice/setbizattr?action=get_contact
//!     data=null → POST "" (空串) → MerchantContactInfoWrapper(原样返回)
//!   getAuthPageSetting        GET_AUTH_FIELD_SET_BIZ_ATTR  /card/invoice/setbizattr?action=get_auth_field
//!     new JsonObject() → POST "{}" → InvoiceAuthPageSetting(原样返回)
//!   getMerchantInvoicePlatform GET_PAY_MCH_SET_BIZ_ATTR    /card/invoice/setbizattr?action=get_pay_mch
//!     new JsonObject() → POST "{}" → MerchantInvoicePlatformInfoWrapper(原样返回)
//!
//! 12 个方法全收录(逐字对照 impl,请求 bean 字段不建模者用原始 JSON 入参):
//!   getAuthPageUrl     GET_AUTH_URL      /card/invoice/getauthurl
//!     Java 内部先 wxMpCardService.getCardApiTicket() 塞 params 再序列化;
//!     Zig 侧 ticket 由调用方经 card.CardService.getCardApiTicket 取得后传入,
//!     这里解析 request_json(对象)并注入/覆盖 "ticket" 字段后 POST。
//!   getAuthData        GET_AUTH_DATA     /card/invoice/getauthdata(入参原样 POST)
//!   rejectInvoice      REJECT_INSERT     /card/invoice/rejectinsert
//!   makeOutInvoice     MAKE_OUT_INVOICE  /card/invoice/makeoutinvoice
//!   clearOutInvoice    CLEAR_OUT_INVOICE /card/invoice/clearoutinvoice
//!   setMerchantContactInfo     SET_CONTACT_SET_BIZ_ATTR   body={"contact":<入参>}
//!     (MerchantContactInfoWrapper 字段 contact)
//!   setAuthPageSetting         SET_AUTH_FIELD_SET_BIZ_ATTR body=入参原样(bean 直发,无 wrapper)
//!   setMerchantInvoicePlatform SET_PAY_MCH_SET_BIZ_ATTR   body={"paymch_info":<入参>}
//!     (MerchantInvoicePlatformInfoWrapper 字段 paymchInfo →
//!     LOWER_CASE_WITH_UNDERSCORES 输出 paymch_info)
//! Invoice*Request/MerchantContactInfo/InvoiceAuthPageSetting/
//! MerchantInvoicePlatformInfo 等 bean 字段不建模,调用方拼 JSON
//! (与 card.zig createLandingPage 的 card_list_json 同口径);reject/makeOut/
//! clearOut/set* 返回 Done(void)。
//! 报销方 4 端点见 reimburse.zig(WxMpReimburseInvoiceService,请求 bean 字段
//! 可逐字确定,已完整建模)。
//! 返回 WxResult([]u8):原样返回响应 body(调用方 free),bean 字段级解析留待后续。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 把 ticket 注入请求 JSON 顶层对象(对应 Java `params.setTicket(ticket)` 后
/// gson 序列化;键序无协议意义,已存在则覆盖)。request_json 必须是 JSON 对象;
/// 树在解析 arena 上改写,避免与 Parsed 的释放责任交叉。
fn injectTicket(gpa: std.mem.Allocator, ticket: []const u8, request_json: []const u8) WxResult([]u8) {
    var parsed = json_util.parse(gpa, request_json) catch
        return .{ .err = result_mod.WxError.internal(gpa, "invoice auth page request must be a json object", .{}) };
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    switch (parsed.value) {
        .object => |*o| {
            o.put(arena, "ticket", .{ .string = ticket }) catch
                return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        },
        else => return .{ .err = result_mod.WxError.internal(gpa, "invoice auth page request must be a json object", .{}) },
    }
    const out = json_util.stringify(gpa, parsed.value) catch
        return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
    return .{ .ok = out };
}

pub const InvoiceService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *InvoiceService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 对应 `WxMpMerchantInvoiceServiceImpl#queryInvoiceInfo`(impl:56-60):
    /// ImmutableMap.of("fpqqlsh", .., "nsrsbh", ..)。
    pub fn queryInvoiceInfo(self: *InvoiceService, io: std.Io, fpqqlsh: []const u8, nsrsbh: []const u8) WxResult([]u8) {
        return self.post(io, .invoice_query_info, .{ .fpqqlsh = fpqqlsh, .nsrsbh = nsrsbh });
    }

    /// 对应 `WxMpMerchantInvoiceServiceImpl#getMerchantContactInfo`(impl:67-71):
    /// doCommonInvoiceHttpPost(data=null) → json="" → POST 空串。
    pub fn getMerchantContactInfo(self: *InvoiceService, io: std.Io) WxResult([]u8) {
        return h.apiPost(self.svc, io, service_mod.ApiUrl.invoice_get_contact.asUri(), "");
    }

    /// 对应 `WxMpMerchantInvoiceServiceImpl#getAuthPageSetting`(impl:78-81):
    /// new JsonObject() → gson.toJson → "{}"。
    pub fn getAuthPageSetting(self: *InvoiceService, io: std.Io) WxResult([]u8) {
        return h.apiPost(self.svc, io, service_mod.ApiUrl.invoice_get_auth_field.asUri(), "{}");
    }

    /// 对应 `WxMpMerchantInvoiceServiceImpl#getMerchantInvoicePlatform`(impl:90-94):
    /// new JsonObject() → "{}"。
    pub fn getMerchantInvoicePlatform(self: *InvoiceService, io: std.Io) WxResult([]u8) {
        return h.apiPost(self.svc, io, service_mod.ApiUrl.invoice_get_pay_mch.asUri(), "{}");
    }

    /// 对应 `getAuthPageUrl(InvoiceAuthPageRequest)`(impl:31-35):Java 先取
    /// card api ticket 塞 params 再序列化;Zig 侧 ticket 由调用方经
    /// `card.CardService.getCardApiTicket` 取得后传入,这里解析 request_json
    /// 并注入 "ticket" 字段。响应原样返回。
    pub fn getAuthPageUrl(self: *InvoiceService, io: std.Io, ticket: []const u8, request_json: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = switch (injectTicket(gpa, ticket, request_json)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, service_mod.ApiUrl.invoice_get_auth_url.asUri(), body);
    }

    /// 对应 `getAuthData(InvoiceAuthDataRequest)`(impl:37-40):
    /// 请求 bean 字段不建模,调用方拼 JSON,原样 POST;响应原样返回。
    pub fn getAuthData(self: *InvoiceService, io: std.Io, request_json: []const u8) WxResult([]u8) {
        return h.apiPost(self.svc, io, service_mod.ApiUrl.invoice_get_auth_data.asUri(), request_json);
    }

    /// 对应 `rejectInvoice(InvoiceRejectRequest)`(impl:42-45)。
    pub fn rejectInvoice(self: *InvoiceService, io: std.Io, request_json: []const u8) Done {
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_reject_insert.asUri(), request_json);
    }

    /// 对应 `makeOutInvoice(MakeOutInvoiceRequest)`(impl:47-50)。
    pub fn makeOutInvoice(self: *InvoiceService, io: std.Io, request_json: []const u8) Done {
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_make_out_invoice.asUri(), request_json);
    }

    /// 对应 `clearOutInvoice(ClearOutInvoiceRequest)`(impl:52-55)。
    pub fn clearOutInvoice(self: *InvoiceService, io: std.Io, request_json: []const u8) Done {
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_clear_out_invoice.asUri(), request_json);
    }

    /// 对应 `setMerchantContactInfo(MerchantContactInfo)`(impl:62-65):
    /// Java 包一层 MerchantContactInfoWrapper → gson 输出 `{"contact":{...}}`。
    pub fn setMerchantContactInfo(self: *InvoiceService, io: std.Io, contact_json: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"contact\":{s}}}", .{contact_json}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_set_contact.asUri(), body);
    }

    /// 对应 `setAuthPageSetting(InvoiceAuthPageSetting)`(impl:73-76):
    /// bean 本体直接序列化,无 wrapper —— 入参原样 POST。
    pub fn setAuthPageSetting(self: *InvoiceService, io: std.Io, setting_json: []const u8) Done {
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_set_auth_field.asUri(), setting_json);
    }

    /// 对应 `setMerchantInvoicePlatform(MerchantInvoicePlatformInfo)`(impl:84-88):
    /// wrapper → `{"paymch_info":{...}}`(字段名取 LOWER_CASE_WITH_UNDERSCORES)。
    pub fn setMerchantInvoicePlatform(self: *InvoiceService, io: std.Io, paymch_info_json: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"paymch_info\":{s}}}", .{paymch_info_json}) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_set_pay_mch.asUri(), body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:4 端点 URL(含 ?action= 后缀)/method/请求体
// (逐字对照 WxMpApiUrl.Invoice + WxMpMerchantInvoiceServiceImpl)
// ---------------------------------------------------------------------------

test "Invoice 契约: 4 端点 URL/method/请求体 (WxMpApiUrl.Invoice)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/invoice/", .response = "{\"errcode\":0,\"invoice_status\":\"DONE\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = InvoiceService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 QUERY_INVOICE_INFO: {"fpqqlsh","nsrsbh"} —— 字段名取自 impl 的 ImmutableMap
    switch (svc.queryInvoiceInfo(io, "FP1", "NSR1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"errcode\":0") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedInvoiceQuery;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/queryinvoceinfo") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"fpqqlsh\":\"FP1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"nsrsbh\":\"NSR1\"") != null);

    // 2 GET_CONTACT_SET_BIZ_ATTR: POST 空串(data=null),URL 带 ?action=get_contact
    switch (svc.getMerchantContactInfo(io)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedInvoiceContact;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=get_contact") != null);
    try testing.expectEqualStrings("", mock.body()); // data=null → json=""

    // 3 GET_AUTH_FIELD_SET_BIZ_ATTR: POST "{}" (new JsonObject())
    switch (svc.getAuthPageSetting(io)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedInvoiceAuthField;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=get_auth_field") != null);
    try testing.expectEqualStrings("{}", mock.body()); // new JsonObject() → "{}"

    // 4 GET_PAY_MCH_SET_BIZ_ATTR: POST "{}" (new JsonObject())
    switch (svc.getMerchantInvoicePlatform(io)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedInvoicePayMch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=get_pay_mch") != null);
    try testing.expectEqualStrings("{}", mock.body());

    // 4 个端点各一次 POST;URL 常量里的 ?action= 与 access_token 用 & 追加共存
    try testing.expectEqual(@as(usize, 4), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "action=get_pay_mch&access_token=TOK") != null);
}

test "Invoice 契约: 8 个写/查端点 + ticket 注入 (WxMpApiUrl.Invoice)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/invoice/", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = InvoiceService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 GET_AUTH_URL:ticket 注入到请求 JSON 顶层
    switch (svc.getAuthPageUrl(io, "APITKT", "{\"biz_id\":\"B1\"}")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"errcode\":0") != null);
        },
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/getauthurl") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"biz_id\":\"B1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"ticket\":\"APITKT\"") != null);

    // 2 GET_AUTH_DATA:入参原样 POST
    switch (svc.getAuthData(io, "{\"skey\":\"K\"}")) {
        .ok => |raw| gpa.free(raw),
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/getauthdata") != null);
    try testing.expectEqualStrings("{\"skey\":\"K\"}", mock.body());

    // 3-5 reject/makeOut/clearOut:入参原样,Done
    switch (svc.rejectInvoice(io, "{\"card_id\":\"C\"}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/rejectinsert") != null);
    try testing.expectEqualStrings("{\"card_id\":\"C\"}", mock.body());

    switch (svc.makeOutInvoice(io, "{\"fpqqlsh\":\"X\"}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/makeoutinvoice") != null);
    try testing.expectEqualStrings("{\"fpqqlsh\":\"X\"}", mock.body());

    switch (svc.clearOutInvoice(io, "{\"card_id\":\"C2\"}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/clearoutinvoice") != null);
    try testing.expectEqualStrings("{\"card_id\":\"C2\"}", mock.body());

    // 6 SET_CONTACT:wrapper → {"contact":{...}}
    switch (svc.setMerchantContactInfo(io, "{\"phone\":\"P\"}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=set_contact") != null);
    try testing.expectEqualStrings("{\"contact\":{\"phone\":\"P\"}}", mock.body());

    // 7 SET_AUTH_FIELD:bean 直发,无 wrapper
    switch (svc.setAuthPageSetting(io, "{\"auth_field\":{\"user_field\":{}}}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=set_auth_field") != null);
    try testing.expectEqualStrings("{\"auth_field\":{\"user_field\":{}}}", mock.body());

    // 8 SET_PAY_MCH:wrapper → {"paymch_info":{...}}
    switch (svc.setMerchantInvoicePlatform(io, "{\"appid\":\"A\"}")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/setbizattr?action=set_pay_mch") != null);
    try testing.expectEqualStrings("{\"paymch_info\":{\"appid\":\"A\"}}", mock.body());

    try testing.expectEqual(@as(usize, 8), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "action=set_pay_mch&access_token=TOK") != null);
}
