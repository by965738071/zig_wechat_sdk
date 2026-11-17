//! 电子发票报销方服务 —— 对应 Java `api.WxMaReimburseInvoiceService` +
//! `api.impl.WxMaReimburseInvoiceServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Invoice`:
//! - getInvoiceInfo(InvoiceInfoRequest):POST card/invoice/reimburse/getinvoiceinfo
//!   → InvoiceInfoResponse;
//! - getInvoiceBatch(InvoiceBatchRequest):POST .../getinvoicebatch → item_list[]
//!   (Java `InvoiceInfoResponse.toList`,缺 item_list 时 Java 会 NPE,Zig 返回空列表);
//! - updateInvoiceStatus(UpdateInvoiceStatusRequest):POST .../updateinvoicestatus;
//! - updateStatusBatch(UpdateStatusBatchRequest):POST .../updatestatusbatch。
//!
//! errcode≠0 已由基座折叠为 `.err`;Java 响应对象里的 errcode/errmsg 载荷字段
//! 不再保留。文档:公众号电子发票报销方接口(与小程序同协议)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_INVOICE_INFO_URL = "https://api.weixin.qq.com/card/invoice/reimburse/getinvoiceinfo";
const GET_INVOICE_BATCH_URL = "https://api.weixin.qq.com/card/invoice/reimburse/getinvoicebatch";
const UPDATE_INVOICE_STATUS_URL = "https://api.weixin.qq.com/card/invoice/reimburse/updateinvoicestatus";
const UPDATE_STATUS_BATCH_URL = "https://api.weixin.qq.com/card/invoice/reimburse/updatestatusbatch";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- 请求 bean ------------------------------------------------------------------

