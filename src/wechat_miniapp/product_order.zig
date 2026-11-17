//! 小程序交易组件-标准版-订单服务 —— 对应 Java `api.WxMaProductOrderService` +
//! `api.impl.WxMaProductOrderServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Product.Order`:
//! - `product/order/get_list`、`product/order/get`、
//!   `product/order/change_merchant_notes`;
//! - `product/delivery/send`(发货);
//! - 售后:`product/order/getaftersaleorder`、`product/order/batchgetaftersaleorder`、
//!   `product/order/acceptapply`(受理)、`product/order/rejectrefund`(拒绝)。
//!
//! 与 Java 的差异(均已在对应位置注释):
//! - errcode≠0 已由基座折叠为 `.err`;WxMaShopBaseResponse 系 errcode/errmsg
//!   载荷字段不再保留;
//! - `batchGetAfterSaleOrder` 回包缺 after_sale_order_list 时 Java 抛
//!   WxErrorException("售后查询不存在"),Zig 返回 `.err`(internal,-99);
//! - `afterSaleReject` 的请求键是 `order_id`(值为售后单 id),与 Java 一致
//!   (Java 代码即如此,疑似应为 after_sale_order_id,按原样保留);
//! - `WxMiniAfterSaleOrder.status` Java 声明为 String,微信实际可能回数字,
//!   与 express_delivery_return 相同用宽容取字符串(looseStr)处理;
//! - `sku_attrs` 复用 product.zig 的 SkuAttr(对齐 Java 共享类
//!   WxMinishopGoodsSkuAttr)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;
const product_mod = @import("product.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_LIST_URL = "https://api.weixin.qq.com/product/order/get_list";
const GET_DETAIL_URL = "https://api.weixin.qq.com/product/order/get";
const CHANGE_MERCHANT_NOTES_URL = "https://api.weixin.qq.com/product/order/change_merchant_notes";
const DELIVERY_SEND_URL = "https://api.weixin.qq.com/product/delivery/send";
const GET_AFTER_SALE_ORDER_URL = "https://api.weixin.qq.com/product/order/getaftersaleorder";
const BATCH_GET_AFTER_SALE_ORDER_URL = "https://api.weixin.qq.com/product/order/batchgetaftersaleorder";
const AFTER_SALE_ACCEPT_URL = "https://api.weixin.qq.com/product/order/acceptapply";
const AFTER_SALE_REJECT_URL = "https://api.weixin.qq.com/product/order/rejectrefund";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- 解析辅助(与 product.zig 同构)--------------------------------------------------

fn looseStrValue(gpa: std.mem.Allocator, c: std.json.Value) !?[]const u8 {
    return switch (c) {
        .string => |s| try gpa.dupe(u8, s),
        .number_string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
        else => null,
    };
}

fn looseStr(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) !?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const c = o.get(key) orelse return null;
    return looseStrValue(gpa, c);
}

/// 字符串数组:逐元素宽容字符串化,元素类型不识别时归一化为 ""。
fn dupStrArray(gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value)) ![][]const u8 {
    const list = try gpa.alloc([]const u8, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |s| gpa.free(@constCast(s));
        gpa.free(list);
    }
    for (arr.items) |item| {
        list[filled] = (try looseStrValue(gpa, item)) orelse try gpa.dupe(u8, "");
        filled += 1;
    }
    return list;
}

// --- bean(发货请求,借用字符串)-----------------------------------------------------

