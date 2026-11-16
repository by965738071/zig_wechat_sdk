//! 发货信息管理服务 —— 对应 Java `api.WxMaOrderShippingService` +
//! `api.impl.WxMaOrderShippingServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.OrderShipping`:
//! - isTradeManaged:POST /wxa/sec/order/is_trade_managed {appid}
//!   → IsTradeManagedResult{is_trade_managed};
//! - upload:POST /wxa/sec/order/upload_shipping_info(发货信息录入,见
//!   UploadShippingInfoRequest);
//! - uploadCombined:POST /wxa/sec/order/upload_combined_shipping_info
//!   (合单录入,Java 重载 `upload(Combined...)`,Zig 改名 uploadCombined);
//! - get:POST /wxa/sec/order/get_order(按交易单号/商户单号查发货状态);
//! - getList:POST /wxa/sec/order/get_order_list(按支付时间/openid/状态查列表);
//! - notifyConfirmReceive:POST /wxa/sec/order/notify_confirm_receive
//!   (确认收货提醒,每个订单仅可调用一次);
//! - setMsgJumpPath:POST /wxa/sec/order/set_msg_jump_path {path};
//! - isTradeManagementConfirmationCompleted:POST
//!   /wxa/sec/order/is_trade_management_confirmation_completed {appid}
//!   → ItmcCompletedResult{completed};
//! - opSpecialOrder:POST /wxa/sec/order/opspecialorder {order_id,type,delay_to?}
//!   (type 1=预售商品订单 此时 delay_to 必填,2=测试订单;delay_to 为 null 时省略,
//!   与 Java GsonHelper.buildJsonObject 跳过 null 一致)。
//! 请求体 null 字段省略(与 Gson 默认一致);errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const IS_TRADE_MANAGED_URL = "https://api.weixin.qq.com/wxa/sec/order/is_trade_managed";
const UPLOAD_SHIPPING_INFO_URL = "https://api.weixin.qq.com/wxa/sec/order/upload_shipping_info";
const UPLOAD_COMBINED_SHIPPING_INFO_URL = "https://api.weixin.qq.com/wxa/sec/order/upload_combined_shipping_info";
const GET_SHIPPING_INFO_URL = "https://api.weixin.qq.com/wxa/sec/order/get_order";
const GET_SHIPPING_INFO_LIST_URL = "https://api.weixin.qq.com/wxa/sec/order/get_order_list";
const NOTIFY_CONFIRM_RECEIVE_URL = "https://api.weixin.qq.com/wxa/sec/order/notify_confirm_receive";
const SET_MSG_JUMP_PATH_URL = "https://api.weixin.qq.com/wxa/sec/order/set_msg_jump_path";
const IS_TRADE_MANAGEMENT_CONFIRMATION_COMPLETED_URL = "https://api.weixin.qq.com/wxa/sec/order/is_trade_management_confirmation_completed";
const OP_SPECIAL_ORDER_URL = "https://api.weixin.qq.com/wxa/sec/order/opspecialorder";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- 请求 bean(字段借用调用方内存,null 省略与 Gson 默认一致) ------------------

/// 对应 `request.shipping.OrderKeyBean`
/// (order_number_type 必填:1=商户号+商户单号,2=微信支付单号)。
pub const OrderKey = struct {
    order_number_type: i64,
    transaction_id: ?[]const u8 = null,
    mchid: ?[]const u8 = null,
    out_trade_no: ?[]const u8 = null,
};

fn writeOrderKey(w: *std.Io.Writer, k: OrderKey) !void {
    try w.writeAll("{\"order_number_type\":");
    try w.print("{d}", .{k.order_number_type});
    if (k.transaction_id) |v| {
        try w.writeAll(",\"transaction_id\":");
        try js(w, v);
    }
    if (k.mchid) |v| {
        try w.writeAll(",\"mchid\":");
        try js(w, v);
    }
    if (k.out_trade_no) |v| {
        try w.writeAll(",\"out_trade_no\":");
        try js(w, v);
    }
    try w.writeAll("}");
}

/// 对应 `request.shipping.ContactBean`(联系方式,掩码传输)。
pub const Contact = struct {
    consignor_contact: ?[]const u8 = null,
    receiver_contact: ?[]const u8 = null,
};