/// 对应 `invoice.reimburse.InvoiceInfoRequest`(查询/更新共用单元)。
pub const InvoiceInfoRequest = struct {
    /// 发票卡券的 card_id。
    card_id: []const u8,
    /// 发票卡券的加密 code,和 card_id 共同构成一张发票卡券的唯一标识。
    encrypt_code: []const u8,

    pub fn to_json(self: InvoiceInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"card_id\":");
        try js(w, self.card_id);
        try w.writeAll(",\"encrypt_code\":");
        try js(w, self.encrypt_code);
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `invoice.reimburse.InvoiceBatchRequest`(批量查询)。
pub const InvoiceBatchRequest = struct {
    item_list: []const InvoiceInfoRequest,

    pub fn to_json(self: InvoiceBatchRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"item_list\":[");
        for (self.item_list, 0..) |item, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"card_id\":");
            try js(w, item.card_id);
            try w.writeAll(",\"encrypt_code\":");
            try js(w, item.encrypt_code);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

/// 对应 `invoice.reimburse.UpdateInvoiceStatusRequest`(更新发票状态)。
pub const UpdateInvoiceStatusRequest = struct {
    card_id: []const u8,
    encrypt_code: []const u8,
    /// 发票报销状态(INVOICE_REIMBURSE_INIT/INVOICE_REIMBURSE_LOCK/
    /// INVOICE_REIMBURSE_CONFIRM/INVOICE_REIMBURSE_RESTORE)。
    reimburse_status: []const u8,

    pub fn to_json(self: UpdateInvoiceStatusRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"card_id\":");
        try js(w, self.card_id);
        try w.writeAll(",\"encrypt_code\":");
        try js(w, self.encrypt_code);
        try w.writeAll(",\"reimburse_status\":");
        try js(w, self.reimburse_status);
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `invoice.reimburse.UpdateStatusBatchRequest`(批量更新状态)。
pub const UpdateStatusBatchRequest = struct {
    openid: []const u8,
    reimburse_status: []const u8,
    invoice_list: []const InvoiceInfoRequest,

    pub fn to_json(self: UpdateStatusBatchRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"reimburse_status\":");
        try js(w, self.reimburse_status);
        try w.writeAll(",\"invoice_list\":[");
        for (self.invoice_list, 0..) |item, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"card_id\":");
            try js(w, item.card_id);
            try w.writeAll(",\"encrypt_code\":");
            try js(w, item.encrypt_code);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

// --- 响应 bean ------------------------------------------------------------------

/// 对应 `invoice.reimburse.InvoiceCommodityInfo`(发票商品信息)。gpa 拥有。
pub const InvoiceCommodityInfo = struct {
    gpa: std.mem.Allocator,
    /// 项目(商品)名称。
    name: ?[]const u8,
    /// 项目数量。
    num: ?i64,
    /// 项目单位。
    unit: ?[]const u8,
    /// 单价,以分为单位。
    price: ?i64,

    pub fn deinit(self: *InvoiceCommodityInfo) void {
        const g = self.gpa;
        if (self.name) |s| g.free(@constCast(s));
        if (self.unit) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const InvoiceCommodityInfo) void {
        const g = self.gpa;
        if (self.name) |s| g.free(s);
        if (self.unit) |s| g.free(s);
    }
};

/// 对应 `invoice.reimburse.InvoiceUserInfo`(发票票面主要信息)。gpa 拥有。
pub const InvoiceUserInfo = struct {
    gpa: std.mem.Allocator,
    /// 发票加税合计金额,以分为单位。
    fee: ?i64,
    /// 发票的抬头。
    title: ?[]const u8,
    /// 开票时间。
    billing_time: ?i64,
    /// 发票代码。
    billing_no: ?[]const u8,
    /// 发票号码。
    billing_code: ?[]const u8,
    /// 不含税金额,以分为单位。
    fee_without_tax: ?i64,
    /// 税额,以分为单位。
    tax: ?i64,
    /// 发票对应的 PDF URL。
    pdf_url: ?[]const u8,
    /// 其它消费凭证附件对应的 URL。
    trip_pdf_url: ?[]const u8,
    /// 发票报销状态。
    reimburse_status: ?[]const u8,
    /// 校验码。
    check_code: ?[]const u8,
    /// 购买方纳税人识别号。
    buyer_number: ?[]const u8,
    /// 购买方地址、电话。
    buyer_address_and_phone: ?[]const u8,
    /// 购买方开户行及账号。
    buyer_bank_account: ?[]const u8,
    /// 销售方纳税人识别号。
    seller_number: ?[]const u8,
    /// 销售方地址、电话。
    seller_address_and_phone: ?[]const u8,
    /// 销售方开户行及账号。
    seller_bank_account: ?[]const u8,
    /// 备注。
    remarks: ?[]const u8,
    /// 收款人。
    cashier: ?[]const u8,
    /// 开票人。
    maker: ?[]const u8,
    /// 商品信息结构。
    info: []InvoiceCommodityInfo,

    pub fn deinit(self: *InvoiceUserInfo) void {
        const g = self.gpa;
        if (self.title) |s| g.free(@constCast(s));
        if (self.billing_no) |s| g.free(@constCast(s));
        if (self.billing_code) |s| g.free(@constCast(s));
        if (self.pdf_url) |s| g.free(@constCast(s));
        if (self.trip_pdf_url) |s| g.free(@constCast(s));
        if (self.reimburse_status) |s| g.free(@constCast(s));
        if (self.check_code) |s| g.free(@constCast(s));
        if (self.buyer_number) |s| g.free(@constCast(s));
        if (self.buyer_address_and_phone) |s| g.free(@constCast(s));
        if (self.buyer_bank_account) |s| g.free(@constCast(s));
        if (self.seller_number) |s| g.free(@constCast(s));
        if (self.seller_address_and_phone) |s| g.free(@constCast(s));
        if (self.seller_bank_account) |s| g.free(@constCast(s));
        if (self.remarks) |s| g.free(@constCast(s));
        if (self.cashier) |s| g.free(@constCast(s));
        if (self.maker) |s| g.free(@constCast(s));
        for (self.info) |*c| c.deinit();
        g.free(self.info);
    }

    pub fn deinitConst(self: *const InvoiceUserInfo) void {
        const g = self.gpa;
        if (self.title) |s| g.free(s);
        if (self.billing_no) |s| g.free(s);
        if (self.billing_code) |s| g.free(s);
        if (self.pdf_url) |s| g.free(s);
        if (self.trip_pdf_url) |s| g.free(s);
        if (self.reimburse_status) |s| g.free(s);
        if (self.check_code) |s| g.free(s);
        if (self.buyer_number) |s| g.free(s);
        if (self.buyer_address_and_phone) |s| g.free(s);
        if (self.buyer_bank_account) |s| g.free(s);
        if (self.seller_number) |s| g.free(s);
        if (self.seller_address_and_phone) |s| g.free(s);
        if (self.seller_bank_account) |s| g.free(s);
        if (self.remarks) |s| g.free(s);
        if (self.cashier) |s| g.free(s);
        if (self.maker) |s| g.free(s);
        for (self.info) |*c| c.deinitConst();
        g.free(self.info);
    }
};

/// 对应 `invoice.reimburse.InvoiceInfoResponse`(查询报销发票信息响应)。gpa 拥有。
pub const InvoiceInfo = struct {
    gpa: std.mem.Allocator,
    /// 发票 ID。
    card_id: ?[]const u8,
    /// 发票的有效期起始时间。
    begin_time: ?i64,
    /// 发票的有效期截止时间。
    end_time: ?i64,
    /// 用户标识。
    openid: ?[]const u8,
    /// 发票的类型。
    type: ?[]const u8,
    /// 发票的收款方。
    payee: ?[]const u8,
    /// 发票详情。
    detail: ?[]const u8,
    /// 用户可在发票票面看到的主要信息。
    user_info: ?InvoiceUserInfo,

    pub fn deinit(self: *InvoiceInfo) void {
        const g = self.gpa;
        if (self.card_id) |s| g.free(@constCast(s));
        if (self.openid) |s| g.free(@constCast(s));
        if (self.type) |s| g.free(@constCast(s));
        if (self.payee) |s| g.free(@constCast(s));
        if (self.detail) |s| g.free(@constCast(s));
        if (self.user_info) |*u| u.deinit();
    }

    pub fn deinitConst(self: *const InvoiceInfo) void {
        const g = self.gpa;
        if (self.card_id) |s| g.free(s);
        if (self.openid) |s| g.free(s);
        if (self.type) |s| g.free(s);
        if (self.payee) |s| g.free(s);
        if (self.detail) |s| g.free(s);
        if (self.user_info) |*u| u.deinitConst();
    }
};

// --- 响应解析 -------------------------------------------------------------------

fn parseCommodity(gpa: std.mem.Allocator, obj: std.json.Value) !InvoiceCommodityInfo {
    var c = InvoiceCommodityInfo{ .gpa = gpa, .name = null, .num = null, .unit = null, .price = null };
    errdefer c.deinit();
    if (json_util.getStr(obj, "name")) |s| c.name = try gpa.dupe(u8, s);
    c.num = json_util.getInt(obj, "num");
    if (json_util.getStr(obj, "unit")) |s| c.unit = try gpa.dupe(u8, s);
    c.price = json_util.getInt(obj, "price");
    return c;
}

fn parseUserInfo(gpa: std.mem.Allocator, obj: std.json.Value) !InvoiceUserInfo {
    var u = InvoiceUserInfo{
        .gpa = gpa,
        .fee = null,
        .title = null,
        .billing_time = null,
        .billing_no = null,
        .billing_code = null,
        .fee_without_tax = null,
        .tax = null,
        .pdf_url = null,
        .trip_pdf_url = null,
        .reimburse_status = null,
        .check_code = null,
        .buyer_number = null,
        .buyer_address_and_phone = null,
        .buyer_bank_account = null,
        .seller_number = null,
        .seller_address_and_phone = null,
        .seller_bank_account = null,
        .remarks = null,
        .cashier = null,
        .maker = null,
        .info = &[_]InvoiceCommodityInfo{},
    };
    errdefer u.deinit();
    u.fee = json_util.getInt(obj, "fee");
    if (json_util.getStr(obj, "title")) |s| u.title = try gpa.dupe(u8, s);
    u.billing_time = json_util.getInt(obj, "billing_time");
    if (json_util.getStr(obj, "billing_no")) |s| u.billing_no = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "billing_code")) |s| u.billing_code = try gpa.dupe(u8, s);
    u.fee_without_tax = json_util.getInt(obj, "fee_without_tax");
    u.tax = json_util.getInt(obj, "tax");
    if (json_util.getStr(obj, "pdf_url")) |s| u.pdf_url = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "trip_pdf_url")) |s| u.trip_pdf_url = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "reimburse_status")) |s| u.reimburse_status = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "check_code")) |s| u.check_code = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "buyer_number")) |s| u.buyer_number = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "buyer_address_and_phone")) |s| u.buyer_address_and_phone = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "buyer_bank_account")) |s| u.buyer_bank_account = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "seller_number")) |s| u.seller_number = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "seller_address_and_phone")) |s| u.seller_address_and_phone = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "seller_bank_account")) |s| u.seller_bank_account = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "remarks")) |s| u.remarks = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "cashier")) |s| u.cashier = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "maker")) |s| u.maker = try gpa.dupe(u8, s);
    if (json_util.getArray(obj, "info")) |arr| {
        const list = try gpa.alloc(InvoiceCommodityInfo, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*c| c.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseCommodity(gpa, item);
            filled += 1;
        }
        u.info = list;
    }
    return u;
}