/// 对应 `WxMiniOrderDeliveryRequest`(deliverySend 入参)。
pub const DeliveryRequest = struct {
    order_id: ?i64 = null,
    delivery_list: []const DeliveryItem = &[_]DeliveryItem{},

    pub fn to_json(self: DeliveryRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        var sep = false;
        try w.writeAll("{");
        if (self.order_id) |v| {
            try w.print("\"order_id\":{d}", .{v});
            sep = true;
        }
        if (self.delivery_list.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"delivery_list\":[");
            for (self.delivery_list, 0..) |*d, i| {
                if (i > 0) try w.writeAll(",");
                try d.write_json(w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `WxMiniOrderDeliveryRequest.DeliveryListBean`。
pub const DeliveryItem = struct {
    delivery_id: ?[]const u8 = null,
    is_all_product: ?bool = null,
    waybill_id: ?[]const u8 = null,
    product_infos: []const DeliveryProduct = &[_]DeliveryProduct{},

    fn write_json(self: *const DeliveryItem, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.delivery_id) |v| {
            try w.writeAll("\"delivery_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.is_all_product) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"is_all_product\":{}", .{v});
            sep = true;
        }
        if (self.waybill_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"waybill_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.product_infos.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"product_infos\":[");
            for (self.product_infos, 0..) |*p, i| {
                if (i > 0) try w.writeAll(",");
                try p.write_json(w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
};

/// 对应 `WxMiniOrderDeliveryRequest.ProductInfosBean`。product_id/sku_id 在
/// Java 中是 String(与订单回包里的 Integer/Long 不同,按原样对齐)。
pub const DeliveryProduct = struct {
    product_id: ?[]const u8 = null,
    sku_id: ?[]const u8 = null,
    product_cnt: ?i64 = null,

    fn write_json(self: *const DeliveryProduct, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.product_id) |v| {
            try w.writeAll("\"product_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.sku_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"sku_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.product_cnt) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"product_cnt\":{d}", .{v});
        }
        try w.writeAll("}");
    }
};

// --- bean(回包)----------------------------------------------------------------------

/// 对应 `WxMinishopPayInfo`。
pub const PayInfo = struct {
    gpa: std.mem.Allocator,
    pay_method: ?[]const u8 = null,
    prepay_id: ?[]const u8 = null,
    prepay_time: ?[]const u8 = null,
    transaction_id: ?[]const u8 = null,
    pay_time: ?[]const u8 = null,

    pub fn deinit(self: *PayInfo) void {
        const g = self.gpa;
        if (self.pay_method) |s| g.free(@constCast(s));
        if (self.prepay_id) |s| g.free(@constCast(s));
        if (self.prepay_time) |s| g.free(@constCast(s));
        if (self.transaction_id) |s| g.free(@constCast(s));
        if (self.pay_time) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const PayInfo) void {
        const g = self.gpa;
        if (self.pay_method) |s| g.free(s);
        if (self.prepay_id) |s| g.free(s);
        if (self.prepay_time) |s| g.free(s);
        if (self.transaction_id) |s| g.free(s);
        if (self.pay_time) |s| g.free(s);
    }
};

fn parsePayInfo(gpa: std.mem.Allocator, v: std.json.Value) !PayInfo {
    var out = PayInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.pay_method = try looseStr(gpa, v, "pay_method");
    out.prepay_id = try looseStr(gpa, v, "prepay_id");
    out.prepay_time = try looseStr(gpa, v, "prepay_time");
    out.transaction_id = try looseStr(gpa, v, "transaction_id");
    out.pay_time = try looseStr(gpa, v, "pay_time");
    return out;
}

/// 对应 `WxMinishopPriceInfo`(单位:分)。
pub const PriceInfo = struct {
    product_price: ?i64 = null,
    order_price: ?i64 = null,
    freight: ?i64 = null,
    discounted_price: ?i64 = null,
    is_discounted: ?bool = null,
};

fn parsePriceInfo(v: std.json.Value) PriceInfo {
    return .{
        .product_price = json_util.getInt(v, "product_price"),
        .order_price = json_util.getInt(v, "order_price"),
        .freight = json_util.getInt(v, "freight"),
        .discounted_price = json_util.getInt(v, "discounted_price"),
        .is_discounted = json_util.getBool(v, "is_discounted"),
    };
}

/// 对应 `WxMinishopAddressInfo`。
pub const AddressInfo = struct {
    gpa: std.mem.Allocator,
    user_name: ?[]const u8 = null,
    postal_code: ?[]const u8 = null,
    province_name: ?[]const u8 = null,
    city_name: ?[]const u8 = null,
    county_name: ?[]const u8 = null,
    detail_info: ?[]const u8 = null,
    national_code: ?[]const u8 = null,
    tel_number: ?[]const u8 = null,

    pub fn deinit(self: *AddressInfo) void {
        const g = self.gpa;
        if (self.user_name) |s| g.free(@constCast(s));
        if (self.postal_code) |s| g.free(@constCast(s));
        if (self.province_name) |s| g.free(@constCast(s));
        if (self.city_name) |s| g.free(@constCast(s));
        if (self.county_name) |s| g.free(@constCast(s));
        if (self.detail_info) |s| g.free(@constCast(s));
        if (self.national_code) |s| g.free(@constCast(s));
        if (self.tel_number) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AddressInfo) void {
        const g = self.gpa;
        if (self.user_name) |s| g.free(s);
        if (self.postal_code) |s| g.free(s);
        if (self.province_name) |s| g.free(s);
        if (self.city_name) |s| g.free(s);
        if (self.county_name) |s| g.free(s);
        if (self.detail_info) |s| g.free(s);
        if (self.national_code) |s| g.free(s);
        if (self.tel_number) |s| g.free(s);
    }
};

fn parseAddressInfo(gpa: std.mem.Allocator, v: std.json.Value) !AddressInfo {
    var out = AddressInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.user_name = try looseStr(gpa, v, "user_name");
    out.postal_code = try looseStr(gpa, v, "postal_code");
    out.province_name = try looseStr(gpa, v, "province_name");
    out.city_name = try looseStr(gpa, v, "city_name");
    out.county_name = try looseStr(gpa, v, "county_name");
    out.detail_info = try looseStr(gpa, v, "detail_info");
    out.national_code = try looseStr(gpa, v, "national_code");
    out.tel_number = try looseStr(gpa, v, "tel_number");
    return out;
}

/// 对应 `WxMinishopDeliveryInfo.InsuranceInfo`。字段名 `type` 是 Zig 关键字,
/// 用 type_(Java 字段名逐字对齐)。type_ 为解析产生的拥有字符串。
pub const InsuranceInfo = struct {
    gpa: std.mem.Allocator,
    type_: ?[]const u8 = null,
    insurance_price: ?i64 = null,

    pub fn deinit(self: *InsuranceInfo) void {
        if (self.type_) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const InsuranceInfo) void {
        if (self.type_) |s| self.gpa.free(s);
    }
};

fn parseInsuranceInfo(gpa: std.mem.Allocator, v: std.json.Value) !InsuranceInfo {
    return .{
        .gpa = gpa,
        .type_ = try looseStr(gpa, v, "type"),
        .insurance_price = json_util.getInt(v, "insurance_price"),
    };
}

/// 对应 `WxMinishopDeliveryInfo.ProductInfo`(product_id/sku_id/product_cnt
/// 均为 Long)。
pub const DeliveryProductItem = struct {
    product_id: ?i64 = null,
    sku_id: ?i64 = null,
    product_cnt: ?i64 = null,
};

fn parseDeliveryProductItem(v: std.json.Value) DeliveryProductItem {
    return .{
        .product_id = json_util.getInt(v, "product_id"),
        .sku_id = json_util.getInt(v, "sku_id"),
        .product_cnt = json_util.getInt(v, "product_cnt"),
    };
}

/// 对应 `WxMinishopDeliveryInfo.DeliveryProductInfo`。
pub const DeliveryProductInfo = struct {
    gpa: std.mem.Allocator,
    waybill_id: ?[]const u8 = null,
    delivery_id: ?[]const u8 = null,
    delivery_time: ?[]const u8 = null,
    deliver_type: ?[]const u8 = null,
    delivery_address: ?AddressInfo = null,
    product_infos: []DeliveryProductItem = &[_]DeliveryProductItem{},

    pub fn deinit(self: *DeliveryProductInfo) void {
        const g = self.gpa;
        if (self.waybill_id) |s| g.free(@constCast(s));
        if (self.delivery_id) |s| g.free(@constCast(s));
        if (self.delivery_time) |s| g.free(@constCast(s));
        if (self.deliver_type) |s| g.free(@constCast(s));
        if (self.delivery_address) |*a| a.deinit();
        g.free(self.product_infos);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const DeliveryProductInfo) void {
        const g = self.gpa;
        if (self.waybill_id) |s| g.free(s);
        if (self.delivery_id) |s| g.free(s);
        if (self.delivery_time) |s| g.free(s);
        if (self.deliver_type) |s| g.free(s);
        if (self.delivery_address) |*a| a.deinitConst();
        g.free(self.product_infos);
    }
};

fn parseDeliveryProductInfo(gpa: std.mem.Allocator, v: std.json.Value) !DeliveryProductInfo {
    var out = DeliveryProductInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.waybill_id = try looseStr(gpa, v, "waybill_id");
    out.delivery_id = try looseStr(gpa, v, "delivery_id");
    out.delivery_time = try looseStr(gpa, v, "delivery_time");
    out.deliver_type = try looseStr(gpa, v, "deliver_type");
    if (json_util.getObject(v, "delivery_address")) |av| {
        out.delivery_address = try parseAddressInfo(gpa, av);
    }
    if (json_util.getArray(v, "product_infos")) |arr| {
        const list = try gpa.alloc(DeliveryProductItem, arr.items.len);
        for (arr.items, 0..) |item, i| list[i] = parseDeliveryProductItem(item);
        out.product_infos = list;
    }
    return out;
}

/// 对应 `WxMinishopDeliveryInfo`。
pub const DeliveryInfo = struct {
    gpa: std.mem.Allocator,
    address_info: ?AddressInfo = null,
    delivery_method: ?[]const u8 = null,
    delivery_product_info: []DeliveryProductInfo = &[_]DeliveryProductInfo{},
    ship_done_time: ?i64 = null,
    insurance_info: ?InsuranceInfo = null,
    deliver_type: ?[]const u8 = null,
    offline_delivery_time: ?i64 = null,
    offline_pickup_time: ?i64 = null,

    pub fn deinit(self: *DeliveryInfo) void {
        const g = self.gpa;
        if (self.address_info) |*a| a.deinit();
        if (self.delivery_method) |s| g.free(@constCast(s));
        for (self.delivery_product_info) |*d| d.deinit();
        g.free(self.delivery_product_info);
        if (self.insurance_info) |*i| i.deinit();
        if (self.deliver_type) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const DeliveryInfo) void {
        const g = self.gpa;
        if (self.address_info) |*a| a.deinitConst();
        if (self.delivery_method) |s| g.free(s);
        for (self.delivery_product_info) |*d| d.deinitConst();
        g.free(self.delivery_product_info);
        if (self.insurance_info) |*i| i.deinitConst();
        if (self.deliver_type) |s| g.free(s);
    }
};

fn parseDeliveryInfo(gpa: std.mem.Allocator, v: std.json.Value) !DeliveryInfo {
    var out = DeliveryInfo{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getObject(v, "address_info")) |av| out.address_info = try parseAddressInfo(gpa, av);
    out.delivery_method = try looseStr(gpa, v, "delivery_method");
    if (json_util.getArray(v, "delivery_product_info")) |arr| {
        const list = try gpa.alloc(DeliveryProductInfo, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*d| d.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseDeliveryProductInfo(gpa, item);
            filled += 1;
        }
        out.delivery_product_info = list;
    }
    out.ship_done_time = json_util.getInt(v, "ship_done_time");
    if (json_util.getObject(v, "insurance_info")) |iv| out.insurance_info = try parseInsuranceInfo(gpa, iv);
    out.deliver_type = try looseStr(gpa, v, "deliver_type");
    out.offline_delivery_time = json_util.getInt(v, "offline_delivery_time");
    out.offline_pickup_time = json_util.getInt(v, "offline_pickup_time");
    return out;
}

/// 对应 `WxMinishopProductInfo`(下单商品信息)。
pub const OrderProductInfo = struct {
    gpa: std.mem.Allocator,
    product_id: ?i64 = null,
    out_product_id: ?[]const u8 = null,
    sku_id: ?i64 = null,
    out_sku_id: ?[]const u8 = null,
    sku_cnt: ?i64 = null,
    on_aftersale_sku_cnt: ?i64 = null,
    finish_aftersale_sku_cnt: ?i64 = null,
    title: ?[]const u8 = null,
    thumb_img: ?[]const u8 = null,
    sku_attrs: []product_mod.SkuAttr = &[_]product_mod.SkuAttr{},
    sale_price: ?i64 = null,
    market_price: ?i64 = null,

    pub fn deinit(self: *OrderProductInfo) void {
        const g = self.gpa;
        if (self.out_product_id) |s| g.free(@constCast(s));
        if (self.out_sku_id) |s| g.free(@constCast(s));
        if (self.title) |s| g.free(@constCast(s));
        if (self.thumb_img) |s| g.free(@constCast(s));
        for (self.sku_attrs) |*a| a.deinit();
        g.free(self.sku_attrs);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderProductInfo) void {
        const g = self.gpa;
        if (self.out_product_id) |s| g.free(s);
        if (self.out_sku_id) |s| g.free(s);
        if (self.title) |s| g.free(s);
        if (self.thumb_img) |s| g.free(s);
        for (self.sku_attrs) |*a| a.deinitConst();
        g.free(self.sku_attrs);
    }
};

fn parseOrderProductInfo(gpa: std.mem.Allocator, v: std.json.Value) !OrderProductInfo {
    var out = OrderProductInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.product_id = json_util.getInt(v, "product_id");
    out.out_product_id = try looseStr(gpa, v, "out_product_id");
    out.sku_id = json_util.getInt(v, "sku_id");
    out.out_sku_id = try looseStr(gpa, v, "out_sku_id");
    out.sku_cnt = json_util.getInt(v, "sku_cnt");
    out.on_aftersale_sku_cnt = json_util.getInt(v, "on_aftersale_sku_cnt");
    out.finish_aftersale_sku_cnt = json_util.getInt(v, "finish_aftersale_sku_cnt");
    out.title = try looseStr(gpa, v, "title");
    out.thumb_img = try looseStr(gpa, v, "thumb_img");
    if (json_util.getArray(v, "sku_attrs")) |arr| {
        const list = try gpa.alloc(product_mod.SkuAttr, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*a| a.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try product_mod.parseSkuAttr(gpa, item);
            filled += 1;
        }
        out.sku_attrs = list;
    }
    out.sale_price = json_util.getInt(v, "sale_price");
    out.market_price = json_util.getInt(v, "market_price");
    return out;
}

/// 对应 `WxMinishopOrderDetail`(下单商品/支付/价格/物流四块)。
pub const OrderDetail = struct {
    gpa: std.mem.Allocator,
    product_infos: []OrderProductInfo = &[_]OrderProductInfo{},
    pay_info: ?PayInfo = null,
    price_info: ?PriceInfo = null,
    delivery_info: ?DeliveryInfo = null,

    pub fn deinit(self: *OrderDetail) void {
        const g = self.gpa;
        for (self.product_infos) |*p| p.deinit();
        g.free(self.product_infos);
        if (self.pay_info) |*p| p.deinit();
        if (self.delivery_info) |*d| d.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderDetail) void {
        const g = self.gpa;
        for (self.product_infos) |*p| p.deinitConst();
        g.free(self.product_infos);
        if (self.pay_info) |*p| p.deinitConst();
        if (self.delivery_info) |*d| d.deinitConst();
    }
};

fn parseOrderDetail(gpa: std.mem.Allocator, v: std.json.Value) !OrderDetail {
    var out = OrderDetail{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "product_infos")) |arr| {
        const list = try gpa.alloc(OrderProductInfo, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*p| p.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseOrderProductInfo(gpa, item);
            filled += 1;
        }
        out.product_infos = list;
    }
    if (json_util.getObject(v, "pay_info")) |pv| out.pay_info = try parsePayInfo(gpa, pv);
    if (json_util.getObject(v, "price_info")) |pv| out.price_info = parsePriceInfo(pv);
    if (json_util.getObject(v, "delivery_info")) |dv| out.delivery_info = try parseDeliveryInfo(gpa, dv);
    return out;
}

/// 对应 `WxMiniOrderAfterSaleDetail.AfterSaleOrder`(订单上的售后单引用,
/// status 为 Integer,与 WxMiniAfterSaleOrder.status(String)不同,Java 亦如此)。
pub const AfterSaleOrderRef = struct {
    aftersale_order_id: ?i64 = null,
    status: ?i64 = null,
};

fn parseAfterSaleOrderRef(v: std.json.Value) AfterSaleOrderRef {
    return .{
        .aftersale_order_id = json_util.getInt(v, "aftersale_order_id"),
        .status = json_util.getInt(v, "status"),
    };
}

/// 对应 `WxMiniOrderAfterSaleDetail`。
pub const OrderAfterSaleDetail = struct {
    gpa: std.mem.Allocator,
    aftersale_order_list: []AfterSaleOrderRef = &[_]AfterSaleOrderRef{},
    on_aftersale_order_cnt: ?i64 = null,

    pub fn deinit(self: *OrderAfterSaleDetail) void {
        self.gpa.free(self.aftersale_order_list);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderAfterSaleDetail) void {
        self.gpa.free(self.aftersale_order_list);
    }
};

fn parseOrderAfterSaleDetail(gpa: std.mem.Allocator, v: std.json.Value) !OrderAfterSaleDetail {
    var out = OrderAfterSaleDetail{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "aftersale_order_list")) |arr| {
        const list = try gpa.alloc(AfterSaleOrderRef, arr.items.len);
        for (arr.items, 0..) |item, i| list[i] = parseAfterSaleOrderRef(item);
        out.aftersale_order_list = list;
    }
    out.on_aftersale_order_cnt = json_util.getInt(v, "on_aftersale_order_cnt");
    return out;
}

/// 对应 `WxMinishopOrderResult.ExtInfo`。
pub const OrderExtInfo = struct {
    gpa: std.mem.Allocator,
    customer_notes: ?[]const u8 = null,
    merchant_notes: ?[]const u8 = null,

    pub fn deinit(self: *OrderExtInfo) void {
        if (self.customer_notes) |s| self.gpa.free(@constCast(s));
        if (self.merchant_notes) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderExtInfo) void {
        if (self.customer_notes) |s| self.gpa.free(s);
        if (self.merchant_notes) |s| self.gpa.free(s);
    }
};

fn parseOrderExtInfo(gpa: std.mem.Allocator, v: std.json.Value) !OrderExtInfo {
    var out = OrderExtInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.customer_notes = try looseStr(gpa, v, "customer_notes");
    out.merchant_notes = try looseStr(gpa, v, "merchant_notes");
    return out;
}

/// 对应 `WxMinishopOrderResult`(订单主体)。
pub const OrderResult = struct {
    gpa: std.mem.Allocator,
    order_id: ?i64 = null,
    status: ?i64 = null,
    create_time: ?[]const u8 = null,
    update_time: ?[]const u8 = null,
    order_detail: ?OrderDetail = null,
    aftersale_detail: ?OrderAfterSaleDetail = null,
    openid: ?[]const u8 = null,
    ext_info: ?OrderExtInfo = null,
    order_type: ?i64 = null,

    pub fn deinit(self: *OrderResult) void {
        const g = self.gpa;
        if (self.create_time) |s| g.free(@constCast(s));
        if (self.update_time) |s| g.free(@constCast(s));
        if (self.order_detail) |*d| d.deinit();
        if (self.aftersale_detail) |*a| a.deinit();
        if (self.openid) |s| g.free(@constCast(s));
        if (self.ext_info) |*e| e.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderResult) void {
        const g = self.gpa;
        if (self.create_time) |s| g.free(s);
        if (self.update_time) |s| g.free(s);
        if (self.order_detail) |*d| d.deinitConst();
        if (self.aftersale_detail) |*a| a.deinitConst();
        if (self.openid) |s| g.free(s);
        if (self.ext_info) |*e| e.deinitConst();
    }
};

fn parseOrderResult(gpa: std.mem.Allocator, v: std.json.Value) !OrderResult {
    var out = OrderResult{ .gpa = gpa };
    errdefer out.deinit();
    out.order_id = json_util.getInt(v, "order_id");
    out.status = json_util.getInt(v, "status");
    out.create_time = try looseStr(gpa, v, "create_time");
    out.update_time = try looseStr(gpa, v, "update_time");
    if (json_util.getObject(v, "order_detail")) |dv| out.order_detail = try parseOrderDetail(gpa, dv);
    if (json_util.getObject(v, "aftersale_detail")) |av| out.aftersale_detail = try parseOrderAfterSaleDetail(gpa, av);
    out.openid = try looseStr(gpa, v, "openid");
    if (json_util.getObject(v, "ext_info")) |ev| out.ext_info = try parseOrderExtInfo(gpa, ev);
    out.order_type = json_util.getInt(v, "order_type");
    return out;
}

/// 对应 `WxMinishopOrderListResponse`(顶层 orders/total_num)。
pub const OrderListResult = struct {
    gpa: std.mem.Allocator,
    orders: []OrderResult = &[_]OrderResult{},
    total_num: ?i64 = null,

    pub fn deinit(self: *OrderListResult) void {
        for (self.orders) |*o| o.deinit();
        self.gpa.free(self.orders);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderListResult) void {
        for (self.orders) |*o| o.deinitConst();
        self.gpa.free(self.orders);
    }
};

/// 对应 `WxMinishopOrderDetailResponse`(data 非包装,order 在顶层;
/// Java 该 bean 直接继承 base response,order 为字段)。
pub const OrderDetailResult = struct {
    gpa: std.mem.Allocator,
    order: ?OrderResult = null,

    pub fn deinit(self: *OrderDetailResult) void {
        if (self.order) |*o| o.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderDetailResult) void {
        if (self.order) |*o| o.deinitConst();
    }
};

/// 对应 `WxMiniAfterSaleOrder.AfterSaleProductInfo`。
pub const AfterSaleProduct = struct {
    product_id: ?i64 = null,
    sku_id: ?i64 = null,
    count: ?i64 = null,
};

fn parseAfterSaleProduct(v: std.json.Value) AfterSaleProduct {
    return .{
        .product_id = json_util.getInt(v, "product_id"),
        .sku_id = json_util.getInt(v, "sku_id"),
        .count = json_util.getInt(v, "count"),
    };
}

/// 对应 `WxMiniAfterSaleOrder.AfterSaleDetails`。
pub const AfterSaleDetails = struct {
    gpa: std.mem.Allocator,
    num: ?i64 = null,
    desc: ?[]const u8 = null,
    cancel_time: ?i64 = null,
    prove_imgs: [][]const u8 = &[_][]const u8{},
    tel_number: ?[]const u8 = null,

    pub fn deinit(self: *AfterSaleDetails) void {
        const g = self.gpa;
        if (self.desc) |s| g.free(@constCast(s));
        for (self.prove_imgs) |s| g.free(@constCast(s));
        g.free(self.prove_imgs);
        if (self.tel_number) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AfterSaleDetails) void {
        const g = self.gpa;
        if (self.desc) |s| g.free(s);
        for (self.prove_imgs) |s| g.free(s);
        g.free(self.prove_imgs);
        if (self.tel_number) |s| g.free(s);
    }
};

fn parseAfterSaleDetails(gpa: std.mem.Allocator, v: std.json.Value) !AfterSaleDetails {
    var out = AfterSaleDetails{ .gpa = gpa };
    errdefer out.deinit();
    out.num = json_util.getInt(v, "num");
    out.desc = try looseStr(gpa, v, "desc");
    out.cancel_time = json_util.getInt(v, "cancel_time");
    if (json_util.getArray(v, "prove_imgs")) |arr| out.prove_imgs = try dupStrArray(gpa, arr);
    out.tel_number = try looseStr(gpa, v, "tel_number");
    return out;
}

/// 对应 `WxMiniAfterSaleOrder.RefundInfo`。
pub const RefundInfo = struct {
    amount: ?i64 = null,
};

/// 对应 `WxMiniAfterSaleOrder.ReturnInfo`。
pub const ReturnInfo = struct {
    gpa: std.mem.Allocator,
    delivery_id: ?[]const u8 = null,
    waybill_id: ?[]const u8 = null,
    delivery_name: ?[]const u8 = null,

    pub fn deinit(self: *ReturnInfo) void {
        const g = self.gpa;
        if (self.delivery_id) |s| g.free(@constCast(s));
        if (self.waybill_id) |s| g.free(@constCast(s));
        if (self.delivery_name) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const ReturnInfo) void {
        const g = self.gpa;
        if (self.delivery_id) |s| g.free(s);
        if (self.waybill_id) |s| g.free(s);
        if (self.delivery_name) |s| g.free(s);
    }
};

fn parseReturnInfo(gpa: std.mem.Allocator, v: std.json.Value) !ReturnInfo {
    var out = ReturnInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.delivery_id = try looseStr(gpa, v, "delivery_id");
    out.waybill_id = try looseStr(gpa, v, "waybill_id");
    out.delivery_name = try looseStr(gpa, v, "delivery_name");
    return out;
}

/// 对应 `WxMiniAfterSaleOrder.MerchantUploadInfo`。
pub const MerchantUploadInfo = struct {
    gpa: std.mem.Allocator,
    reject_reason: ?[]const u8 = null,
    refund_certificates: [][]const u8 = &[_][]const u8{},

    pub fn deinit(self: *MerchantUploadInfo) void {
        const g = self.gpa;
        if (self.reject_reason) |s| g.free(@constCast(s));
        for (self.refund_certificates) |s| g.free(@constCast(s));
        g.free(self.refund_certificates);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const MerchantUploadInfo) void {
        const g = self.gpa;
        if (self.reject_reason) |s| g.free(s);
        for (self.refund_certificates) |s| g.free(s);
        g.free(self.refund_certificates);
    }
};

fn parseMerchantUploadInfo(gpa: std.mem.Allocator, v: std.json.Value) !MerchantUploadInfo {
    var out = MerchantUploadInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.reject_reason = try looseStr(gpa, v, "reject_reason");
    if (json_util.getArray(v, "refund_certificates")) |arr| {
        out.refund_certificates = try dupStrArray(gpa, arr);
    }
    return out;
}

/// 对应 `WxMiniAfterSaleOrder.RefundResp`。
pub const RefundResp = struct {
    gpa: std.mem.Allocator,
    code: ?[]const u8 = null,
    ret: ?i64 = null,
    message: ?[]const u8 = null,

    pub fn deinit(self: *RefundResp) void {
        if (self.code) |s| self.gpa.free(@constCast(s));
        if (self.message) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const RefundResp) void {
        if (self.code) |s| self.gpa.free(s);
        if (self.message) |s| self.gpa.free(s);
    }
};

fn parseRefundResp(gpa: std.mem.Allocator, v: std.json.Value) !RefundResp {
    var out = RefundResp{ .gpa = gpa };
    errdefer out.deinit();
    out.code = try looseStr(gpa, v, "code");
    out.ret = json_util.getInt(v, "ret");
    out.message = try looseStr(gpa, v, "message");
    return out;
}

/// 对应 `WxMiniAfterSaleOrder`(售后单)。status Java 声明为 String,微信实际
/// 可能回数字,用 looseStr 宽容处理;create_time/update_time 是 Long(与订单
/// 主体的 String 不同,Java 亦如此)。
pub const AfterSaleOrder = struct {
    gpa: std.mem.Allocator,
    order_id: ?i64 = null,
    status: ?[]const u8 = null,
    openid: ?[]const u8 = null,
    original_order_id: ?i64 = null,
    product_info: ?AfterSaleProduct = null,
    details: ?AfterSaleDetails = null,
    refund_info: ?RefundInfo = null,
    return_info: ?ReturnInfo = null,
    merchant_upload_info: ?MerchantUploadInfo = null,
    create_time: ?i64 = null,
    update_time: ?i64 = null,
    reason: ?[]const u8 = null,
    refund_resp: ?RefundResp = null,
    type_: ?[]const u8 = null,

    pub fn deinit(self: *AfterSaleOrder) void {
        const g = self.gpa;
        if (self.status) |s| g.free(@constCast(s));
        if (self.openid) |s| g.free(@constCast(s));
        if (self.details) |*d| d.deinit();
        if (self.return_info) |*r| r.deinit();
        if (self.merchant_upload_info) |*m| m.deinit();
        if (self.reason) |s| g.free(@constCast(s));
        if (self.refund_resp) |*r| r.deinit();
        if (self.type_) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AfterSaleOrder) void {
        const g = self.gpa;
        if (self.status) |s| g.free(s);
        if (self.openid) |s| g.free(s);
        if (self.details) |*d| d.deinitConst();
        if (self.return_info) |*r| r.deinitConst();
        if (self.merchant_upload_info) |*m| m.deinitConst();
        if (self.reason) |s| g.free(s);
        if (self.refund_resp) |*r| r.deinitConst();
        if (self.type_) |s| g.free(s);
    }
};

fn parseAfterSaleOrder(gpa: std.mem.Allocator, v: std.json.Value) !AfterSaleOrder {
    var out = AfterSaleOrder{ .gpa = gpa };
    errdefer out.deinit();
    out.order_id = json_util.getInt(v, "order_id");
    out.status = try looseStr(gpa, v, "status");
    out.openid = try looseStr(gpa, v, "openid");
    out.original_order_id = json_util.getInt(v, "original_order_id");
    if (json_util.getObject(v, "product_info")) |pv| out.product_info = parseAfterSaleProduct(pv);
    if (json_util.getObject(v, "details")) |dv| out.details = try parseAfterSaleDetails(gpa, dv);
    if (json_util.getObject(v, "refund_info")) |rv| {
        out.refund_info = .{ .amount = json_util.getInt(rv, "amount") };
    }
    if (json_util.getObject(v, "return_info")) |rv| out.return_info = try parseReturnInfo(gpa, rv);
    if (json_util.getObject(v, "merchant_upload_info")) |mv| {
        out.merchant_upload_info = try parseMerchantUploadInfo(gpa, mv);
    }
    out.create_time = json_util.getInt(v, "create_time");
    out.update_time = json_util.getInt(v, "update_time");
    out.reason = try looseStr(gpa, v, "reason");
    if (json_util.getObject(v, "refund_resp")) |rv| out.refund_resp = try parseRefundResp(gpa, rv);
    out.type_ = try looseStr(gpa, v, "type");
    return out;
}

/// 对应 `WxMiniGetAfterSaleOrderResponse`(顶层 after_sale_order)。
pub const GetAfterSaleResult = struct {
    gpa: std.mem.Allocator,
    after_sale_order: ?AfterSaleOrder = null,

    pub fn deinit(self: *GetAfterSaleResult) void {
        if (self.after_sale_order) |*a| a.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const GetAfterSaleResult) void {
        if (self.after_sale_order) |*a| a.deinitConst();
    }
};

/// 对应 `WxMiniBatchGetAfterSaleOrderResponse`(顶层 after_sale_order_list)。
pub const BatchGetAfterSaleResult = struct {
    gpa: std.mem.Allocator,
    after_sale_order_list: []AfterSaleOrder = &[_]AfterSaleOrder{},

    pub fn deinit(self: *BatchGetAfterSaleResult) void {
        for (self.after_sale_order_list) |*a| a.deinit();
        self.gpa.free(self.after_sale_order_list);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BatchGetAfterSaleResult) void {
        for (self.after_sale_order_list) |*a| a.deinitConst();
        self.gpa.free(self.after_sale_order_list);
    }
};

// --- service -----------------------------------------------------------------------

/// 对应 `WxMaProductOrderServiceImpl`。所有方法 errcode≠0 时返回 `.err`。
pub const ProductOrderService = struct {
    svc: *mp_service.Service,

    /// 对应 `getOrderList(…)`:POST order/get_list。page/page_size 微信侧必填
    /// (最小 1 / 不超过 10000),其余可选。
    pub fn getOrderList(
        self: *ProductOrderService,
        io: std.Io,
        start_create_time: ?[]const u8,
        end_create_time: ?[]const u8,
        start_update_time: ?[]const u8,
        end_update_time: ?[]const u8,
        status: ?i64,
        page: ?i64,
        page_size: ?i64,
        source: ?i64,
    ) WxResult(OrderListResult) {
        const gpa = self.svc.gpa;
        const body = orderListBody(gpa, start_create_time, end_create_time, start_update_time, end_update_time, status, page, page_size, source) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_LIST_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "order list not json", .{}) };
        defer parsed.deinit();
        var out = OrderListResult{ .gpa = gpa };
        out.total_num = json_util.getInt(parsed.value, "total_num");
        if (json_util.getArray(parsed.value, "orders")) |arr| {
            const list = gpa.alloc(OrderResult, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseOrderResult(gpa, item) catch {
                    for (list[0..filled]) |*o| o.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "order list parse fail", .{}) };
                };
                filled += 1;
            }
            out.orders = list;
        }
        return .{ .ok = out };
    }

    /// 对应 `getOrderDetail(Long)`:POST order/get {"order_id":N}。order 缺失时
    /// Java 侧访问会 NPE,Zig 归一化为 null。
    pub fn getOrderDetail(self: *ProductOrderService, io: std.Io, order_id: i64) WxResult(OrderDetailResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("order_id", order_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_DETAIL_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "order detail not json", .{}) };
        defer parsed.deinit();
        var out = OrderDetailResult{ .gpa = gpa };
        if (json_util.getObject(parsed.value, "order")) |ov| {
            out.order = parseOrderResult(gpa, ov) catch
                return .{ .err = WxError.internal(gpa, "order detail parse fail", .{}) };
        }
        return .{ .ok = out };
    }

    /// 对应 `changeMerchantNotes(Long,String)`:POST change_merchant_notes
    /// {"order_id":N,"merchant_notes":"…"}。
    pub fn changeMerchantNotes(self: *ProductOrderService, io: std.Io, order_id: i64, merchant_notes: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"order_id\":{d},\"merchant_notes\":", .{order_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, merchant_notes) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, CHANGE_MERCHANT_NOTES_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `deliverySend(WxMiniOrderDeliveryRequest)`:POST delivery/send。
    pub fn deliverySend(self: *ProductOrderService, io: std.Io, req: DeliveryRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DELIVERY_SEND_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getAfterSaleOrder(Long)`:POST getaftersaleorder
    /// {"after_sale_order_id":N}。
    pub fn getAfterSaleOrder(self: *ProductOrderService, io: std.Io, after_sale_order_id: i64) WxResult(GetAfterSaleResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("after_sale_order_id", after_sale_order_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_AFTER_SALE_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "aftersale get not json", .{}) };
        defer parsed.deinit();
        var out = GetAfterSaleResult{ .gpa = gpa };
        if (json_util.getObject(parsed.value, "after_sale_order")) |av| {
            out.after_sale_order = parseAfterSaleOrder(gpa, av) catch
                return .{ .err = WxError.internal(gpa, "aftersale parse fail", .{}) };
        }
        return .{ .ok = out };
    }

    /// 对应 `batchGetAfterSaleOrder(List<Long>)`:POST batchgetaftersaleorder
    /// {"after_sale_order_id_list":[…]}。回包缺 after_sale_order_list 时 Java
    /// 抛 WxErrorException("售后查询不存在"),Zig 返回 `.err`。
    pub fn batchGetAfterSaleOrder(self: *ProductOrderService, io: std.Io, after_sale_order_id_list: []const i64) WxResult(BatchGetAfterSaleResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"after_sale_order_id_list\":[") catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (after_sale_order_id_list, 0..) |id, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print("{d}", .{id}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, BATCH_GET_AFTER_SALE_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "aftersale batch not json", .{}) };
        defer parsed.deinit();
        var result = BatchGetAfterSaleResult{ .gpa = gpa };
        if (json_util.getArray(parsed.value, "after_sale_order_list")) |arr| {
            const list = gpa.alloc(AfterSaleOrder, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseAfterSaleOrder(gpa, item) catch {
                    for (list[0..filled]) |*a| a.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "aftersale batch parse fail", .{}) };
                };
                filled += 1;
            }
            result.after_sale_order_list = list;
            return .{ .ok = result };
        }
        // Java:列表缺失 → throw new WxErrorException(errCode, "售后查询不存在")
        return .{ .err = WxError.internal(gpa, "售后查询不存在", .{}) };
    }

    /// 对应 `afterSaleAccept(Long,Long)`:POST acceptapply
    /// {"order_id":N,"address_id":N}。
    pub fn afterSaleAccept(self: *ProductOrderService, io: std.Io, order_id: i64, address_id: i64) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"order_id\":{d},\"address_id\":{d}}}", .{ order_id, address_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, AFTER_SALE_ACCEPT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `afterSaleReject(Long,String)`:POST rejectrefund。请求键为
    /// `order_id`(值是售后单 id),与 Java 一致(见文件头差异说明)。
    pub fn afterSaleReject(self: *ProductOrderService, io: std.Io, after_sale_order_id: i64, reject_reason: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"order_id\":{d},\"reject_reason\":", .{after_sale_order_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, reject_reason) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, AFTER_SALE_REJECT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

fn orderListBody(
    gpa: std.mem.Allocator,
    start_create_time: ?[]const u8,
    end_create_time: ?[]const u8,
    start_update_time: ?[]const u8,
    end_update_time: ?[]const u8,
    status: ?i64,
    page: ?i64,
    page_size: ?i64,
    source: ?i64,
) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (start_create_time) |v| try ob.putStr("start_create_time", v);
    if (end_create_time) |v| try ob.putStr("end_create_time", v);
    if (start_update_time) |v| try ob.putStr("start_update_time", v);
    if (end_update_time) |v| try ob.putStr("end_update_time", v);
    if (status) |v| try ob.putInt("status", v);
    if (page) |v| try ob.putInt("page", v);
    if (page_size) |v| try ob.putInt("page_size", v);
    if (source) |v| try ob.putInt("source", v);
    return ob.toJson();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "order list/detail/notes: 列表与嵌套订单树" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // get_list 必须排在 get 之前;getaftersaleorder/batchget 排在 get 之后
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "order/get_list", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total_num\":1,\"orders\":[{\"order_id\":100,\"status\":20,\"create_time\":\"2022-06-20 10:00:00\",\"update_time\":\"2022-06-21 10:00:00\",\"openid\":\"o-1\",\"order_type\":0,\"ext_info\":{\"customer_notes\":\"尽快发\",\"merchant_notes\":\"已备注\"},\"aftersale_detail\":{\"aftersale_order_list\":[{\"aftersale_order_id\":900,\"status\":10}],\"on_aftersale_order_cnt\":1},\"order_detail\":{\"product_infos\":[{\"product_id\":123,\"out_product_id\":\"op-1\",\"sku_id\":55,\"out_sku_id\":\"sku-1\",\"sku_cnt\":2,\"title\":\"拉杆箱\",\"thumb_img\":\"t.png\",\"sku_attrs\":[{\"attr_key\":\"颜色\",\"attr_value\":\"绿\"}],\"sale_price\":99800,\"market_price\":999800}],\"pay_info\":{\"pay_method\":\"weixin\",\"prepay_id\":\"pp1\",\"prepay_time\":\"2022-06-20 10:01:00\",\"transaction_id\":\"tx1\",\"pay_time\":\"2022-06-20 10:02:00\"},\"price_info\":{\"product_price\":199600,\"order_price\":199600,\"freight\":0,\"discounted_price\":0,\"is_discounted\":false}}}]}" },
        .{ .match = "order/getaftersaleorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"after_sale_order\":{\"order_id\":900,\"status\":\"20\",\"openid\":\"o-1\",\"original_order_id\":100,\"product_info\":{\"product_id\":123,\"sku_id\":55,\"count\":2},\"details\":{\"num\":2,\"desc\":\"不想要了\",\"cancel_time\":1656000000,\"prove_imgs\":[\"p1.jpg\"],\"tel_number\":\"13800000000\"},\"refund_info\":{\"amount\":199600},\"return_info\":{\"delivery_id\":\"SF\",\"waybill_id\":\"WB1\",\"delivery_name\":\"顺丰\"},\"merchant_upload_info\":{\"reject_reason\":\"\",\"refund_certificates\":[\"c1.jpg\"]},\"create_time\":1656000000,\"update_time\":1656000100,\"reason\":\"七天无理由\",\"refund_resp\":{\"code\":\"OK\",\"ret\":0,\"message\":\"ok\"},\"type\":\"ONLY_REFUND\"}}" },
        .{ .match = "change_merchant_notes", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "order/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order\":{\"order_id\":100,\"status\":20,\"order_detail\":{\"product_infos\":[{\"product_id\":123,\"sku_cnt\":1}],\"delivery_info\":{\"address_info\":{\"user_name\":\"张三\",\"province_name\":\"广东省\",\"tel_number\":\"13800000000\"},\"delivery_method\":\"SELF_PICKUP\",\"ship_done_time\":1656000200,\"insurance_info\":{\"type\":\"INSURE\",\"insurance_price\":100},\"deliver_type\":\"OFFLINE\",\"offline_delivery_time\":1656000300,\"offline_pickup_time\":1656000400,\"delivery_product_info\":[{\"waybill_id\":\"WB1\",\"delivery_id\":\"SF\",\"delivery_time\":\"2022-06-24 12:00:00\",\"deliver_type\":\"EXPRESS\",\"delivery_address\":{\"user_name\":\"李四\",\"city_name\":\"深圳\"},\"product_infos\":[{\"product_id\":123,\"sku_id\":55,\"product_cnt\":2}]}]}}}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductOrderService{ .svc = &base };

    var list = switch (s.getOrderList(io, "2022-06-01", "2022-06-30", null, null, 20, 1, 10, 1)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer list.deinit();
    try std.testing.expectEqualStrings("{\"start_create_time\":\"2022-06-01\",\"end_create_time\":\"2022-06-30\",\"status\":20,\"page\":1,\"page_size\":10,\"source\":1}", m.last_body);
    try std.testing.expectEqual(@as(i64, 1), list.total_num.?);
    try std.testing.expectEqual(@as(usize, 1), list.orders.len);
    const order = list.orders[0];
    try std.testing.expectEqual(@as(i64, 100), order.order_id.?);
    try std.testing.expectEqual(@as(i64, 20), order.status.?);
    try std.testing.expectEqualStrings("o-1", order.openid.?);
    try std.testing.expectEqualStrings("已备注", order.ext_info.?.merchant_notes.?);
    try std.testing.expectEqual(@as(i64, 900), order.aftersale_detail.?.aftersale_order_list[0].aftersale_order_id.?);
    const detail = order.order_detail.?;
    const prod = detail.product_infos[0];
    try std.testing.expectEqual(@as(i64, 123), prod.product_id.?);
    try std.testing.expectEqualStrings("sku-1", prod.out_sku_id.?);
    try std.testing.expectEqual(@as(i64, 2), prod.sku_cnt.?);
    try std.testing.expectEqualStrings("绿", prod.sku_attrs[0].attr_value.?);
    try std.testing.expectEqual(@as(i64, 999800), prod.market_price.?);
    const pay = detail.pay_info.?;
    try std.testing.expectEqualStrings("weixin", pay.pay_method.?);
    try std.testing.expectEqualStrings("tx1", pay.transaction_id.?);
    const price = detail.price_info.?;
    try std.testing.expectEqual(@as(i64, 199600), price.order_price.?);
    try std.testing.expect(price.is_discounted.? == false);

    // 全 null 参数 → 空请求体(Java buildJsonObject 全跳过)
    var list2 = switch (s.getOrderList(io, null, null, null, null, null, null, null, null)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer list2.deinit();
    try std.testing.expectEqualStrings("{}", m.last_body);

    var got = switch (s.getOrderDetail(io, 100)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expectEqualStrings("{\"order_id\":100}", m.last_body);
    const dinfo = got.order.?.order_detail.?.delivery_info.?;
    try std.testing.expectEqualStrings("张三", dinfo.address_info.?.user_name.?);
    try std.testing.expectEqual(@as(i64, 1656000200), dinfo.ship_done_time.?);
    try std.testing.expectEqualStrings("INSURE", dinfo.insurance_info.?.type_.?);
    try std.testing.expectEqual(@as(i64, 100), dinfo.insurance_info.?.insurance_price.?);
    const dprod = dinfo.delivery_product_info[0];
    try std.testing.expectEqualStrings("WB1", dprod.waybill_id.?);
    try std.testing.expectEqualStrings("李四", dprod.delivery_address.?.user_name.?);
    try std.testing.expectEqual(@as(i64, 2), dprod.product_infos[0].product_cnt.?);

    switch (s.changeMerchantNotes(io, 100, "加急\n优先发货")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"order_id\":100,\"merchant_notes\":\"加急\\n优先发货\"}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "change_merchant_notes") != null);

    var aso = switch (s.getAfterSaleOrder(io, 900)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer aso.deinit();
    try std.testing.expectEqualStrings("{\"after_sale_order_id\":900}", m.last_body);
    const ao = aso.after_sale_order.?;
    try std.testing.expectEqual(@as(i64, 900), ao.order_id.?);
    // status Java 声明为 String,fixture 回字符串
    try std.testing.expectEqualStrings("20", ao.status.?);
    try std.testing.expectEqual(@as(i64, 100), ao.original_order_id.?);
    try std.testing.expectEqual(@as(i64, 2), ao.product_info.?.count.?);
    try std.testing.expectEqualStrings("不想要了", ao.details.?.desc.?);
    try std.testing.expectEqual(@as(usize, 1), ao.details.?.prove_imgs.len);
    try std.testing.expectEqual(@as(i64, 199600), ao.refund_info.?.amount.?);
    try std.testing.expectEqualStrings("顺丰", ao.return_info.?.delivery_name.?);
    try std.testing.expectEqual(@as(usize, 1), ao.merchant_upload_info.?.refund_certificates.len);
    try std.testing.expectEqualStrings("七天无理由", ao.reason.?);
    try std.testing.expectEqual(@as(i64, 0), ao.refund_resp.?.ret.?);
    try std.testing.expectEqualStrings("ONLY_REFUND", ao.type_.?);
}

test "delivery send + aftersale accept/reject + batch(含缺失列表错误)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // batchgetaftersaleorder 必须排在 getaftersaleorder 之前(子串包含)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "order/batchgetaftersaleorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"after_sale_order_list\":[{\"order_id\":900,\"status\":\"20\"},{\"order_id\":901,\"status\":\"30\"}]}" },
        .{ .match = "delivery/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "acceptapply", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "rejectrefund", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductOrderService{ .svc = &base };

    // 发货:order_id + 两个 delivery_list(其一含 product_infos)
    switch (s.deliverySend(io, .{
        .order_id = 100,
        .delivery_list = &[_]DeliveryItem{
            .{ .delivery_id = "SF", .is_all_product = true, .waybill_id = "WB1" },
            .{ .delivery_id = "YT", .is_all_product = false, .waybill_id = "WB2", .product_infos = &[_]DeliveryProduct{
                .{ .product_id = "123", .sku_id = "55", .product_cnt = 2 },
            } },
        },
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"order_id\":100,\"delivery_list\":[{\"delivery_id\":\"SF\",\"is_all_product\":true,\"waybill_id\":\"WB1\"},{\"delivery_id\":\"YT\",\"is_all_product\":false,\"waybill_id\":\"WB2\",\"product_infos\":[{\"product_id\":\"123\",\"sku_id\":\"55\",\"product_cnt\":2}]}]}", m.last_body);

    switch (s.afterSaleAccept(io, 100, 7)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"order_id\":100,\"address_id\":7}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "acceptapply") != null);

    // Java quirk:reject 的请求键是 order_id(值是售后单 id)
    switch (s.afterSaleReject(io, 900, "凭证不足")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"order_id\":900,\"reject_reason\":\"凭证不足\"}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "rejectrefund") != null);

    var batch = switch (s.batchGetAfterSaleOrder(io, &[_]i64{ 900, 901 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer batch.deinit();
    try std.testing.expectEqualStrings("{\"after_sale_order_id_list\":[900,901]}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), batch.after_sale_order_list.len);
    try std.testing.expectEqual(@as(i64, 901), batch.after_sale_order_list[1].order_id.?);
    try std.testing.expectEqualStrings("30", batch.after_sale_order_list[1].status.?);

    // 回包缺列表 → .err(Java 抛"售后查询不存在")
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "batchgetaftersaleorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = ProductOrderService{ .svc = &base2 };
    switch (s2.batchGetAfterSaleOrder(io, &[_]i64{900})) {
        .ok => return error.Unexpected,
        .err => |e| {
            try std.testing.expectEqual(@as(i64, -99), e.error_code);
            var err = e;
            err.deinit();
        },
    }
}

test "product order: errcode≠0 折叠为 .err + status 数字宽容" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        // status 回数字(Java String 字段,Gson 宽容转换)
        .{ .match = "order/getaftersaleorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"after_sale_order\":{\"order_id\":900,\"status\":25,\"details\":{\"desc\":\"x\"}}}" },
        .{ .match = "order/get", .response = "{\"errcode\":990001,\"errmsg\":\"order not exist\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductOrderService{ .svc = &base };

    var aso = switch (s.getAfterSaleOrder(io, 900)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer aso.deinit();
    try std.testing.expectEqualStrings("25", aso.after_sale_order.?.status.?);

    switch (s.getOrderDetail(io, 100)) {
        .ok => return error.Unexpected,
        .err => |e| {
            try std.testing.expectEqual(@as(i64, 990001), e.error_code);
            var err = e;
            err.deinit();
        },
    }
}