fn writeContact(w: *std.Io.Writer, c: Contact) !void {
    try w.writeByte('{');
    var sep: []const u8 = "";
    if (c.consignor_contact) |v| {
        try w.print("{s}\"consignor_contact\":", .{sep});
        try js(w, v);
        sep = ",";
    }
    if (c.receiver_contact) |v| {
        try w.print("{s}\"receiver_contact\":", .{sep});
        try js(w, v);
    }
    try w.writeByte('}');
}

/// 对应 `request.shipping.ShippingListBean`(单个物流单信息)。
pub const ShippingList = struct {
    tracking_no: ?[]const u8 = null,
    express_company: ?[]const u8 = null,
    item_desc: ?[]const u8 = null,
    contact: ?Contact = null,
};

fn writeShippingItems(w: *std.Io.Writer, items: []const ShippingList) !void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (item.tracking_no) |v| {
            try w.print("{s}\"tracking_no\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (item.express_company) |v| {
            try w.print("{s}\"express_company\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (item.item_desc) |v| {
            try w.print("{s}\"item_desc\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (item.contact) |c| {
            try w.print("{s}\"contact\":", .{sep});
            try writeContact(w, c);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// 对应 `request.shipping.PayerBean`(openid)。
pub const Payer = struct {
    openid: []const u8,
};

/// 对应 `request.shipping.WxMaOrderShippingInfoUploadRequest`。
pub const UploadShippingInfoRequest = struct {
    order_key: OrderKey,
    /// 物流模式:1 实体物流 2 同城配送 3 虚拟商品 4 用户自提。
    logistics_type: i64,
    /// 发货模式:1 统一发货 2 分拆发货。
    delivery_mode: i64,
    /// 分拆发货模式时必填:是否已全部发货完成。
    is_all_delivered: ?bool = null,
    shipping_list: []const ShippingList,
    /// 上传时间,如 `2022-12-15T13:29:35.120+08:00`。
    upload_time: []const u8,
    payer: Payer,

    pub fn to_json(self: UploadShippingInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"order_key\":");
        try writeOrderKey(w, self.order_key);
        try w.print(",\"logistics_type\":{d},\"delivery_mode\":{d}", .{ self.logistics_type, self.delivery_mode });
        if (self.is_all_delivered) |v| try w.print(",\"is_all_delivered\":{}", .{v});
        try w.writeAll(",\"shipping_list\":");
        try writeShippingItems(w, self.shipping_list);
        try w.writeAll(",\"upload_time\":");
        try js(w, self.upload_time);
        try w.writeAll(",\"payer\":{\"openid\":");
        try js(w, self.payer.openid);
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// 对应 `request.shipping.WxMaOrderCombinedShippingInfoUploadRequest.SubOrderBean`。
pub const SubOrder = struct {
    order_key: OrderKey,
    logistics_type: i64,
    delivery_mode: i64,
    is_all_delivered: ?bool = null,
    shipping_list: []const ShippingList,
};

fn writeSubOrder(w: *std.Io.Writer, sub: SubOrder) !void {
    try w.writeAll("{\"order_key\":");
    try writeOrderKey(w, sub.order_key);
    try w.print(",\"logistics_type\":{d},\"delivery_mode\":{d}", .{ sub.logistics_type, sub.delivery_mode });
    if (sub.is_all_delivered) |v| try w.print(",\"is_all_delivered\":{}", .{v});
    try w.writeAll(",\"shipping_list\":");
    try writeShippingItems(w, sub.shipping_list);
    try w.writeAll("}");
}

/// 对应 `request.shipping.WxMaOrderCombinedShippingInfoUploadRequest`(合单录入)。
pub const UploadCombinedShippingInfoRequest = struct {
    order_key: OrderKey,
    sub_orders: []const SubOrder,
    upload_time: []const u8,
    payer: Payer,

    pub fn to_json(self: UploadCombinedShippingInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"order_key\":");
        try writeOrderKey(w, self.order_key);
        try w.writeAll(",\"sub_orders\":[");
        for (self.sub_orders, 0..) |sub, i| {
            if (i > 0) try w.writeByte(',');
            try writeSubOrder(w, sub);
        }
        try w.writeAll("],\"upload_time\":");
        try js(w, self.upload_time);
        try w.writeAll(",\"payer\":{\"openid\":");
        try js(w, self.payer.openid);
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }
};

/// 对应 `request.shipping.WxMaOrderShippingInfoGetRequest`
/// (交易单号或商户号+商户单号二选一)。
pub const GetShippingInfoRequest = struct {
    transaction_id: ?[]const u8 = null,
    merchant_id: ?[]const u8 = null,
    sub_merchant_id: ?[]const u8 = null,
    merchant_trade_no: ?[]const u8 = null,

    pub fn to_json(self: GetShippingInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.transaction_id) |v| {
            try w.print("{s}\"transaction_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.merchant_id) |v| {
            try w.print("{s}\"merchant_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.sub_merchant_id) |v| {
            try w.print("{s}\"sub_merchant_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.merchant_trade_no) |v| {
            try w.print("{s}\"merchant_trade_no\":", .{sep});
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `request.shipping.WxMaOrderShippingInfoGetListRequest.PayTimeRange`。
pub const PayTimeRange = struct {
    /// 起始时间(时间戳),不填视为从 0 开始。
    begin_time: ?i64 = null,
    /// 结束时间(含,时间戳),不填视为 32 位无符号整型最大值。
    end_time: ?i64 = null,
};

/// 对应 `request.shipping.WxMaOrderShippingInfoGetListRequest`。
pub const GetShippingInfoListRequest = struct {
    pay_time_range: ?PayTimeRange = null,
    /// 订单状态:1 待发货 2 已发货 3 确认收货 4 交易完成 5 已退款。
    order_state: ?i64 = null,
    openid: ?[]const u8 = null,
    last_index: ?[]const u8 = null,
    page_size: ?i64 = null,

    pub fn to_json(self: GetShippingInfoListRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.pay_time_range) |r| {
            try w.writeAll("\"pay_time_range\":{");
            var rsep: []const u8 = "";
            if (r.begin_time) |v| {
                try w.print("{s}\"begin_time\":{d}", .{ rsep, v });
                rsep = ",";
            }
            if (r.end_time) |v| try w.print("{s}\"end_time\":{d}", .{ rsep, v });
            try w.writeByte('}');
            sep = ",";
        }
        if (self.order_state) |v| {
            try w.print("{s}\"order_state\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.openid) |v| {
            try w.print("{s}\"openid\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.last_index) |v| {
            try w.print("{s}\"last_index\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.page_size) |v| {
            try w.print("{s}\"page_size\":{d}", .{ sep, v });
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `request.shipping.WxMaOrderShippingInfoNotifyConfirmRequest`。
pub const NotifyConfirmReceiveRequest = struct {
    transaction_id: ?[]const u8 = null,
    merchant_id: ?[]const u8 = null,
    sub_merchant_id: ?[]const u8 = null,
    merchant_trade_no: ?[]const u8 = null,
    /// 快递签收时间(时间戳)。
    received_time: ?i64 = null,

    pub fn to_json(self: NotifyConfirmReceiveRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.transaction_id) |v| {
            try w.print("{s}\"transaction_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.merchant_id) |v| {
            try w.print("{s}\"merchant_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.sub_merchant_id) |v| {
            try w.print("{s}\"sub_merchant_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.merchant_trade_no) |v| {
            try w.print("{s}\"merchant_trade_no\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.received_time) |v| {
            try w.print("{s}\"received_time\":{d}", .{ sep, v });
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

// --- 响应 bean(gpa 拥有) ------------------------------------------------------

/// 对应 `response.WxMaOrderShippingIsTradeManagedResponse`(业务字段部分;
/// errcode/errmsg 已由基座折叠)。无动态内存,无需 deinit。
pub const IsTradeManagedResult = struct {
    /// 是否已开通小程序发货信息管理服务。
    is_trade_managed: ?bool,
};

/// 对应 `response.WxMaOrderShippingITMCCompletedResult`(业务字段部分)。
pub const ItmcCompletedResult = struct {
    /// 是否已完成交易结算管理确认。
    completed: ?bool,
};

/// 对应 `response.WxMaOrderShippingInfoBaseResponse.Contact`。gpa 拥有。
pub const ContactInfo = struct {
    gpa: std.mem.Allocator,
    consignor_contact: ?[]const u8,
    receiver_contact: ?[]const u8,

    pub fn deinit(self: *ContactInfo) void {
        const g = self.gpa;
        if (self.consignor_contact) |s| g.free(@constCast(s));
        if (self.receiver_contact) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const ContactInfo) void {
        const g = self.gpa;
        if (self.consignor_contact) |s| g.free(s);
        if (self.receiver_contact) |s| g.free(s);
    }
};

/// 对应 `response.WxMaOrderShippingInfoBaseResponse.ShippingItem`。gpa 拥有。
pub const ShippingItem = struct {
    gpa: std.mem.Allocator,
    tracking_no: ?[]const u8,
    express_company: ?[]const u8,
    goods_desc: ?[]const u8,
    upload_time: ?i64,
    contact: ?ContactInfo,

    pub fn deinit(self: *ShippingItem) void {
        const g = self.gpa;
        if (self.tracking_no) |s| g.free(@constCast(s));
        if (self.express_company) |s| g.free(@constCast(s));
        if (self.goods_desc) |s| g.free(@constCast(s));
        if (self.contact) |*c| c.deinit();
    }

    pub fn deinitConst(self: *const ShippingItem) void {
        const g = self.gpa;
        if (self.tracking_no) |s| g.free(s);
        if (self.express_company) |s| g.free(s);
        if (self.goods_desc) |s| g.free(s);
        if (self.contact) |*c| c.deinitConst();
    }
};

/// 对应 `response.WxMaOrderShippingInfoBaseResponse.Shipping`。gpa 拥有。
pub const Shipping = struct {
    gpa: std.mem.Allocator,
    delivery_mode: ?i64,
    logistics_type: ?i64,
    finish_shipping: ?bool,
    goods_desc: ?[]const u8,
    finish_shipping_count: ?i64,
    shipping_list: []ShippingItem,

    pub fn deinit(self: *Shipping) void {
        const g = self.gpa;
        if (self.goods_desc) |s| g.free(@constCast(s));
        for (self.shipping_list) |*item| item.deinit();
        g.free(self.shipping_list);
    }

    pub fn deinitConst(self: *const Shipping) void {
        const g = self.gpa;
        if (self.goods_desc) |s| g.free(s);
        for (self.shipping_list) |item| item.deinitConst();
        g.free(self.shipping_list);
    }
};

/// 对应 `response.WxMaOrderShippingInfoBaseResponse.Order`(支付单信息)。gpa 拥有。
pub const Order = struct {
    gpa: std.mem.Allocator,
    transaction_id: ?[]const u8,
    merchant_id: ?[]const u8,
    sub_merchant_id: ?[]const u8,
    merchant_trade_no: ?[]const u8,
    description: ?[]const u8,
    paid_amount: ?i64,
    openid: ?[]const u8,
    trade_create_time: ?i64,
    pay_time: ?i64,
    order_state: ?i64,
    in_complaint: ?bool,
    shipping: ?Shipping,

    pub fn deinit(self: *Order) void {
        const g = self.gpa;
        if (self.transaction_id) |s| g.free(@constCast(s));
        if (self.merchant_id) |s| g.free(@constCast(s));
        if (self.sub_merchant_id) |s| g.free(@constCast(s));
        if (self.merchant_trade_no) |s| g.free(@constCast(s));
        if (self.description) |s| g.free(@constCast(s));
        if (self.openid) |s| g.free(@constCast(s));
        if (self.shipping) |*sh| sh.deinit();
    }

    pub fn deinitConst(self: *const Order) void {
        const g = self.gpa;
        if (self.transaction_id) |s| g.free(s);
        if (self.merchant_id) |s| g.free(s);
        if (self.sub_merchant_id) |s| g.free(s);
        if (self.merchant_trade_no) |s| g.free(s);
        if (self.description) |s| g.free(s);
        if (self.openid) |s| g.free(s);
        if (self.shipping) |*sh| sh.deinitConst();
    }
};

fn deinitOrders(gpa: std.mem.Allocator, list: []Order) void {
    for (list) |*o| o.deinit();
    gpa.free(list);
}

/// 对应 `response.WxMaOrderShippingInfoGetResponse`(order)。gpa 拥有。
pub const GetShippingInfoResult = struct {
    gpa: std.mem.Allocator,
    order: ?Order,

    pub fn deinit(self: *GetShippingInfoResult) void {
        if (self.order) |*o| o.deinit();
    }
};

/// 对应 `response.WxMaOrderShippingInfoGetListResponse`。gpa 拥有。
pub const GetShippingInfoListResult = struct {
    gpa: std.mem.Allocator,
    last_index: ?[]const u8,
    has_more: ?bool,
    order_list: []Order,

    pub fn deinit(self: *GetShippingInfoListResult) void {
        const g = self.gpa;
        if (self.last_index) |s| g.free(@constCast(s));
        deinitOrders(g, self.order_list);
    }
};

// --- 响应解析 -------------------------------------------------------------------

fn parseContactInfo(gpa: std.mem.Allocator, obj: std.json.Value) !ContactInfo {
    var c = ContactInfo{ .gpa = gpa, .consignor_contact = null, .receiver_contact = null };
    errdefer c.deinit();
    if (json_util.getStr(obj, "consignor_contact")) |s| c.consignor_contact = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "receiver_contact")) |s| c.receiver_contact = try gpa.dupe(u8, s);
    return c;
}

fn parseShippingItem(gpa: std.mem.Allocator, obj: std.json.Value) !ShippingItem {
    var it = ShippingItem{
        .gpa = gpa,
        .tracking_no = null,
        .express_company = null,
        .goods_desc = null,
        .upload_time = null,
        .contact = null,
    };
    errdefer it.deinit();
    if (json_util.getStr(obj, "tracking_no")) |s| it.tracking_no = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "express_company")) |s| it.express_company = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "goods_desc")) |s| it.goods_desc = try gpa.dupe(u8, s);
    it.upload_time = json_util.getInt(obj, "upload_time");
    if (json_util.getObject(obj, "contact")) |cv| it.contact = try parseContactInfo(gpa, cv);
    return it;
}

fn parseShipping(gpa: std.mem.Allocator, obj: std.json.Value) !Shipping {
    var sh = Shipping{
        .gpa = gpa,
        .delivery_mode = null,
        .logistics_type = null,
        .finish_shipping = null,
        .goods_desc = null,
        .finish_shipping_count = null,
        .shipping_list = &[_]ShippingItem{},
    };
    errdefer sh.deinit();
    sh.delivery_mode = json_util.getInt(obj, "delivery_mode");
    sh.logistics_type = json_util.getInt(obj, "logistics_type");
    sh.finish_shipping = json_util.getBool(obj, "finish_shipping");
    if (json_util.getStr(obj, "goods_desc")) |s| sh.goods_desc = try gpa.dupe(u8, s);
    sh.finish_shipping_count = json_util.getInt(obj, "finish_shipping_count");
    if (json_util.getArray(obj, "shipping_list")) |arr| {
        const list = try gpa.alloc(ShippingItem, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*item| item.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseShippingItem(gpa, item);
            filled += 1;
        }
        sh.shipping_list = list;
    }
    return sh;
}

fn parseOrder(gpa: std.mem.Allocator, obj: std.json.Value) !Order {
    var o = Order{
        .gpa = gpa,
        .transaction_id = null,
        .merchant_id = null,
        .sub_merchant_id = null,
        .merchant_trade_no = null,
        .description = null,
        .paid_amount = null,
        .openid = null,
        .trade_create_time = null,
        .pay_time = null,
        .order_state = null,
        .in_complaint = null,
        .shipping = null,
    };
    errdefer o.deinit();
    if (json_util.getStr(obj, "transaction_id")) |s| o.transaction_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "merchant_id")) |s| o.merchant_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "sub_merchant_id")) |s| o.sub_merchant_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "merchant_trade_no")) |s| o.merchant_trade_no = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "description")) |s| o.description = try gpa.dupe(u8, s);
    o.paid_amount = json_util.getInt(obj, "paid_amount");
    if (json_util.getStr(obj, "openid")) |s| o.openid = try gpa.dupe(u8, s);
    o.trade_create_time = json_util.getInt(obj, "trade_create_time");
    o.pay_time = json_util.getInt(obj, "pay_time");
    o.order_state = json_util.getInt(obj, "order_state");
    o.in_complaint = json_util.getBool(obj, "in_complaint");
    if (json_util.getObject(obj, "shipping")) |sv| o.shipping = try parseShipping(gpa, sv);
    return o;
}

// --- service --------------------------------------------------------------------

pub const OrderShippingService = struct {
    svc: *mp_service.Service,

    /// 对应 `isTradeManaged(String appId)`:POST is_trade_managed {appid}
    /// → 是否已开通发货信息管理服务。
    pub fn isTradeManaged(self: *OrderShippingService, io: std.Io, appid: []const u8) WxResult(IsTradeManagedResult) {
        const gpa = self.svc.gpa;
        const body = appidBody(gpa, appid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, IS_TRADE_MANAGED_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "is_trade_managed not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{ .is_trade_managed = json_util.getBool(parsed.value, "is_trade_managed") } };
    }

    /// 对应 `upload(WxMaOrderShippingInfoUploadRequest)`:POST upload_shipping_info。
    pub fn upload(self: *OrderShippingService, io: std.Io, req: UploadShippingInfoRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPLOAD_SHIPPING_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `upload(WxMaOrderCombinedShippingInfoUploadRequest)`(Java 重载):
    /// POST upload_combined_shipping_info。
    pub fn uploadCombined(self: *OrderShippingService, io: std.Io, req: UploadCombinedShippingInfoRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPLOAD_COMBINED_SHIPPING_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `get(WxMaOrderShippingInfoGetRequest)`:POST get_order → order。
    pub fn get(self: *OrderShippingService, io: std.Io, req: GetShippingInfoRequest) WxResult(GetShippingInfoResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_SHIPPING_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_order not json", .{}) };
        defer parsed.deinit();
        var out = GetShippingInfoResult{ .gpa = gpa, .order = null };
        if (json_util.getObject(parsed.value, "order")) |ov| {
            out.order = parseOrder(gpa, ov) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out };
    }

    /// 对应 `getList(WxMaOrderShippingInfoGetListRequest)`:POST get_order_list。
    pub fn getList(self: *OrderShippingService, io: std.Io, req: GetShippingInfoListRequest) WxResult(GetShippingInfoListResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_SHIPPING_INFO_LIST_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_order_list not json", .{}) };
        defer parsed.deinit();
        var out = GetShippingInfoListResult{ .gpa = gpa, .last_index = null, .has_more = null, .order_list = &[_]Order{} };
        if (json_util.getStr(parsed.value, "last_index")) |s| {
            out.last_index = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        out.has_more = json_util.getBool(parsed.value, "has_more");
        if (json_util.getArray(parsed.value, "order_list")) |arr| {
            const list = gpa.alloc(Order, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseOrder(gpa, item) catch {
                    for (list[0..filled]) |*o| o.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
            out.order_list = list;
        }
        return .{ .ok = out };
    }

    /// 对应 `notifyConfirmReceive(WxMaOrderShippingInfoNotifyConfirmRequest)`:
    /// POST notify_confirm_receive(每个订单仅可调用一次)。
    pub fn notifyConfirmReceive(self: *OrderShippingService, io: std.Io, req: NotifyConfirmReceiveRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, NOTIFY_CONFIRM_RECEIVE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `setMsgJumpPath(String path)`:POST set_msg_jump_path {path}。
    pub fn setMsgJumpPath(self: *OrderShippingService, io: std.Io, path: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"path\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, path) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SET_MSG_JUMP_PATH_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `isTradeManagementConfirmationCompleted(String appId)`:POST
    /// is_trade_management_confirmation_completed {appid} → completed。
    pub fn isTradeManagementConfirmationCompleted(self: *OrderShippingService, io: std.Io, appid: []const u8) WxResult(ItmcCompletedResult) {
        const gpa = self.svc.gpa;
        const body = appidBody(gpa, appid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, IS_TRADE_MANAGEMENT_CONFIRMATION_COMPLETED_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "is_trade_management_confirmation_completed not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{ .completed = json_util.getBool(parsed.value, "completed") } };
    }

    /// 对应 `opSpecialOrder(String orderId, Integer type, Long delayTo)`:
    /// POST opspecialorder {order_id,type,delay_to?}(1 预售订单 此时 delayTo 必填,
    /// 2 测试订单;delayTo 为 null 时省略)。
    pub fn opSpecialOrder(self: *OrderShippingService, io: std.Io, order_id: []const u8, order_type: i64, delay_to: ?i64) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"order_id\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, order_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (delay_to) |v| {
            w.print(",\"type\":{d},\"delay_to\":{d}}}", .{ order_type, v }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        } else {
            w.print(",\"type\":{d}}}", .{order_type}) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, OP_SPECIAL_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// 内部:构建 {"appid":...} 请求体(gpa 拥有,调用方 free)。
fn appidBody(gpa: std.mem.Allocator, appid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"appid\":");
    try js(w, appid);
    try w.writeAll("}");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "order shipping isTradeManaged / confirmationCompleted / setMsgJumpPath / opSpecialOrder" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "is_trade_management_confirmation_completed", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"completed\":true}" },
        .{ .match = "is_trade_managed", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"is_trade_managed\":true}" },
        .{ .match = "set_msg_jump_path", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "opspecialorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OrderShippingService{ .svc = &base };

    // isTradeManaged:POST {"appid":...} → is_trade_managed
    const managed = switch (s.isTradeManaged(io, "wxAppId")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/is_trade_managed") != null);
    try std.testing.expectEqualStrings("{\"appid\":\"wxAppId\"}", m.last_body);
    try std.testing.expectEqual(true, managed.is_trade_managed.?);

    // isTradeManagementConfirmationCompleted:completed
    const completed = switch (s.isTradeManagementConfirmationCompleted(io, "wxAppId")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "is_trade_management_confirmation_completed") != null);
    try std.testing.expectEqualStrings("{\"appid\":\"wxAppId\"}", m.last_body);
    try std.testing.expectEqual(true, completed.completed.?);

    // setMsgJumpPath:POST {path}
    switch (s.setMsgJumpPath(io, "pages/orders/list")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/set_msg_jump_path") != null);
    try std.testing.expectEqualStrings("{\"path\":\"pages/orders/list\"}", m.last_body);

    // opSpecialOrder:delay_to 省略/包含两种形态
    switch (s.opSpecialOrder(io, "order-1", 1, 1737000000)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/opspecialorder") != null);
    try std.testing.expectEqualStrings("{\"order_id\":\"order-1\",\"type\":1,\"delay_to\":1737000000}", m.last_body);

    switch (s.opSpecialOrder(io, "order-2", 2, null)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"order_id\":\"order-2\",\"type\":2}", m.last_body);
}

test "order shipping upload / uploadCombined" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "upload_combined_shipping_info", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "upload_shipping_info", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OrderShippingService{ .svc = &base };

    // upload:嵌套 order_key/shipping_list/contact/payer;is_all_delivered 包含
    switch (s.upload(io, .{
        .order_key = .{ .order_number_type = 2, .transaction_id = "TX1", .mchid = "MCH", .out_trade_no = "OUT1" },
        .logistics_type = 1,
        .delivery_mode = 1,
        .is_all_delivered = true,
        .shipping_list = &.{
            .{ .tracking_no = "SF123", .express_company = "SF", .item_desc = "抱枕*1", .contact = .{ .consignor_contact = "189****1234", .receiver_contact = "137****5678" } },
        },
        .upload_time = "2026-01-01T00:00:00+08:00",
        .payer = .{ .openid = "OPENID" },
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/upload_shipping_info") != null);
    try std.testing.expectEqualStrings(
        "{\"order_key\":{\"order_number_type\":2,\"transaction_id\":\"TX1\",\"mchid\":\"MCH\",\"out_trade_no\":\"OUT1\"},\"logistics_type\":1,\"delivery_mode\":1,\"is_all_delivered\":true,\"shipping_list\":[{\"tracking_no\":\"SF123\",\"express_company\":\"SF\",\"item_desc\":\"抱枕*1\",\"contact\":{\"consignor_contact\":\"189****1234\",\"receiver_contact\":\"137****5678\"}}],\"upload_time\":\"2026-01-01T00:00:00+08:00\",\"payer\":{\"openid\":\"OPENID\"}}",
        m.last_body,
    );

    // uploadCombined:sub_orders 数组,is_all_delivered 为 null 时省略
    switch (s.uploadCombined(io, .{
        .order_key = .{ .order_number_type = 1, .transaction_id = "TXC" },
        .sub_orders = &.{
            .{
                .order_key = .{ .order_number_type = 2, .transaction_id = "SUBTX" },
                .logistics_type = 3,
                .delivery_mode = 1,
                .shipping_list = &.{.{ .item_desc = "虚拟商品" }},
            },
        },
        .upload_time = "2026-01-01T00:00:00+08:00",
        .payer = .{ .openid = "OPENID" },
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/upload_combined_shipping_info") != null);
    try std.testing.expectEqualStrings(
        "{\"order_key\":{\"order_number_type\":1,\"transaction_id\":\"TXC\"},\"sub_orders\":[{\"order_key\":{\"order_number_type\":2,\"transaction_id\":\"SUBTX\"},\"logistics_type\":3,\"delivery_mode\":1,\"shipping_list\":[{\"item_desc\":\"虚拟商品\"}]}],\"upload_time\":\"2026-01-01T00:00:00+08:00\",\"payer\":{\"openid\":\"OPENID\"}}",
        m.last_body,
    );
}

test "order shipping get / getList / notifyConfirmReceive" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 注意顺序:get_order_list 在 get_order 之前(子串包含关系,先命中 list)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_order_list", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"last_index\":\"LI\",\"has_more\":true,\"order_list\":[{\"transaction_id\":\"TX1\",\"order_state\":2},{\"transaction_id\":\"TX2\",\"order_state\":3}]}" },
        .{ .match = "get_order", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order\":{\"transaction_id\":\"TX1\",\"merchant_id\":\"MCH\",\"paid_amount\":100,\"openid\":\"OPENID\",\"order_state\":2,\"in_complaint\":false,\"shipping\":{\"delivery_mode\":1,\"logistics_type\":1,\"finish_shipping\":true,\"goods_desc\":\"gd\",\"finish_shipping_count\":1,\"shipping_list\":[{\"tracking_no\":\"SF123\",\"express_company\":\"SF\",\"goods_desc\":\"item\",\"upload_time\":1700000002,\"contact\":{\"consignor_contact\":\"189****1234\",\"receiver_contact\":\"137****5678\"}}]}}}" },
        .{ .match = "notify_confirm_receive", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OrderShippingService{ .svc = &base };

    // get:POST {transaction_id},解析嵌套 order/shipping/shipping_list/contact
    var got = switch (s.get(io, .{ .transaction_id = "TX1" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/get_order") != null);
    try std.testing.expectEqualStrings("{\"transaction_id\":\"TX1\"}", m.last_body);
    const order = got.order.?;
    try std.testing.expectEqualStrings("TX1", order.transaction_id.?);
    try std.testing.expectEqualStrings("MCH", order.merchant_id.?);
    try std.testing.expectEqual(@as(i64, 100), order.paid_amount.?);
    try std.testing.expectEqual(@as(i64, 2), order.order_state.?);
    try std.testing.expectEqual(false, order.in_complaint.?);
    const shp = order.shipping.?;
    try std.testing.expectEqual(@as(i64, 1), shp.delivery_mode.?);
    try std.testing.expectEqual(true, shp.finish_shipping.?);
    try std.testing.expectEqualStrings("gd", shp.goods_desc.?);
    try std.testing.expectEqual(@as(usize, 1), shp.shipping_list.len);
    const item = shp.shipping_list[0];
    try std.testing.expectEqualStrings("SF123", item.tracking_no.?);
    try std.testing.expectEqual(@as(i64, 1700000002), item.upload_time.?);
    try std.testing.expectEqualStrings("189****1234", item.contact.?.consignor_contact.?);
    try std.testing.expectEqualStrings("137****5678", item.contact.?.receiver_contact.?);

    // getList:pay_time_range/order_state/openid/last_index/page_size 全量序列化
    var listed = switch (s.getList(io, .{
        .pay_time_range = .{ .begin_time = 1, .end_time = 2 },
        .order_state = 2,
        .openid = "O1",
        .last_index = "LI",
        .page_size = 10,
    })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer listed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/get_order_list") != null);
    try std.testing.expectEqualStrings(
        "{\"pay_time_range\":{\"begin_time\":1,\"end_time\":2},\"order_state\":2,\"openid\":\"O1\",\"last_index\":\"LI\",\"page_size\":10}",
        m.last_body,
    );
    try std.testing.expectEqualStrings("LI", listed.last_index.?);
    try std.testing.expectEqual(true, listed.has_more.?);
    try std.testing.expectEqual(@as(usize, 2), listed.order_list.len);
    try std.testing.expectEqualStrings("TX1", listed.order_list[0].transaction_id.?);
    try std.testing.expectEqual(@as(i64, 3), listed.order_list[1].order_state.?);

    // notifyConfirmReceive:received_time 序列化
    switch (s.notifyConfirmReceive(io, .{ .transaction_id = "TX1", .received_time = 1737000000 })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/notify_confirm_receive") != null);
    try std.testing.expectEqualStrings("{\"transaction_id\":\"TX1\",\"received_time\":1737000000}", m.last_body);
}

test "order shipping get: null 字段省略 / order 缺失" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_order", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OrderShippingService{ .svc = &base };

    // 全 null 请求体 → "{}"(与 Gson 全 null 省略一致)
    var got = switch (s.get(io, .{})) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expect(got.order == null);
}