fn parseInvoiceInfo(gpa: std.mem.Allocator, obj: std.json.Value) !InvoiceInfo {
    var inv = InvoiceInfo{
        .gpa = gpa,
        .card_id = null,
        .begin_time = null,
        .end_time = null,
        .openid = null,
        .type = null,
        .payee = null,
        .detail = null,
        .user_info = null,
    };
    errdefer inv.deinit();
    if (json_util.getStr(obj, "card_id")) |s| inv.card_id = try gpa.dupe(u8, s);
    inv.begin_time = json_util.getInt(obj, "begin_time");
    inv.end_time = json_util.getInt(obj, "end_time");
    if (json_util.getStr(obj, "openid")) |s| inv.openid = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "type")) |s| inv.type = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "payee")) |s| inv.payee = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "detail")) |s| inv.detail = try gpa.dupe(u8, s);
    if (json_util.getObject(obj, "user_info")) |uv| inv.user_info = try parseUserInfo(gpa, uv);
    return inv;
}

// --- service ----------------------------------------------------------------------

pub const ReimburseInvoiceService = struct {
    svc: *mp_service.Service,

    /// 对应 `getInvoiceInfo(InvoiceInfoRequest)`:POST getinvoiceinfo → 单张发票。
    pub fn getInvoiceInfo(self: *ReimburseInvoiceService, io: std.Io, req: InvoiceInfoRequest) WxResult(InvoiceInfo) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_INVOICE_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getinvoiceinfo not json", .{}) };
        defer parsed.deinit();
        const inv = parseInvoiceInfo(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = inv };
    }

    /// 对应 `getInvoiceBatch(InvoiceBatchRequest)`:POST getinvoicebatch
    /// → item_list[](Java toList;响应缺 item_list 时 Java 直接 NPE,此处从宽
    /// 返回空列表)。调用方负责逐个 deinit 后 free 切片。
    pub fn getInvoiceBatch(self: *ReimburseInvoiceService, io: std.Io, req: InvoiceBatchRequest) WxResult([]InvoiceInfo) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_INVOICE_BATCH_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getinvoicebatch not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "item_list") orelse
            return .{ .ok = &[_]InvoiceInfo{} };
        const list = gpa.alloc(InvoiceInfo, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        for (arr.items) |item| {
            list[filled] = parseInvoiceInfo(gpa, item) catch {
                for (list[0..filled]) |*x| x.deinit();
                gpa.free(list);
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
            filled += 1;
        }
        return .{ .ok = list };
    }

    /// 对应 `updateInvoiceStatus(UpdateInvoiceStatusRequest)`:
    /// POST updateinvoicestatus。
    pub fn updateInvoiceStatus(self: *ReimburseInvoiceService, io: std.Io, req: UpdateInvoiceStatusRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_INVOICE_STATUS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `updateStatusBatch(UpdateStatusBatchRequest)`:
    /// POST updatestatusbatch。
    pub fn updateStatusBatch(self: *ReimburseInvoiceService, io: std.Io, req: UpdateStatusBatchRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_STATUS_BATCH_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "reimburse invoice get/update" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "updateinvoicestatus", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "getinvoiceinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"card_id\":\"CARD1\",\"begin_time\":1700000000,\"end_time\":1800000000,\"openid\":\"OPENID\",\"type\":\"增值税普通发票\",\"payee\":\"收款方\",\"detail\":\"明细\",\"user_info\":{\"fee\":9900,\"title\":\"抬头\",\"billing_time\":1700000100,\"billing_no\":\"NO1\",\"billing_code\":\"CODE1\",\"fee_without_tax\":8800,\"tax\":1100,\"pdf_url\":\"https://pdf\",\"reimburse_status\":\"INVOICE_REIMBURSE_INIT\",\"info\":[{\"name\":\"商品A\",\"num\":2,\"unit\":\"个\",\"price\":4950}]}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ReimburseInvoiceService{ .svc = &base };

    // getInvoiceInfo:POST {card_id,encrypt_code},解析嵌套 user_info/info
    var got = switch (s.getInvoiceInfo(io, .{ .card_id = "CARD1", .encrypt_code = "ENC1" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "card/invoice/reimburse/getinvoiceinfo") != null);
    try std.testing.expectEqualStrings("{\"card_id\":\"CARD1\",\"encrypt_code\":\"ENC1\"}", m.last_body);
    try std.testing.expectEqualStrings("CARD1", got.card_id.?);
    try std.testing.expectEqual(@as(i64, 1700000000), got.begin_time.?);
    try std.testing.expectEqual(@as(i64, 1800000000), got.end_time.?);
    try std.testing.expectEqualStrings("OPENID", got.openid.?);
    try std.testing.expectEqualStrings("增值税普通发票", got.type.?);
    try std.testing.expectEqualStrings("收款方", got.payee.?);
    try std.testing.expectEqualStrings("明细", got.detail.?);
    const ui = got.user_info.?;
    try std.testing.expectEqual(@as(i64, 9900), ui.fee.?);
    try std.testing.expectEqualStrings("抬头", ui.title.?);
    try std.testing.expectEqual(@as(i64, 1700000100), ui.billing_time.?);
    try std.testing.expectEqualStrings("NO1", ui.billing_no.?);
    try std.testing.expectEqualStrings("CODE1", ui.billing_code.?);
    try std.testing.expectEqual(@as(i64, 8800), ui.fee_without_tax.?);
    try std.testing.expectEqual(@as(i64, 1100), ui.tax.?);
    try std.testing.expectEqualStrings("https://pdf", ui.pdf_url.?);
    try std.testing.expectEqualStrings("INVOICE_REIMBURSE_INIT", ui.reimburse_status.?);
    try std.testing.expectEqual(@as(usize, 1), ui.info.len);
    try std.testing.expectEqualStrings("商品A", ui.info[0].name.?);
    try std.testing.expectEqual(@as(i64, 2), ui.info[0].num.?);
    try std.testing.expectEqualStrings("个", ui.info[0].unit.?);
    try std.testing.expectEqual(@as(i64, 4950), ui.info[0].price.?);

    // updateInvoiceStatus:POST {card_id,encrypt_code,reimburse_status}
    switch (s.updateInvoiceStatus(io, .{ .card_id = "CARD1", .encrypt_code = "ENC1", .reimburse_status = "INVOICE_REIMBURSE_LOCK" })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "card/invoice/reimburse/updateinvoicestatus") != null);
    try std.testing.expectEqualStrings("{\"card_id\":\"CARD1\",\"encrypt_code\":\"ENC1\",\"reimburse_status\":\"INVOICE_REIMBURSE_LOCK\"}", m.last_body);
}

test "reimburse invoice batch get/update" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "updatestatusbatch", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "getinvoicebatch", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"item_list\":[{\"card_id\":\"C1\",\"openid\":\"O1\"},{\"card_id\":\"C2\",\"payee\":\"P2\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ReimburseInvoiceService{ .svc = &base };

    // getInvoiceBatch:POST {item_list:[{card_id,encrypt_code}...]} → item_list[]
    const listed = switch (s.getInvoiceBatch(io, .{ .item_list = &.{
        .{ .card_id = "C1", .encrypt_code = "E1" },
        .{ .card_id = "C2", .encrypt_code = "E2" },
    } })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer {
        for (listed) |*x| x.deinit();
        gpa.free(listed);
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "card/invoice/reimburse/getinvoicebatch") != null);
    try std.testing.expectEqualStrings("{\"item_list\":[{\"card_id\":\"C1\",\"encrypt_code\":\"E1\"},{\"card_id\":\"C2\",\"encrypt_code\":\"E2\"}]}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("C1", listed[0].card_id.?);
    try std.testing.expectEqualStrings("O1", listed[0].openid.?);
    try std.testing.expectEqualStrings("C2", listed[1].card_id.?);
    try std.testing.expectEqualStrings("P2", listed[1].payee.?);

    // updateStatusBatch:POST {openid,reimburse_status,invoice_list}
    switch (s.updateStatusBatch(io, .{
        .openid = "OPENID",
        .reimburse_status = "INVOICE_REIMBURSE_CONFIRM",
        .invoice_list = &.{.{ .card_id = "C1", .encrypt_code = "E1" }},
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "card/invoice/reimburse/updatestatusbatch") != null);
    try std.testing.expectEqualStrings("{\"openid\":\"OPENID\",\"reimburse_status\":\"INVOICE_REIMBURSE_CONFIRM\",\"invoice_list\":[{\"card_id\":\"C1\",\"encrypt_code\":\"E1\"}]}", m.last_body);
}

test "reimburse invoice batch: item_list 缺失返回空列表" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getinvoicebatch", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ReimburseInvoiceService{ .svc = &base };

    const listed = switch (s.getInvoiceBatch(io, .{ .item_list = &.{} })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}
