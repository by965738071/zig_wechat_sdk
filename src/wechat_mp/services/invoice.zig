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
//! 未收录(下一轮,共 12 个):getAuthPageUrl(依赖 wxMpCardService.getCardApiTicket()
//! → 真实 api ticket GET,不可离线测)、getAuthData/rejectInvoice/makeOutInvoice/
//! clearOutInvoice/set* 系列(请求体来自 Invoice*Request/Info bean,需逐字读
//! @SerializedName)、reimburse 4 端点(WxMpReimburseInvoiceServiceImpl,body =
//! request.toJson(),需逐字读 reimburse bean)。均不编造字段、不伪造凭证。
//! 返回 WxResult([]u8):原样返回响应 body(调用方 free),bean 字段级解析留待下一轮。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;

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
