//! 小程序同城配送(上门服务)—— 对应 Java `api.WxMaIntracityService` +
//! `api.impl.WxMaIntracityServiceImpl` + `bean.intractiy.*`(Java 目录名
//! 拼写 intractiy 的 quirk 保留在对应注释里)。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Intracity`
//! (`https://api.weixin.qq.com/cgi-bin/express/intracity/` 下 15 个)。
//!
//! **签名通道**:除 `apply` 走普通明文 POST 外,Java 其余方法全部显式调
//! `postWithSignature`(AES-GCM 加密 + RSA-PSS 签名,见 api_signature.zig)。
//! Zig 侧这些 URL 已列入签名装饰器的强制列表,`signedPost` 先检查
//! `enableApiSignature` 是否已调用(快速失败,对应 Java 缺 rsaKeySn 时的
//! SecurityException),再走 base.post(装饰器加密)。access_token 附加、
//! -1 退避、token 失效重试与 Java 同(都经 executeWithRetry/executeInternal)。
//!
//! 与 Java 的差异(均已在对应位置注释):
//! - Java 用本地 Gson `LOWER_CASE_WITH_UNDERSCORES` 序列化/解析(无
//!   @SerializedName 的驼峰字段 → snake_case);Zig bean 字段本就是 snake_case,
//!   线上键名逐字段对齐(含 `payorderId`→`payorder_id` 与 `payOrderId`→
//!   `pay_order_id` 两种拼写的差异,按 Java 字段原名转换);
//! - errcode≠0 已由基座折叠为 `.err`,Java 的 checkStringResponse 不再需要;
//! - `queryStore` 缺 `store_list` 时 Java 会 NPE(getAsJsonArray 返回 null),
//!   Zig 归一化为空列表;`getCity` 缺 `support_list` 同理;
//! - `createStore`/`storeCharge` 缺字符串字段时 Java 返回 null,Zig 返回
//!   `.err`(internal),宁可不交 null 给调用方;
//! - `storeRefund` 缺 `refund_amount` 时 Java NPE,Zig 返回 `.err`;
//! - `WxMaStoreFlowResponse<T>` 的三个记录子类(充值/退款/消费)在 Zig 合成
//!   单个 `FlowRecord`(字段超集全可选)——线上 JSON 同构,不再区分泛型;
//! - `updateStore` 的 order_pattern:Java 对 int 原始值判断 `==1 || ==2`
//!   (默认 1 → 恒发送出),按原样保留该 quirk。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;
const service_mod = @import("service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;
const MiniappService = service_mod.MiniappService;

const APPLY_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/apply";
const CREATE_STORE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/createstore";
const QUERY_STORE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/querystore";
const UPDATE_STORE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/updatestore";
const STORE_CHARGE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/storecharge";
const STORE_REFUND_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/storerefund";
const QUERY_FLOW_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/queryflow";
const BALANCE_QUERY_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/balancequery";
const GET_PAY_MODE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/getpaymode";
const SET_PAY_MODE_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/setpaymode";
const PRE_ADD_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/preaddorder";
const ADD_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/addorder";
const QUERY_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/queryorder";
const CANCEL_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/cancelorder";
const GET_CITY_URL = "https://api.weixin.qq.com/cgi-bin/express/intracity/getcity";

// --- 序列化/解析辅助(与 product_order.zig 同构)--------------------------------

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

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

/// f64 字段(lat/lng 等):接受 float/integer/数字串。
fn getF64(v: std.json.Value, key: []const u8) ?f64 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const c = o.get(key) orelse return null;
    return switch (c) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn dupArray(comptime T: type, gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value), comptime parseFn: fn (std.mem.Allocator, std.json.Value) anyerror!T) ![]T {
    const list = try gpa.alloc(T, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*x| x.deinit();
        gpa.free(list);
    }
    for (arr.items) |item| {
        list[filled] = try parseFn(gpa, item);
        filled += 1;
    }
    return list;
}

// --- bean(请求:借用字符串;回包:gpa 拥有)--------------------------------------

/// 充值、扣费主体 —— 对应 `PayMode`(enum,均带 @SerializedName)。
pub const PayMode = enum {
    store,
    app,
    component,

    pub fn tag(self: PayMode) []const u8 {
        return switch (self) {
            .store => "PAY_MODE_STORE",
            .app => "PAY_MODE_APP",
            .component => "PAY_MODE_COMPONENT",
        };
    }

    pub fn parse(s: []const u8) ?PayMode {
        if (std.mem.eql(u8, s, "PAY_MODE_STORE")) return .store;
        if (std.mem.eql(u8, s, "PAY_MODE_APP")) return .app;
        if (std.mem.eql(u8, s, "PAY_MODE_COMPONENT")) return .component;
        return null; // Gson 对未知枚举名静默回 null,行为一致
    }
};

/// 地址 —— 对应 `WxMaStore.AddressInfo`(lat/lng 为 double 原始值,Gson 恒序列化)。
pub const AddressInfo = struct {
    gpa: ?std.mem.Allocator = null,
    province: ?[]const u8 = null,
    city: ?[]const u8 = null,
    area: ?[]const u8 = null,
    street: ?[]const u8 = null,
    house: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    lat: f64 = 0,
    lng: f64 = 0,

    pub fn deinit(self: *AddressInfo) void {
        const g = self.gpa orelse return;
        if (self.province) |s| g.free(@constCast(s));
        if (self.city) |s| g.free(@constCast(s));
        if (self.area) |s| g.free(@constCast(s));
        if (self.street) |s| g.free(@constCast(s));
        if (self.house) |s| g.free(@constCast(s));
        if (self.phone) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AddressInfo) void {
        const g = self.gpa orelse return;
        if (self.province) |s| g.free(s);
        if (self.city) |s| g.free(s);
        if (self.area) |s| g.free(s);
        if (self.street) |s| g.free(s);
        if (self.house) |s| g.free(s);
        if (self.phone) |s| g.free(s);
    }

    fn writeJson(self: *const AddressInfo, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.province) |v| {
            try w.writeAll("\"province\":");
            try js(w, v);
            sep = true;
        }
        if (self.city) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"city\":");
            try js(w, v);
            sep = true;
        }
        if (self.area) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"area\":");
            try js(w, v);
            sep = true;
        }
        if (self.street) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"street\":");
            try js(w, v);
            sep = true;
        }
        if (self.house) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"house\":");
            try js(w, v);
            sep = true;
        }
        if (self.phone) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"phone\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"lat\":{d},\"lng\":{d}}}", .{ self.lat, self.lng });
    }
};

fn parseAddressInfo(gpa: std.mem.Allocator, v: std.json.Value) !AddressInfo {
    var out = AddressInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.province = try looseStr(gpa, v, "province");
    out.city = try looseStr(gpa, v, "city");
    out.area = try looseStr(gpa, v, "area");
    out.street = try looseStr(gpa, v, "street");
    out.house = try looseStr(gpa, v, "house");
    out.phone = try looseStr(gpa, v, "phone");
    out.lat = getF64(v, "lat") orelse 0;
    out.lng = getF64(v, "lng") orelse 0;
    return out;
}

/// 门店 —— 对应 `WxMaStore`。请求(createStore/updateStore)与回包共用;
/// 请求实例 `gpa = null`(deinit 为 no-op),回包解析时注入 gpa。
/// Java 字段 `ServiceTransPrefer` 首字母大写的 quirk:Gson 转换结果同为
/// `service_trans_prefer`,Zig 直接用规范命名。
pub const Store = struct {
    gpa: ?std.mem.Allocator = null,
    wx_store_id: ?[]const u8 = null,
    out_store_id: ?[]const u8 = null,
    store_name: ?[]const u8 = null,
    city_id: ?[]const u8 = null,
    order_pattern: i64 = 1, // Java int 原始值默认 1
    service_trans_prefer: ?[]const u8 = null,
    address_info: ?AddressInfo = null,

    pub fn deinit(self: *Store) void {
        const g = self.gpa orelse return;
        if (self.wx_store_id) |s| g.free(@constCast(s));
        if (self.out_store_id) |s| g.free(@constCast(s));
        if (self.store_name) |s| g.free(@constCast(s));
        if (self.city_id) |s| g.free(@constCast(s));
        if (self.service_trans_prefer) |s| g.free(@constCast(s));
        if (self.address_info) |*a| a.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const Store) void {
        const g = self.gpa orelse return;
        if (self.wx_store_id) |s| g.free(s);
        if (self.out_store_id) |s| g.free(s);
        if (self.store_name) |s| g.free(s);
        if (self.city_id) |s| g.free(s);
        if (self.service_trans_prefer) |s| g.free(s);
        if (self.address_info) |*a| a.deinitConst();
    }

    /// 对应 Gson LOWER_CASE_WITH_UNDERSCORES 序列化(跳过 null;order_pattern
    /// 为 int 原始值恒序列化;lat/lng 同理)。
    pub fn to_json(self: *const Store, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var sep = false;
        if (self.wx_store_id) |v| {
            try w.writeAll("\"wx_store_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.out_store_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"out_store_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.store_name) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"store_name\":");
            try js(w, v);
            sep = true;
        }
        if (self.city_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"city_id\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"order_pattern\":{d}", .{self.order_pattern});
        if (self.service_trans_prefer) |v| {
            try w.writeAll(",\"service_trans_prefer\":");
            try js(w, v);
        }
        if (self.address_info) |*a| {
            try w.writeAll(",\"address_info\":");
            try a.writeJson(w);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

fn parseStore(gpa: std.mem.Allocator, v: std.json.Value) !Store {
    var out = Store{ .gpa = gpa };
    errdefer out.deinit();
    out.wx_store_id = try looseStr(gpa, v, "wx_store_id");
    out.out_store_id = try looseStr(gpa, v, "out_store_id");
    out.store_name = try looseStr(gpa, v, "store_name");
    out.city_id = try looseStr(gpa, v, "city_id");
    out.order_pattern = json_util.getInt(v, "order_pattern") orelse 1;
    out.service_trans_prefer = try looseStr(gpa, v, "service_trans_prefer");
    if (json_util.getObject(v, "address_info")) |av| out.address_info = try parseAddressInfo(gpa, av);
    return out;
}

/// 充值/退款请求公共字段(Java 基类 `BasicWxMaStoreChargeRefundRequest`
/// + 子类;Zig 拆成两个平铺结构)。
pub const StoreChargeRequest = struct {
    wx_store_id: ?[]const u8 = null,
    pay_mode: ?PayMode = null,
    service_trans_id: ?[]const u8 = null,
    /// 充值金额(单位:分;微信要求单笔 ≥ 5000,由服务端校验)。
    amount: i64 = 0, // Java int 原始值,恒序列化

    pub fn to_json(self: *const StoreChargeRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var sep = false;
        if (self.wx_store_id) |v| {
            try w.writeAll("\"wx_store_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.pay_mode) |p| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"pay_mode\":");
            try js(w, p.tag());
            sep = true;
        }
        if (self.service_trans_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"service_trans_id\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"amount\":{d}}}", .{self.amount});
        return out.toOwnedSlice();
    }
};

/// 对应 `WxMaStoreRefundRequest`(子类无额外字段)。
pub const StoreRefundRequest = struct {
    wx_store_id: ?[]const u8 = null,
    pay_mode: ?PayMode = null,
    service_trans_id: ?[]const u8 = null,

    pub fn to_json(self: *const StoreRefundRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var sep = false;
        if (self.wx_store_id) |v| {
            try w.writeAll("\"wx_store_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.pay_mode) |p| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"pay_mode\":");
            try js(w, p.tag());
            sep = true;
        }
        if (self.service_trans_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"service_trans_id\":");
            try js(w, v);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 流水查询请求 —— 对应 `WxMaQueryFlowRequest`。Java 的 beginDate/endDate
/// 是 transient(不序列化),只发 begin_time/end_time(long 原始值恒发送);
/// flow_type:1=充值 2=退款 3=消费流水。
pub const QueryFlowRequest = struct {
    wx_store_id: ?[]const u8 = null,
    flow_type: i64 = 1,
    service_trans_id: ?[]const u8 = null,
    begin_time: i64 = 0,
    end_time: i64 = 0,

    pub fn to_json(self: *const QueryFlowRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var sep = false;
        if (self.wx_store_id) |v| {
            try w.writeAll("\"wx_store_id\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"flow_type\":{d}", .{self.flow_type});
        if (self.service_trans_id) |v| {
            try w.writeAll(",\"service_trans_id\":");
            try js(w, v);
        }
        try w.print(",\"begin_time\":{d},\"end_time\":{d}}}", .{ self.begin_time, self.end_time });
        return out.toOwnedSlice();
    }
};

/// 流水记录 —— Java 三个子类(Charge/Refund/Consume)的 Zig 合成超集,
/// 全字段可选(对应 `WxMaStoreFlowResponse.BasicFlowRecord` 及其子类;
/// payOrderId 拼写 → `pay_order_id`)。
pub const FlowRecord = struct {
    gpa: std.mem.Allocator,
    flow_type: ?i64 = null,
    appid: ?[]const u8 = null,
    wx_store_id: ?[]const u8 = null,
    pay_order_id: ?[]const u8 = null,
    service_trans_id: ?[]const u8 = null,
    pay_amount: ?i64 = null,
    pay_time: ?i64 = null,
    create_time: ?i64 = null,
    // 充值(Charge):
    pay_status: ?[]const u8 = null,
    consume_deadline: ?i64 = null,
    // 退款(Refund):
    refund_amount: ?i64 = null,
    refund_time: ?i64 = null,
    // 消费(Consume):
    wx_order_id: ?[]const u8 = null,
    openid: ?[]const u8 = null,
    delivery_status: ?[]const u8 = null,
    refund_status: ?[]const u8 = null,
    deduct_amount: ?i64 = null,
    bill_id: ?[]const u8 = null,
    delivery_finished_time: ?i64 = null,

    pub fn deinit(self: *FlowRecord) void {
        const g = self.gpa;
        for ([_]*?[]const u8{ &self.appid, &self.wx_store_id, &self.pay_order_id, &self.service_trans_id, &self.pay_status, &self.wx_order_id, &self.openid, &self.delivery_status, &self.refund_status, &self.bill_id }) |f| {
            if (f.*) |s| g.free(@constCast(s));
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const FlowRecord) void {
        const g = self.gpa;
        for ([_]*const ?[]const u8{ &self.appid, &self.wx_store_id, &self.pay_order_id, &self.service_trans_id, &self.pay_status, &self.wx_order_id, &self.openid, &self.delivery_status, &self.refund_status, &self.bill_id }) |f| {
            if (f.*) |s| g.free(s);
        }
    }
};

fn parseFlowRecord(gpa: std.mem.Allocator, v: std.json.Value) !FlowRecord {
    var out = FlowRecord{ .gpa = gpa };
    errdefer out.deinit();
    out.flow_type = json_util.getInt(v, "flow_type");
    out.appid = try looseStr(gpa, v, "appid");
    out.wx_store_id = try looseStr(gpa, v, "wx_store_id");
    out.pay_order_id = try looseStr(gpa, v, "pay_order_id");
    out.service_trans_id = try looseStr(gpa, v, "service_trans_id");
    out.pay_amount = json_util.getInt(v, "pay_amount");
    out.pay_time = json_util.getInt(v, "pay_time");
    out.create_time = json_util.getInt(v, "create_time");
    out.pay_status = try looseStr(gpa, v, "pay_status");
    out.consume_deadline = json_util.getInt(v, "consume_deadline");
    out.refund_amount = json_util.getInt(v, "refund_amount");
    out.refund_time = json_util.getInt(v, "refund_time");
    out.wx_order_id = try looseStr(gpa, v, "wx_order_id");
    out.openid = try looseStr(gpa, v, "openid");
    out.delivery_status = try looseStr(gpa, v, "delivery_status");
    out.refund_status = try looseStr(gpa, v, "refund_status");
    out.deduct_amount = json_util.getInt(v, "deduct_amount");
    out.bill_id = try looseStr(gpa, v, "bill_id");
    out.delivery_finished_time = json_util.getInt(v, "delivery_finished_time");
    return out;
}

/// 流水查询回包 —— 对应 `WxMaStoreFlowResponse<T>`(total* 为 Long 可空,
/// 查询消费流水才返回 total_deduct_amt)。
pub const FlowResponse = struct {
    gpa: std.mem.Allocator,
    total_pay_amt: ?i64 = null,
    total_refund_amt: ?i64 = null,
    total_deduct_amt: ?i64 = null,
    flow_list: []FlowRecord = &[_]FlowRecord{},

    pub fn deinit(self: *FlowResponse) void {
        for (self.flow_list) |*r| r.deinit();
        self.gpa.free(self.flow_list);
        self.* = undefined;
    }
};

/// 余额明细里的充值单 —— 对应 `WxMaStoreBalance.BalanceDetail.OrderDetail`
/// (Java 字段 `payorderId` 小写 o 的 quirk → `payorder_id`)。
pub const BalanceOrder = struct {
    gpa: std.mem.Allocator,
    payorder_id: ?[]const u8 = null,
    charge_amt: ?i64 = null,
    unused_amt: ?i64 = null,
    begin_time: ?i64 = null,
    end_time: ?i64 = null,

    pub fn deinit(self: *BalanceOrder) void {
        const g = self.gpa;
        if (self.payorder_id) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BalanceOrder) void {
        const g = self.gpa;
        if (self.payorder_id) |s| g.free(s);
    }
};

fn parseBalanceOrder(gpa: std.mem.Allocator, v: std.json.Value) !BalanceOrder {
    var out = BalanceOrder{ .gpa = gpa };
    errdefer out.deinit();
    out.payorder_id = try looseStr(gpa, v, "payorder_id");
    out.charge_amt = json_util.getInt(v, "charge_amt");
    out.unused_amt = json_util.getInt(v, "unused_amt");
    out.begin_time = json_util.getInt(v, "begin_time");
    out.end_time = json_util.getInt(v, "end_time");
    return out;
}

/// 对应 `WxMaStoreBalance.BalanceDetail`。
pub const BalanceDetail = struct {
    gpa: std.mem.Allocator,
    balance: ?i64 = null,
    service_trans_id: ?[]const u8 = null,
    service_trans_name: ?[]const u8 = null,
    order_list: []BalanceOrder = &[_]BalanceOrder{},

    pub fn deinit(self: *BalanceDetail) void {
        const g = self.gpa;
        if (self.service_trans_id) |s| g.free(@constCast(s));
        if (self.service_trans_name) |s| g.free(@constCast(s));
        for (self.order_list) |*o| o.deinit();
        g.free(self.order_list);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BalanceDetail) void {
        const g = self.gpa;
        if (self.service_trans_id) |s| g.free(s);
        if (self.service_trans_name) |s| g.free(s);
        for (self.order_list) |*o| o.deinitConst();
        g.free(self.order_list);
    }
};

fn parseBalanceDetail(gpa: std.mem.Allocator, v: std.json.Value) !BalanceDetail {
    var out = BalanceDetail{ .gpa = gpa };
    errdefer out.deinit();
    out.balance = json_util.getInt(v, "balance");
    out.service_trans_id = try looseStr(gpa, v, "service_trans_id");
    out.service_trans_name = try looseStr(gpa, v, "service_trans_name");
    if (json_util.getArray(v, "order_list")) |arr| out.order_list = try dupArray(BalanceOrder, gpa, arr, parseBalanceOrder);
    return out;
}

/// 余额查询回包 —— 对应 `WxMaStoreBalance`。
pub const StoreBalance = struct {
    gpa: std.mem.Allocator,
    wx_store_id: ?[]const u8 = null,
    appid: ?[]const u8 = null,
    all_balance: ?i64 = null,
    balance_detail: []BalanceDetail = &[_]BalanceDetail{},

    pub fn deinit(self: *StoreBalance) void {
        const g = self.gpa;
        if (self.wx_store_id) |s| g.free(@constCast(s));
        if (self.appid) |s| g.free(@constCast(s));
        for (self.balance_detail) |*d| d.deinit();
        g.free(self.balance_detail);
        self.* = undefined;
    }
};

/// 支付方式查询回包 —— 对应 `WxMaGetPayModeResponse`。
pub const GetPayModeResponse = struct {
    gpa: std.mem.Allocator,
    pay_mode: ?PayMode = null,
    pay_appid: ?[]const u8 = null,
    component_appid: ?[]const u8 = null,

    pub fn deinit(self: *GetPayModeResponse) void {
        const g = self.gpa;
        if (self.pay_appid) |s| g.free(@constCast(s));
        if (self.component_appid) |s| g.free(@constCast(s));
        self.* = undefined;
    }
};

/// 货品 —— 对应 `BasicWxMaOrder.Cargo` / `WxMaAddOrderRequest.Cargo`(含
/// item_list 超集;preAddOrder 侧 Java 类型无 itemList,调用方不填即可)。
/// 请求实例 gpa = null;回包 cargo_info 解析时注入 gpa。
pub const Cargo = struct {
    gpa: ?std.mem.Allocator = null,
    cargo_name: ?[]const u8 = null,
    cargo_weight: i64 = 0, // Java int 原始值,恒序列化
    cargo_type: i64 = 0,
    cargo_num: i64 = 0,
    cargo_price: i64 = 0,
    item_list: []const ItemDetail = &[_]ItemDetail{},

    pub fn deinit(self: *Cargo) void {
        const g = self.gpa orelse return;
        if (self.cargo_name) |s| g.free(@constCast(s));
        for (self.item_list) |*i| i.deinitConst();
        g.free(@constCast(self.item_list));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const Cargo) void {
        const g = self.gpa orelse return;
        if (self.cargo_name) |s| g.free(s);
        for (self.item_list) |*i| i.deinitConst();
        g.free(self.item_list);
    }

    fn writeJson(self: *const Cargo, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.cargo_name) |v| {
            try w.writeAll("\"cargo_name\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"cargo_weight\":{d},\"cargo_type\":{d},\"cargo_num\":{d},\"cargo_price\":{d}", .{ self.cargo_weight, self.cargo_type, self.cargo_num, self.cargo_price });
        if (self.item_list.len > 0) {
            try w.writeAll(",\"item_list\":[");
            for (self.item_list, 0..) |*item, i| {
                if (i > 0) try w.writeAll(",");
                try item.writeJson(w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
};

fn parseCargo(gpa: std.mem.Allocator, v: std.json.Value) !Cargo {
    var out = Cargo{ .gpa = gpa };
    errdefer out.deinit();
    out.cargo_name = try looseStr(gpa, v, "cargo_name");
    out.cargo_weight = json_util.getInt(v, "cargo_weight") orelse 0;
    out.cargo_type = json_util.getInt(v, "cargo_type") orelse 0;
    out.cargo_num = json_util.getInt(v, "cargo_num") orelse 0;
    out.cargo_price = json_util.getInt(v, "cargo_price") orelse 0;
    if (json_util.getArray(v, "item_list")) |arr| {
        const list = try gpa.alloc(ItemDetail, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*x| x.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseItemDetail(gpa, item);
            filled += 1;
        }
        out.item_list = list;
    }
    return out;
}

/// 货品明细 —— 对应 `WxMaAddOrderRequest.ItemDetail`(仅请求侧使用;
/// 回包 cargo_info 不含 item_list,但合成 Cargo 解析器一并支持)。
pub const ItemDetail = struct {
    gpa: ?std.mem.Allocator = null,
    item_name: ?[]const u8 = null,
    item_pic_url: ?[]const u8 = null,
    count: i64 = 0, // Java int 原始值,恒序列化

    pub fn deinit(self: *ItemDetail) void {
        const g = self.gpa orelse return;
        if (self.item_name) |s| g.free(@constCast(s));
        if (self.item_pic_url) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const ItemDetail) void {
        const g = self.gpa orelse return;
        if (self.item_name) |s| g.free(s);
        if (self.item_pic_url) |s| g.free(s);
    }

    fn writeJson(self: *const ItemDetail, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.item_name) |v| {
            try w.writeAll("\"item_name\":");
            try js(w, v);
            sep = true;
        }
        if (self.item_pic_url) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"item_pic_url\":");
            try js(w, v);
            sep = true;
        }
        if (sep) try w.writeAll(",");
        try w.print("\"count\":{d}}}", .{self.count});
    }
};

fn parseItemDetail(gpa: std.mem.Allocator, v: std.json.Value) !ItemDetail {
    var out = ItemDetail{ .gpa = gpa };
    errdefer out.deinit();
    out.item_name = try looseStr(gpa, v, "item_name");
    out.item_pic_url = try looseStr(gpa, v, "item_pic_url");
    out.count = json_util.getInt(v, "count") orelse 0;
    return out;
}

/// BasicWxMaOrder 字段写入(preAddOrder/addOrder 请求共用;
/// user_lng/user_lat 为 double 原始值,恒序列化)。
fn writeBasicOrderFields(self: anytype, w: *std.Io.Writer) !void {
    var sep = false;
    if (self.wx_store_id) |v| {
        try w.writeAll("\"wx_store_id\":");
        try js(w, v);
        sep = true;
    }
    if (self.user_name) |v| {
        if (sep) try w.writeAll(",");
        try w.writeAll("\"user_name\":");
        try js(w, v);
        sep = true;
    }
    if (self.user_phone) |v| {
        if (sep) try w.writeAll(",");
        try w.writeAll("\"user_phone\":");
        try js(w, v);
        sep = true;
    }
    if (sep) try w.writeAll(",");
    try w.print("\"user_lng\":{d},\"user_lat\":{d}", .{ self.user_lng, self.user_lat });
    if (self.user_address) |v| {
        try w.writeAll(",\"user_address\":");
        try js(w, v);
    }
    if (self.use_sandbox) |v| {
        try w.print(",\"use_sandbox\":{d}", .{v});
    }
}

/// 预下单请求 —— 对应 `WxMaPreAddOrderRequest`(BasicWxMaOrder + cargo)。
pub const PreAddOrderRequest = struct {
    wx_store_id: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    user_phone: ?[]const u8 = null,
    user_lng: f64 = 0,
    user_lat: f64 = 0,
    user_address: ?[]const u8 = null,
    use_sandbox: ?i64 = null,
    cargo: ?*const Cargo = null,

    pub fn to_json(self: *const PreAddOrderRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        try writeBasicOrderFields(self, w);
        if (self.cargo) |c| {
            try w.writeAll(",\"cargo\":");
            try c.writeJson(w);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 预下单回包 —— 对应 `WxMaPreAddOrderResponse`。
pub const PreAddOrderResponse = struct {
    gpa: std.mem.Allocator,
    service_trans_id: ?[]const u8 = null,
    distance: ?i64 = null,
    est_fee: ?i64 = null,
    expected_finished_time: ?i64 = null,
    promise_delivery_time: ?i64 = null,

    pub fn deinit(self: *PreAddOrderResponse) void {
        const g = self.gpa;
        if (self.service_trans_id) |s| g.free(@constCast(s));
        self.* = undefined;
    }
};

/// 下单请求 —— 对应 `WxMaAddOrderRequest`(BasicWxMaOrder + 下单字段 +
/// 含 item_list 的 cargo)。
pub const AddOrderRequest = struct {
    wx_store_id: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    user_phone: ?[]const u8 = null,
    user_lng: f64 = 0,
    user_lat: f64 = 0,
    user_address: ?[]const u8 = null,
    use_sandbox: ?i64 = null,
    store_order_id: ?[]const u8 = null,
    user_openid: ?[]const u8 = null,
    order_seq: ?[]const u8 = null,
    verify_code_type: i64 = 0, // Java int 原始值,恒序列化
    order_detail_path: ?[]const u8 = null,
    callback_url: ?[]const u8 = null,
    cargo: ?*const Cargo = null,

    pub fn to_json(self: *const AddOrderRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        try writeBasicOrderFields(self, w);
        if (self.store_order_id) |v| {
            try w.writeAll(",\"store_order_id\":");
            try js(w, v);
        }
        if (self.user_openid) |v| {
            try w.writeAll(",\"user_openid\":");
            try js(w, v);
        }
        if (self.order_seq) |v| {
            try w.writeAll(",\"order_seq\":");
            try js(w, v);
        }
        try w.print(",\"verify_code_type\":{d}", .{self.verify_code_type});
        if (self.order_detail_path) |v| {
            try w.writeAll(",\"order_detail_path\":");
            try js(w, v);
        }
        if (self.callback_url) |v| {
            try w.writeAll(",\"callback_url\":");
            try js(w, v);
        }
        if (self.cargo) |c| {
            try w.writeAll(",\"cargo\":");
            try c.writeJson(w);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 下单回包 —— 对应 `WxMaAddOrderResponse`。
pub const AddOrderResponse = struct {
    gpa: std.mem.Allocator,
    wx_order_id: ?[]const u8 = null,
    store_order_id: ?[]const u8 = null,
    wx_store_id: ?[]const u8 = null,
    service_trans_id: ?[]const u8 = null,
    distance: ?i64 = null,
    trans_order_id: ?[]const u8 = null,
    waybill_id: ?[]const u8 = null,
    fee: ?i64 = null,
    fetch_code: ?[]const u8 = null,
    order_seq: ?[]const u8 = null,

    pub fn deinit(self: *AddOrderResponse) void {
        const g = self.gpa;
        for ([_]*?[]const u8{ &self.wx_order_id, &self.store_order_id, &self.wx_store_id, &self.service_trans_id, &self.trans_order_id, &self.waybill_id, &self.fetch_code, &self.order_seq }) |f| {
            if (f.*) |s| g.free(@constCast(s));
        }
        self.* = undefined;
    }
};

/// 配送员信息 —— 对应 `WxMaOrder.TransporterInfo`。
pub const TransporterInfo = struct {
    gpa: std.mem.Allocator,
    transporter_name: ?[]const u8 = null,
    transporter_phone: ?[]const u8 = null,

    pub fn deinit(self: *TransporterInfo) void {
        const g = self.gpa;
        if (self.transporter_name) |s| g.free(@constCast(s));
        if (self.transporter_phone) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const TransporterInfo) void {
        const g = self.gpa;
        if (self.transporter_name) |s| g.free(s);
        if (self.transporter_phone) |s| g.free(s);
    }
};

fn parseTransporterInfo(gpa: std.mem.Allocator, v: std.json.Value) !TransporterInfo {
    var out = TransporterInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.transporter_name = try looseStr(gpa, v, "transporter_name");
    out.transporter_phone = try looseStr(gpa, v, "transporter_phone");
    return out;
}

/// 门店信息 —— 对应 `WxMaOrder.StoreInfo`。
pub const OrderStoreInfo = struct {
    gpa: std.mem.Allocator,
    store_name: ?[]const u8 = null,
    wx_store_id: ?[]const u8 = null,
    address: ?[]const u8 = null,
    lng: f64 = 0,
    lat: f64 = 0,
    phone_num: ?[]const u8 = null,

    pub fn deinit(self: *OrderStoreInfo) void {
        const g = self.gpa;
        if (self.store_name) |s| g.free(@constCast(s));
        if (self.wx_store_id) |s| g.free(@constCast(s));
        if (self.address) |s| g.free(@constCast(s));
        if (self.phone_num) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const OrderStoreInfo) void {
        const g = self.gpa;
        if (self.store_name) |s| g.free(s);
        if (self.wx_store_id) |s| g.free(s);
        if (self.address) |s| g.free(s);
        if (self.phone_num) |s| g.free(s);
    }
};

fn parseOrderStoreInfo(gpa: std.mem.Allocator, v: std.json.Value) !OrderStoreInfo {
    var out = OrderStoreInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.store_name = try looseStr(gpa, v, "store_name");
    out.wx_store_id = try looseStr(gpa, v, "wx_store_id");
    out.address = try looseStr(gpa, v, "address");
    out.lng = getF64(v, "lng") orelse 0;
    out.lat = getF64(v, "lat") orelse 0;
    out.phone_num = try looseStr(gpa, v, "phone_num");
    return out;
}

/// 收件人信息 —— 对应 `WxMaOrder.ReceiverInfo`。
pub const ReceiverInfo = struct {
    gpa: std.mem.Allocator,
    receiver_name: ?[]const u8 = null,
    address: ?[]const u8 = null,
    phone_num: ?[]const u8 = null,
    lng: f64 = 0,
    lat: f64 = 0,

    pub fn deinit(self: *ReceiverInfo) void {
        const g = self.gpa;
        if (self.receiver_name) |s| g.free(@constCast(s));
        if (self.address) |s| g.free(@constCast(s));
        if (self.phone_num) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const ReceiverInfo) void {
        const g = self.gpa;
        if (self.receiver_name) |s| g.free(s);
        if (self.address) |s| g.free(s);
        if (self.phone_num) |s| g.free(s);
    }
};

fn parseReceiverInfo(gpa: std.mem.Allocator, v: std.json.Value) !ReceiverInfo {
    var out = ReceiverInfo{ .gpa = gpa };
    errdefer out.deinit();
    out.receiver_name = try looseStr(gpa, v, "receiver_name");
    out.address = try looseStr(gpa, v, "address");
    out.phone_num = try looseStr(gpa, v, "phone_num");
    out.lng = getF64(v, "lng") orelse 0;
    out.lat = getF64(v, "lat") orelse 0;
    return out;
}

/// 订单详情 —— 对应 `WxMaOrder`(继承 WxMaAddOrderRequest/BasicWxMaOrder,
/// Zig 平铺全部字段;请求侧字段在回包里同样可能出现,全可选)。
pub const Order = struct {
    gpa: std.mem.Allocator,
    // BasicWxMaOrder:
    wx_store_id: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    user_phone: ?[]const u8 = null,
    user_lng: f64 = 0,
    user_lat: f64 = 0,
    user_address: ?[]const u8 = null,
    use_sandbox: ?i64 = null,
    // WxMaAddOrderRequest:
    store_order_id: ?[]const u8 = null,
    user_openid: ?[]const u8 = null,
    order_seq: ?[]const u8 = null,
    verify_code_type: ?i64 = null,
    order_detail_path: ?[]const u8 = null,
    callback_url: ?[]const u8 = null,
    // WxMaOrder:
    wx_order_id: ?[]const u8 = null,
    order_status: ?i64 = null,
    appid: ?[]const u8 = null,
    service_trans_id: ?[]const u8 = null,
    delivery_no: ?[]const u8 = null,
    actualfee: ?i64 = null,
    deductfee: ?i64 = null,
    distance: ?i64 = null,
    create_time: ?i64 = null,
    accept_time: ?i64 = null,
    fetch_time: ?i64 = null,
    finish_time: ?i64 = null,
    cancel_time: ?i64 = null,
    expected_finish_time: ?i64 = null,
    fetch_code: ?[]const u8 = null,
    recv_code: ?[]const u8 = null,
    transporter_info: ?TransporterInfo = null,
    store_info: ?OrderStoreInfo = null,
    receiver_info: ?ReceiverInfo = null,
    cargo_info: ?Cargo = null,

    pub fn deinit(self: *Order) void {
        const g = self.gpa;
        for ([_]*?[]const u8{
            &self.wx_store_id,    &self.user_name,   &self.user_phone, &self.user_address,
            &self.store_order_id, &self.user_openid, &self.order_seq,  &self.order_detail_path,
            &self.callback_url,   &self.wx_order_id, &self.appid,      &self.service_trans_id,
            &self.delivery_no,    &self.fetch_code,  &self.recv_code,
        }) |f| {
            if (f.*) |s| g.free(@constCast(s));
        }
        if (self.transporter_info) |*t| t.deinit();
        if (self.store_info) |*s| s.deinit();
        if (self.receiver_info) |*r| r.deinit();
        if (self.cargo_info) |*c| c.deinit();
        self.* = undefined;
    }
};

fn parseOrder(gpa: std.mem.Allocator, v: std.json.Value) !Order {
    var out = Order{ .gpa = gpa };
    errdefer out.deinit();
    out.wx_store_id = try looseStr(gpa, v, "wx_store_id");
    out.user_name = try looseStr(gpa, v, "user_name");
    out.user_phone = try looseStr(gpa, v, "user_phone");
    out.user_lng = getF64(v, "user_lng") orelse 0;
    out.user_lat = getF64(v, "user_lat") orelse 0;
    out.user_address = try looseStr(gpa, v, "user_address");
    out.use_sandbox = json_util.getInt(v, "use_sandbox");
    out.store_order_id = try looseStr(gpa, v, "store_order_id");
    out.user_openid = try looseStr(gpa, v, "user_openid");
    out.order_seq = try looseStr(gpa, v, "order_seq");
    out.verify_code_type = json_util.getInt(v, "verify_code_type");
    out.order_detail_path = try looseStr(gpa, v, "order_detail_path");
    out.callback_url = try looseStr(gpa, v, "callback_url");
    out.wx_order_id = try looseStr(gpa, v, "wx_order_id");
    out.order_status = json_util.getInt(v, "order_status");
    out.appid = try looseStr(gpa, v, "appid");
    out.service_trans_id = try looseStr(gpa, v, "service_trans_id");
    out.delivery_no = try looseStr(gpa, v, "delivery_no");
    out.actualfee = json_util.getInt(v, "actualfee");
    out.deductfee = json_util.getInt(v, "deductfee");
    out.distance = json_util.getInt(v, "distance");
    out.create_time = json_util.getInt(v, "create_time");
    out.accept_time = json_util.getInt(v, "accept_time");
    out.fetch_time = json_util.getInt(v, "fetch_time");
    out.finish_time = json_util.getInt(v, "finish_time");
    out.cancel_time = json_util.getInt(v, "cancel_time");
    out.expected_finish_time = json_util.getInt(v, "expected_finish_time");
    out.fetch_code = try looseStr(gpa, v, "fetch_code");
    out.recv_code = try looseStr(gpa, v, "recv_code");
    if (json_util.getObject(v, "transporter_info")) |tv| out.transporter_info = try parseTransporterInfo(gpa, tv);
    if (json_util.getObject(v, "store_info")) |sv| out.store_info = try parseOrderStoreInfo(gpa, sv);
    if (json_util.getObject(v, "receiver_info")) |rv| out.receiver_info = try parseReceiverInfo(gpa, rv);
    if (json_util.getObject(v, "cargo_info")) |cv| out.cargo_info = try parseCargo(gpa, cv);
    return out;
}

/// 取消订单回包 —— 对应 `WxMaCancelOrderResponse`(order_status 为 String,
/// 微信可能回数字 → looseStr)。
pub const CancelOrderResponse = struct {
    gpa: std.mem.Allocator,
    wx_order_id: ?[]const u8 = null,
    store_order_id: ?[]const u8 = null,
    wx_store_id: ?[]const u8 = null,
    order_status: ?[]const u8 = null,
    appid: ?[]const u8 = null,
    deductfee: ?i64 = null,

    pub fn deinit(self: *CancelOrderResponse) void {
        const g = self.gpa;
        for ([_]*?[]const u8{ &self.wx_order_id, &self.store_order_id, &self.wx_store_id, &self.order_status, &self.appid }) |f| {
            if (f.*) |s| g.free(@constCast(s));
        }
        self.* = undefined;
    }
};

/// 支持城市 —— 对应 `WxMaTransCity.City`。
pub const TransCity = struct {
    gpa: std.mem.Allocator,
    city_name: ?[]const u8 = null,
    city_code: ?[]const u8 = null,

    pub fn deinit(self: *TransCity) void {
        const g = self.gpa;
        if (self.city_name) |s| g.free(@constCast(s));
        if (self.city_code) |s| g.free(@constCast(s));
        self.* = undefined;
    }
};

fn parseCityEntry(gpa: std.mem.Allocator, v: std.json.Value) !TransCity {
    var out = TransCity{ .gpa = gpa };
    errdefer out.deinit();
    out.city_name = try looseStr(gpa, v, "city_name");
    out.city_code = try looseStr(gpa, v, "city_code");
    return out;
}

/// getCity 回包条目 —— 对应 `WxMaTransCity`。
pub const TransCityEntry = struct {
    gpa: std.mem.Allocator,
    service_trans_id: ?[]const u8 = null,
    city_list: []TransCity = &[_]TransCity{},

    pub fn deinit(self: *TransCityEntry) void {
        const g = self.gpa;
        if (self.service_trans_id) |s| g.free(@constCast(s));
        for (self.city_list) |*c| c.deinit();
        g.free(self.city_list);
        self.* = undefined;
    }
};

/// getCity 回包 —— 对应 Java `List<WxMaTransCity>`(support_list)。
pub const CityList = struct {
    gpa: std.mem.Allocator,
    list: []TransCityEntry = &[_]TransCityEntry{},

    pub fn deinit(self: *CityList) void {
        for (self.list) |*e| e.deinit();
        self.gpa.free(self.list);
        self.* = undefined;
    }
};

/// queryStore 回包 —— 对应 Java `List<WxMaStore>`(store_list)。
pub const StoreList = struct {
    gpa: std.mem.Allocator,
    list: []Store = &[_]Store{},

    pub fn deinit(self: *StoreList) void {
        for (self.list) |*s| s.deinit();
        self.gpa.free(self.list);
        self.* = undefined;
    }
};

// --- 服务 ----------------------------------------------------------------------

pub const IntracityService = struct {
    ma: *MiniappService,

    /// 加密通道 POST(除 apply 外的全部方法走这里):未启用 API 签名时快速
    /// 失败(对应 Java 缺 ApiSignatureRsaPrivateKeySn 的 SecurityException);
    /// 已启用则 base.post —— 装饰器按 URL 强制列表透明加密。
    fn signedPost(self: *IntracityService, io: std.Io, url: []const u8, body: []const u8) WxResult([]u8) {
        if (self.ma.sig == null)
            return .{ .err = WxError.configError(self.ma.base.gpa, "同城配送接口要求服务端 API 签名,请先 enableApiSignature", .{}) };
        return self.ma.base.post(io, url, &.{}, body);
    }

    /// 开通上门服务 —— 对应 `apply()`。Java 走普通 `post(APPLY_URL, "{}")`
    /// (不加密;apply 不在签名列表),errcode 检查由基座折叠。
    pub fn apply(self: *IntracityService, io: std.Io) Done {
        const r = self.ma.base.post(io, APPLY_URL, &.{}, "{}");
        return switch (r) {
            .ok => |b| {
                self.ma.base.gpa.free(b);
                return .{ .ok = {} };
            },
            .err => |e| .{ .err = e },
        };
    }

    /// 创建门店 —— 对应 `createStore(WxMaStore)`。outStoreId 必填、wxStoreId
    /// 必须为 null(Java IllegalArgumentException → .err);回包取 `wx_store_id`
    /// (gpa 拥有,调用方 free;Java 缺失时返回 null,Zig 报错更诚实)。
    pub fn createStore(self: *IntracityService, io: std.Io, store: *const Store) WxResult([]u8) {
        const gpa = self.ma.base.gpa;
        if (store.out_store_id == null)
            return .{ .err = WxError.internal(gpa, "创建门店时outStoreId不能为空", .{}) };
        if (store.wx_store_id != null)
            return .{ .err = WxError.internal(gpa, "创建门店时wxStoreId只能是null", .{}) };
        const body = store.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, CREATE_STORE_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseSingleStrField(gpa, resp, "wx_store_id", "createstore");
    }

    /// 更新门店 —— 对应 `updateStore(WxMaStore)`。wxStoreId/outStoreId 至少一个;
    /// content 按字段跳过 null(order_pattern 为 1/2 才发 —— Java 原样 quirk:
    /// 默认值 1 也会发送)。
    pub fn updateStore(self: *IntracityService, io: std.Io, store: *const Store) Done {
        const gpa = self.ma.base.gpa;
        if (store.wx_store_id == null and store.out_store_id == null)
            return .{ .err = WxError.internal(gpa, "更新门店时wxStoreId 或 outStoreId 至少要有一个不为null", .{}) };
        const body = updateStoreBody(gpa, store) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const r = self.signedPost(io, UPDATE_STORE_URL, body);
        return switch (r) {
            .ok => |b| {
                gpa.free(b);
                return .{ .ok = {} };
            },
            .err => |e| .{ .err = e },
        };
    }

    /// 查询全部门店 —— 对应 `listAllStores()`(queryStore(null, null))。
    pub fn listAllStores(self: *IntracityService, io: std.Io) WxResult(StoreList) {
        return self.queryStore(io, null, null);
    }

    /// 按 wx_store_id 查询 —— 对应 `queryStoreByWxStoreId`(空列表 → null →
    /// Zig 返回 .ok null)。
    pub fn queryStoreByWxStoreId(self: *IntracityService, io: std.Io, wx_store_id: []const u8) WxResult(?Store) {
        var r = self.queryStore(io, wx_store_id, null);
        switch (r) {
            .ok => |*sl| {
                if (sl.list.len == 0) {
                    sl.deinit();
                    return .{ .ok = null };
                }
                // 转移 list[0] 所有权给调用方:释放其余记录与列表数组本身,
                // 再抹掉列表状态防止误 deinit 造成 double free。
                // 先拷出 list[0](浅拷,字符串仍归 gpa),再释放其余记录与数组
                // 本体;若先 free 数组再读 list[0] 就是 use-after-free。
                const out = sl.list[0];
                for (sl.list[1..]) |*s| s.deinit();
                sl.gpa.free(sl.list);
                sl.* = undefined;
                return .{ .ok = out };
            },
            .err => |e| return .{ .err = e },
        }
    }

    /// 按 out_store_id 查询 —— 对应 `queryStoreByOutStoreId`。
    pub fn queryStoreByOutStoreId(self: *IntracityService, io: std.Io, out_store_id: []const u8) WxResult(StoreList) {
        return self.queryStore(io, null, out_store_id);
    }

    /// 查询门店 —— 对应私有 `queryStore(wxStoreId, outStoreId)`:wxStoreId 优先,
    /// 两者都 null → `{}`(查全部)。回包缺 `store_list` 时 Java NPE,Zig
    /// 归一化为空列表。
    pub fn queryStore(self: *IntracityService, io: std.Io, wx_store_id: ?[]const u8, out_store_id: ?[]const u8) WxResult(StoreList) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        if (wx_store_id) |v| {
            ob.putStr("wx_store_id", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        } else if (out_store_id) |v| {
            ob.putStr("out_store_id", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, QUERY_STORE_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "querystore not json", .{}) };
        defer parsed.deinit();
        var out = StoreList{ .gpa = gpa };
        if (json_util.getArray(parsed.value, "store_list")) |arr| {
            out.list = dupArray(Store, gpa, arr, parseStore) catch
                return .{ .err = WxError.internal(gpa, "store list parse fail", .{}) };
        }
        return .{ .ok = out };
    }

    /// 门店充值 —— 对应 `storeCharge(WxMaStoreChargeRequest)`。回包取 `payurl`
    /// (gpa 拥有;Java 缺失时返回 null,Zig 报错)。
    pub fn storeCharge(self: *IntracityService, io: std.Io, req: *const StoreChargeRequest) WxResult([]u8) {
        const gpa = self.ma.base.gpa;
        const body = req.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, STORE_CHARGE_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseSingleStrField(gpa, resp, "payurl", "storecharge");
    }

    /// 门店退款 —— 对应 `storeRefund(WxMaStoreRefundRequest)`。回包取
    /// `refund_amount`(Java 缺失时 NPE,Zig 报 .err)。
    pub fn storeRefund(self: *IntracityService, io: std.Io, req: *const StoreRefundRequest) WxResult(i64) {
        const gpa = self.ma.base.gpa;
        const body = req.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, STORE_REFUND_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "storerefund not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = json_util.getInt(parsed.value, "refund_amount") orelse
            return .{ .err = WxError.internal(gpa, "storerefund 响应缺少 refund_amount", .{}) } };
    }

    /// 查询流水 —— 对应 `queryFlow(WxMaQueryFlowRequest)`。wxStoreId 必填、
    /// flowType ∈ 1/2/3(Java IllegalArgumentException → .err)。
    /// Java 泛型三记录类合成单个 FlowRecord(超集,见 bean 注释)。
    pub fn queryFlow(self: *IntracityService, io: std.Io, req: *const QueryFlowRequest) WxResult(FlowResponse) {
        const gpa = self.ma.base.gpa;
        if (req.wx_store_id == null)
            return .{ .err = WxError.internal(gpa, "查询请求 wxStoreId 不可为空", .{}) };
        if (req.flow_type != 1 and req.flow_type != 2 and req.flow_type != 3)
            return .{ .err = WxError.internal(gpa, "查询请求 flowType 不正确,只能是1、2、3之一", .{}) };
        const body = req.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, QUERY_FLOW_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "queryflow not json", .{}) };
        defer parsed.deinit();
        var out = FlowResponse{ .gpa = gpa };
        out.total_pay_amt = json_util.getInt(parsed.value, "total_pay_amt");
        out.total_refund_amt = json_util.getInt(parsed.value, "total_refund_amt");
        out.total_deduct_amt = json_util.getInt(parsed.value, "total_deduct_amt");
        if (json_util.getArray(parsed.value, "flow_list")) |arr| {
            out.flow_list = dupArray(FlowRecord, gpa, arr, parseFlowRecord) catch
                return .{ .err = WxError.internal(gpa, "flow list parse fail", .{}) };
        }
        return .{ .ok = out };
    }

    /// 余额查询 —— 对应 `balanceQuery(wxStoreId, serviceTransId, payMode)`。
    /// payMode 为 null/STORE 时必须传 wxStoreId(Java 校验 → .err)。
    pub fn balanceQuery(self: *IntracityService, io: std.Io, wx_store_id: ?[]const u8, service_trans_id: ?[]const u8, pay_mode: ?PayMode) WxResult(StoreBalance) {
        const gpa = self.ma.base.gpa;
        if (wx_store_id == null and (pay_mode == null or pay_mode == .store))
            return .{ .err = WxError.internal(gpa, "payMode是PAY_MODE_STORE或null时,必须传递wxStoreId", .{}) };
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        if (wx_store_id) |v| ob.putStr("wx_store_id", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (service_trans_id) |v| ob.putStr("service_trans_id", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (pay_mode) |p| ob.putStr("pay_mode", p.tag()) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, BALANCE_QUERY_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "balancequery not json", .{}) };
        defer parsed.deinit();
        var out = StoreBalance{ .gpa = gpa };
        errdefer out.deinit();
        out.wx_store_id = looseStr(gpa, parsed.value, "wx_store_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.appid = looseStr(gpa, parsed.value, "appid") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.all_balance = json_util.getInt(parsed.value, "all_balance");
        if (json_util.getArray(parsed.value, "balance_detail")) |arr| {
            out.balance_detail = dupArray(BalanceDetail, gpa, arr, parseBalanceDetail) catch
                return .{ .err = WxError.internal(gpa, "balance detail parse fail", .{}) };
        }
        return .{ .ok = out };
    }

    /// 设置支付方式 —— 对应 `setPayMode(PayMode)`(请求带配置里的 appid)。
    pub fn setPayMode(self: *IntracityService, io: std.Io, pay_mode: PayMode) Done {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("pay_mode", pay_mode.tag()) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("appid", self.ma.base.config.appid()) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const r = self.signedPost(io, SET_PAY_MODE_URL, body);
        return switch (r) {
            .ok => |b| {
                gpa.free(b);
                return .{ .ok = {} };
            },
            .err => |e| .{ .err = e },
        };
    }

    /// 查询支付方式 —— 对应 `getPayMode()`(请求带配置里的 appid)。
    pub fn getPayMode(self: *IntracityService, io: std.Io) WxResult(GetPayModeResponse) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("appid", self.ma.base.config.appid()) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, GET_PAY_MODE_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getpaymode not json", .{}) };
        defer parsed.deinit();
        var out = GetPayModeResponse{ .gpa = gpa };
        errdefer out.deinit();
        if (json_util.getStr(parsed.value, "pay_mode")) |tag| out.pay_mode = PayMode.parse(tag);
        out.pay_appid = looseStr(gpa, parsed.value, "pay_appid") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.component_appid = looseStr(gpa, parsed.value, "component_appid") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 预下单 —— 对应 `preAddOrder(WxMaPreAddOrderRequest)`。
    pub fn preAddOrder(self: *IntracityService, io: std.Io, req: *const PreAddOrderRequest) WxResult(PreAddOrderResponse) {
        const gpa = self.ma.base.gpa;
        const body = req.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, PRE_ADD_ORDER_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "preaddorder not json", .{}) };
        defer parsed.deinit();
        var out = PreAddOrderResponse{ .gpa = gpa };
        errdefer out.deinit();
        out.service_trans_id = looseStr(gpa, parsed.value, "service_trans_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.distance = json_util.getInt(parsed.value, "distance");
        out.est_fee = json_util.getInt(parsed.value, "est_fee");
        out.expected_finished_time = json_util.getInt(parsed.value, "expected_finished_time");
        out.promise_delivery_time = json_util.getInt(parsed.value, "promise_delivery_time");
        return .{ .ok = out };
    }

    /// 创建订单 —— 对应 `addOrder(WxMaAddOrderRequest)`。
    pub fn addOrder(self: *IntracityService, io: std.Io, req: *const AddOrderRequest) WxResult(AddOrderResponse) {
        const gpa = self.ma.base.gpa;
        const body = req.to_json(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, ADD_ORDER_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "addorder not json", .{}) };
        defer parsed.deinit();
        var out = AddOrderResponse{ .gpa = gpa };
        errdefer out.deinit();
        out.wx_order_id = looseStr(gpa, parsed.value, "wx_order_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.store_order_id = looseStr(gpa, parsed.value, "store_order_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.wx_store_id = looseStr(gpa, parsed.value, "wx_store_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.service_trans_id = looseStr(gpa, parsed.value, "service_trans_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.distance = json_util.getInt(parsed.value, "distance");
        out.trans_order_id = looseStr(gpa, parsed.value, "trans_order_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.waybill_id = looseStr(gpa, parsed.value, "waybill_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.fee = json_util.getInt(parsed.value, "fee");
        out.fetch_code = looseStr(gpa, parsed.value, "fetch_code") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.order_seq = looseStr(gpa, parsed.value, "order_seq") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 按 wx_order_id 查询订单 —— 对应 `queryOrderByWxOrderId`。
    pub fn queryOrderByWxOrderId(self: *IntracityService, io: std.Io, wx_order_id: []const u8) WxResult(Order) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("wx_order_id", wx_order_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.queryOrder(io, &ob);
    }

    /// 按 wx_store_id + store_order_id 查询订单 —— 对应 `queryOrderByStoreOrderId`。
    pub fn queryOrderByStoreOrderId(self: *IntracityService, io: std.Io, wx_store_id: []const u8, store_order_id: []const u8) WxResult(Order) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("wx_store_id", wx_store_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("store_order_id", store_order_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.queryOrder(io, &ob);
    }

    fn queryOrder(self: *IntracityService, io: std.Io, ob: *json_util.ObjectBuilder) WxResult(Order) {
        const gpa = self.ma.base.gpa;
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, QUERY_ORDER_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "queryorder not json", .{}) };
        defer parsed.deinit();
        const order = parseOrder(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "queryorder parse fail", .{}) };
        return .{ .ok = order };
    }

    /// 按 wx_order_id 取消订单 —— 对应 `cancelOrderByWxOrderId`(cancelReason
    /// 可选,非 null 才发送)。
    pub fn cancelOrderByWxOrderId(self: *IntracityService, io: std.Io, wx_order_id: []const u8, cancel_reason_id: i64, cancel_reason: ?[]const u8) WxResult(CancelOrderResponse) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("wx_order_id", wx_order_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("cancel_reason_id", cancel_reason_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (cancel_reason) |v| ob.putStr("cancel_reason", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.cancelOrder(io, &ob);
    }

    /// 按 wx_store_id + store_order_id 取消订单 —— 对应 `cancelOrderByStoreOrderId`。
    pub fn cancelOrderByStoreOrderId(self: *IntracityService, io: std.Io, wx_store_id: []const u8, store_order_id: []const u8, cancel_reason_id: i64, cancel_reason: ?[]const u8) WxResult(CancelOrderResponse) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("wx_store_id", wx_store_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("store_order_id", store_order_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("cancel_reason_id", cancel_reason_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (cancel_reason) |v| ob.putStr("cancel_reason", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.cancelOrder(io, &ob);
    }

    fn cancelOrder(self: *IntracityService, io: std.Io, ob: *json_util.ObjectBuilder) WxResult(CancelOrderResponse) {
        const gpa = self.ma.base.gpa;
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, CANCEL_ORDER_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cancelorder not json", .{}) };
        defer parsed.deinit();
        var out = CancelOrderResponse{ .gpa = gpa };
        errdefer out.deinit();
        out.wx_order_id = looseStr(gpa, parsed.value, "wx_order_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.store_order_id = looseStr(gpa, parsed.value, "store_order_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.wx_store_id = looseStr(gpa, parsed.value, "wx_store_id") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.order_status = looseStr(gpa, parsed.value, "order_status") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.appid = looseStr(gpa, parsed.value, "appid") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.deductfee = json_util.getInt(parsed.value, "deductfee");
        return .{ .ok = out };
    }

    /// 查询支持城市 —— 对应 `getCity(serviceTransId)`。回包缺 `support_list`
    /// 时 Java NPE,Zig 归一化为空列表。
    pub fn getCity(self: *IntracityService, io: std.Io, service_trans_id: ?[]const u8) WxResult(CityList) {
        const gpa = self.ma.base.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        if (service_trans_id) |v| ob.putStr("service_trans_id", v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.signedPost(io, GET_CITY_URL, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getcity not json", .{}) };
        defer parsed.deinit();
        var out = CityList{ .gpa = gpa };
        if (json_util.getArray(parsed.value, "support_list")) |arr| {
            var filled: usize = 0;
            for (arr.items) |item| {
                var entry = TransCityEntry{ .gpa = gpa };
                entry.service_trans_id = looseStr(gpa, item, "service_trans_id") catch {
                    entry.deinit();
                    for (out.list[0..filled]) |*e| e.deinit();
                    gpa.free(out.list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                if (json_util.getArray(item, "city_list")) |cities| {
                    entry.city_list = dupArray(TransCity, gpa, cities, parseCityEntry) catch {
                        entry.deinit();
                        for (out.list[0..filled]) |*e| e.deinit();
                        gpa.free(out.list);
                        return .{ .err = WxError.internal(gpa, "city list parse fail", .{}) };
                    };
                }
                if (filled == 0) {
                    out.list = gpa.alloc(TransCityEntry, arr.items.len) catch {
                        entry.deinit();
                        return .{ .err = WxError.internal(gpa, "oom", .{}) };
                    };
                }
                out.list[filled] = entry;
                filled += 1;
            }
        }
        return .{ .ok = out };
    }
};

/// 单字段字符串回包(跨加密通道,响应已是解密后明文):createStore/storeCharge。
fn parseSingleStrField(gpa: std.mem.Allocator, resp: []const u8, field: []const u8, what: []const u8) WxResult([]u8) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "{s} not json", .{what}) };
    defer parsed.deinit();
    const s = looseStr(gpa, parsed.value, field) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
    if (s == null or s.?.len == 0)
        return .{ .err = WxError.internal(gpa, "{s} 响应缺少 {s}", .{ what, field }) };
    // looseStr 已是 gpa 副本,直接转移所有权
    return .{ .ok = @constCast(s.?) };
}

/// updateStore 的 `{keys:{...},content:{...}}` 组包。
fn updateStoreBody(gpa: std.mem.Allocator, store: *const Store) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"keys\":{");
    if (store.wx_store_id) |v| {
        try w.writeAll("\"wx_store_id\":");
        try js(w, v);
    } else if (store.out_store_id) |v| {
        try w.writeAll("\"out_store_id\":");
        try js(w, v);
    }
    try w.writeAll("},\"content\":{");
    var sep = false;
    if (store.store_name) |v| {
        try w.writeAll("\"store_name\":");
        try js(w, v);
        sep = true;
    }
    if (store.order_pattern == 1 or store.order_pattern == 2) {
        if (sep) try w.writeAll(",");
        try w.print("\"order_pattern\":{d}", .{store.order_pattern});
        sep = true;
    }
    if (store.service_trans_prefer) |v| {
        if (sep) try w.writeAll(",");
        try w.writeAll("\"service_trans_prefer\":");
        try js(w, v);
        sep = true;
    }
    if (store.address_info) |*a| {
        if (sep) try w.writeAll(",");
        try w.writeAll("\"address_info\":");
        try a.writeJson(w);
    }
    try w.writeAll("}}");
    return out.toOwnedSlice();
}

// ---- 测试 ------------------------------------------------------------------------

const sig_mock = @import("_sig_mock.zig");
const mock_mod = @import("_mock.zig");

/// 断言结果为 .err 且 source/errcode 匹配。
fn expectErr(r: anytype, source: error_mod.WxError.Source, code: i64) !void {
    switch (r) {
        .ok => return error.TestUnexpectedResult,
        .err => |e0| {
            var e = e0;
            defer e.deinit();
            try std.testing.expectEqual(source, e.source);
            try std.testing.expectEqual(code, e.error_code);
        },
    }
}

test "intracity 请求组包:Store/charge/refund/flow/preadd/addorder/updatestore" {
    const gpa = std.testing.allocator;

    // createStore 请求:out_store_id + 恒序列化的 order_pattern + address_info
    var store = Store{
        .out_store_id = "OUT1",
        .store_name = "同城门店",
        .city_id = "C1",
        .service_trans_prefer = "P1",
        .address_info = .{ .province = "广东", .city = "深圳", .lat = 22.5, .lng = 114.05 },
    };
    const s1 = try store.to_json(gpa);
    defer gpa.free(s1);
    try std.testing.expectEqualStrings(
        "{\"out_store_id\":\"OUT1\",\"store_name\":\"同城门店\",\"city_id\":\"C1\",\"order_pattern\":1,\"service_trans_prefer\":\"P1\",\"address_info\":{\"province\":\"广东\",\"city\":\"深圳\",\"lat\":22.5,\"lng\":114.05}}",
        s1,
    );

    // updateStore:keys 取 wx_store_id 优先;content 跳过 null 字段
    var up = Store{ .wx_store_id = "WS1", .out_store_id = "OUT1", .store_name = "新名", .order_pattern = 2, .service_trans_prefer = "P2" };
    const upd1 = try updateStoreBody(gpa, &up);
    defer gpa.free(upd1);
    try std.testing.expectEqualStrings(
        "{\"keys\":{\"wx_store_id\":\"WS1\"},\"content\":{\"store_name\":\"新名\",\"order_pattern\":2,\"service_trans_prefer\":\"P2\"}}",
        upd1,
    );

    // 最小 content:默认 order_pattern=1 恒发(Java 原始 int quirk)
    var up2 = Store{ .out_store_id = "OUT2" };
    const upd2 = try updateStoreBody(gpa, &up2);
    defer gpa.free(upd2);
    try std.testing.expectEqualStrings(
        "{\"keys\":{\"out_store_id\":\"OUT2\"},\"content\":{\"order_pattern\":1}}",
        upd2,
    );

    // StoreChargeRequest:amount 恒序列化(Java int 原始值)
    const charge = StoreChargeRequest{ .wx_store_id = "WS1", .pay_mode = .store, .amount = 5000 };
    const c1 = try charge.to_json(gpa);
    defer gpa.free(c1);
    try std.testing.expectEqualStrings(
        "{\"wx_store_id\":\"WS1\",\"pay_mode\":\"PAY_MODE_STORE\",\"amount\":5000}",
        c1,
    );

    // StoreRefundRequest(子类无额外字段)
    const refund = StoreRefundRequest{ .service_trans_id = "ST1" };
    const r1 = try refund.to_json(gpa);
    defer gpa.free(r1);
    try std.testing.expectEqualStrings("{\"service_trans_id\":\"ST1\"}", r1);

    // QueryFlowRequest:begin_time/end_time 恒序列化(Java 日期字段 transient 不发)
    const flow = QueryFlowRequest{ .wx_store_id = "WS1", .flow_type = 3, .begin_time = 100, .end_time = 200 };
    const f1 = try flow.to_json(gpa);
    defer gpa.free(f1);
    try std.testing.expectEqualStrings(
        "{\"wx_store_id\":\"WS1\",\"flow_type\":3,\"begin_time\":100,\"end_time\":200}",
        f1,
    );

    // PreAddOrderRequest:double 原始值恒序列化 + cargo
    const cargo = Cargo{ .cargo_name = "文件", .cargo_weight = 2, .cargo_type = 1, .cargo_num = 1, .cargo_price = 100 };
    const pre = PreAddOrderRequest{
        .wx_store_id = "WS1",
        .user_name = "张三",
        .user_phone = "13800138000",
        .user_lng = 114.05,
        .user_lat = 22.5,
        .user_address = "南山区科技园",
        .cargo = &cargo,
    };
    const p1 = try pre.to_json(gpa);
    defer gpa.free(p1);
    try std.testing.expectEqualStrings(
        "{\"wx_store_id\":\"WS1\",\"user_name\":\"张三\",\"user_phone\":\"13800138000\",\"user_lng\":114.05,\"user_lat\":22.5,\"user_address\":\"南山区科技园\",\"cargo\":{\"cargo_name\":\"文件\",\"cargo_weight\":2,\"cargo_type\":1,\"cargo_num\":1,\"cargo_price\":100}}",
        p1,
    );

    // AddOrderRequest:verify_code_type 恒序列化 + cargo.item_list
    const items = [_]ItemDetail{.{ .item_name = "合同", .item_pic_url = "https://example.com/a.png", .count = 2 }};
    const cargo2 = Cargo{ .cargo_name = "文件", .cargo_weight = 2, .cargo_type = 1, .cargo_num = 1, .cargo_price = 100, .item_list = &items };
    const add = AddOrderRequest{ .wx_store_id = "WS1", .user_lng = 113.95, .user_lat = 22.53, .order_seq = "SEQ1", .verify_code_type = 1, .cargo = &cargo2 };
    const a1 = try add.to_json(gpa);
    defer gpa.free(a1);
    try std.testing.expectEqualStrings(
        "{\"wx_store_id\":\"WS1\",\"user_lng\":113.95,\"user_lat\":22.53,\"order_seq\":\"SEQ1\",\"verify_code_type\":1,\"cargo\":{\"cargo_name\":\"文件\",\"cargo_weight\":2,\"cargo_type\":1,\"cargo_num\":1,\"cargo_price\":100,\"item_list\":[{\"item_name\":\"合同\",\"item_pic_url\":\"https://example.com/a.png\",\"count\":2}]}}",
        a1,
    );
}

test "intracity 参数校验:queryFlow/balanceQuery/createStore/updateStore(不发 HTTP)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var ma: MiniappService = undefined;
    ma.init(gpa, cfg.config(), m.executor());
    const svc = ma.intracity();

    // queryFlow:wx_store_id 必填;flow_type 只能 1/2/3
    var bad_flow = QueryFlowRequest{ .wx_store_id = null, .flow_type = 1 };
    try expectErr(svc.queryFlow(io, &bad_flow), .internal, -99);
    bad_flow.wx_store_id = "WS1";
    bad_flow.flow_type = 5;
    try expectErr(svc.queryFlow(io, &bad_flow), .internal, -99);

    // balanceQuery:payMode 为 null/STORE 时必须传 wx_store_id
    try expectErr(svc.balanceQuery(io, null, null, null), .internal, -99);
    try expectErr(svc.balanceQuery(io, null, null, .store), .internal, -99);
    // .app 豁免:通过校验,走 signedPost → 未启用签名 → configError(.config)
    try expectErr(svc.balanceQuery(io, null, "ST1", .app), .config, -99);

    // createStore:out_store_id 必填、wx_store_id 必须为 null
    var no_out = Store{ .store_name = "x" };
    try expectErr(svc.createStore(io, &no_out), .internal, -99);
    var with_wx = Store{ .out_store_id = "OUT1", .wx_store_id = "WS1" };
    try expectErr(svc.createStore(io, &with_wx), .internal, -99);

    // updateStore:wxStoreId/outStoreId 至少一个
    var empty_store = Store{};
    try expectErr(svc.updateStore(io, &empty_store), .internal, -99);

    try std.testing.expectEqual(@as(usize, 0), m.calls);
}

test "intracity queryStore 解析 + queryStoreByWxStoreId 所有权转移" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/querystore", .response =
        \\{"errcode":0,"store_list":[
        \\  {"wx_store_id":"WS1","out_store_id":"OUT1","store_name":"门店一","city_id":"C1","order_pattern":2,"service_trans_prefer":"P1","address_info":{"province":"广东","city":"深圳","area":"南山","street":"科技园","house":"1栋","phone":"0755","lat":22.5,"lng":114.05}},
        \\  {"wx_store_id":"WS2","store_name":"门店二"}
        \\]}
        },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    // listAllStores:空请求体 + 解析两条
    var sl = switch (svc.listAllStores(io)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer sl.deinit();
    try std.testing.expectEqual(@as(usize, 2), sl.list.len);
    try std.testing.expectEqualStrings("WS1", sl.list[0].wx_store_id.?);
    try std.testing.expectEqual(@as(i64, 2), sl.list[0].order_pattern);
    try std.testing.expectEqualStrings("广东", sl.list[0].address_info.?.province.?);
    try std.testing.expectEqual(@as(f64, 22.5), sl.list[0].address_info.?.lat);
    try std.testing.expectEqualStrings("门店二", sl.list[1].store_name.?);
    try std.testing.expect(sl.list[1].address_info == null);
    // 空请求体:明文只有注入字段(无 wx_store_id/out_store_id)
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expect(json_util.getStr(p.value, "wx_store_id") == null);
    }

    // ByWxStoreId:请求带 wx_store_id;返回 list[0] 所有权(其余记录已释放)
    var one = switch (svc.queryStoreByWxStoreId(io, "WS1")) {
        .ok => |x| x orelse return error.TestUnexpectedResult,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer one.deinit();
    try std.testing.expectEqualStrings("WS1", one.wx_store_id.?);
    try std.testing.expectEqualStrings("门店一", one.store_name.?);
    try std.testing.expectEqualStrings("深圳", one.address_info.?.city.?);
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("WS1", json_util.getStr(p.value, "wx_store_id").?);
        try std.testing.expect(json_util.getStr(p.value, "out_store_id") == null);
    }

    // ByOutStoreId:请求带 out_store_id
    var by_out = switch (svc.queryStoreByOutStoreId(io, "OUT1")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer by_out.deinit();
    try std.testing.expectEqual(@as(usize, 2), by_out.list.len);
}

test "intracity queryStore 缺 store_list 归一化为空;ByWxStoreId 空 → null" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/querystore", .response = "{\"errcode\":0}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    var sl = switch (svc.listAllStores(io)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer sl.deinit();
    try std.testing.expectEqual(@as(usize, 0), sl.list.len); // Java 侧此处 NPE

    const none = switch (svc.queryStoreByWxStoreId(io, "WS1")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    try std.testing.expect(none == null);
}

test "intracity queryFlow 解析(三记录超集 + pay_order_id 拼写)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/queryflow", .response =
        \\{"errcode":0,"total_pay_amt":10000,"total_refund_amt":200,"flow_list":[
        \\  {"flow_type":1,"appid":"MA","wx_store_id":"WS1","pay_order_id":"PO1","service_trans_id":"ST1","pay_amount":10000,"pay_time":1700000000,"pay_status":"PAY_STATUS_SUCCESS","consume_deadline":1800000000},
        \\  {"flow_type":2,"wx_store_id":"WS1","pay_order_id":"PO1","refund_amount":200,"refund_time":1700001000},
        \\  {"flow_type":3,"wx_store_id":"WS1","wx_order_id":"WO1","openid":"oABC","delivery_status":"DELIVERY_STATUS_FINISHED","refund_status":"REFUND_STATUS_NOT_REFUND","deduct_amount":500,"bill_id":"B1","create_time":1700002000,"delivery_finished_time":1700003000}
        \\]}
        },
    });
    defer h.deinit();

    const req = QueryFlowRequest{ .wx_store_id = "WS1", .flow_type = 3, .begin_time = 1, .end_time = 2 };
    var out = switch (h.ma.intracity().queryFlow(io, &req)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer out.deinit();
    try std.testing.expectEqual(@as(?i64, 10000), out.total_pay_amt);
    try std.testing.expectEqual(@as(?i64, 200), out.total_refund_amt);
    try std.testing.expectEqual(@as(usize, 3), out.flow_list.len);
    // 充值记录
    try std.testing.expectEqualStrings("PO1", out.flow_list[0].pay_order_id.?); // flow 拼写:pay_order_id
    try std.testing.expectEqualStrings("PAY_STATUS_SUCCESS", out.flow_list[0].pay_status.?);
    try std.testing.expectEqual(@as(?i64, 1800000000), out.flow_list[0].consume_deadline);
    // 退款记录
    try std.testing.expectEqual(@as(?i64, 200), out.flow_list[1].refund_amount);
    // 消费记录(无 total_* 的场景由字段可空覆盖)
    try std.testing.expectEqualStrings("WO1", out.flow_list[2].wx_order_id.?);
    try std.testing.expectEqual(@as(?i64, 500), out.flow_list[2].deduct_amount);
    try std.testing.expectEqualStrings("B1", out.flow_list[2].bill_id.?);
    // 请求组包:begin_time/end_time 恒发
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqual(@as(i64, 3), json_util.getInt(p.value, "flow_type").?);
        try std.testing.expectEqual(@as(i64, 1), json_util.getInt(p.value, "begin_time").?);
        try std.testing.expectEqual(@as(i64, 2), json_util.getInt(p.value, "end_time").?);
    }
}

test "intracity balanceQuery 解析(payorder_id 小写 o 拼写)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/balancequery", .response =
        \\{"errcode":0,"wx_store_id":"WS1","appid":"MA","all_balance":9800,"balance_detail":[
        \\  {"balance":9800,"service_trans_id":"ST1","service_trans_name":"上门服务","order_list":[
        \\    {"payorder_id":"PO9","charge_amt":10000,"unused_amt":9800,"begin_time":1,"end_time":2}
        \\  ]}
        \\]}
        },
    });
    defer h.deinit();

    var out = switch (h.ma.intracity().balanceQuery(io, "WS1", null, .app)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer out.deinit();
    try std.testing.expectEqual(@as(?i64, 9800), out.all_balance);
    try std.testing.expectEqual(@as(usize, 1), out.balance_detail.len);
    const d = out.balance_detail[0];
    try std.testing.expectEqualStrings("ST1", d.service_trans_id.?);
    try std.testing.expectEqualStrings("PO9", d.order_list[0].payorder_id.?); // 余额拼写:payorder_id
    try std.testing.expectEqual(@as(?i64, 10000), d.order_list[0].charge_amt);
    // 请求组包:pay_mode + wx_store_id
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("WS1", json_util.getStr(p.value, "wx_store_id").?);
        try std.testing.expectEqualStrings("PAY_MODE_APP", json_util.getStr(p.value, "pay_mode").?);
    }
}

test "intracity getPayMode/setPayMode(请求带配置 appid)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/getpaymode", .response = "{\"errcode\":0,\"pay_mode\":\"PAY_MODE_APP\",\"pay_appid\":\"wxPAY\",\"component_appid\":\"wxCOMP\"}" },
        .{ .match = "express/intracity/setpaymode", .response = "{\"errcode\":0}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    var got = switch (svc.getPayMode(io)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer got.deinit();
    try std.testing.expectEqual(PayMode.app, got.pay_mode.?);
    try std.testing.expectEqualStrings("wxPAY", got.pay_appid.?);
    try std.testing.expectEqualStrings("wxCOMP", got.component_appid.?);

    switch (svc.setPayMode(io, .component)) {
        .ok => {},
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("PAY_MODE_COMPONENT", json_util.getStr(p.value, "pay_mode").?);
        try std.testing.expectEqualStrings("MA", json_util.getStr(p.value, "appid").?); // 来自配置
    }
}

test "intracity queryOrder 解析(嵌套四信息 + 数字串 looseStr)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/queryorder", .response =
        \\{"errcode":0,"wx_order_id":1234567890,"order_status":3,"appid":"MA","wx_store_id":"WS1",
        \\ "user_name":"张三","user_phone":"13800138000","user_lng":114.05,"user_lat":22.5,"user_address":"南山区科技园",
        \\ "store_order_id":"SO1","service_trans_id":"ST1","delivery_no":"DN1","actualfee":500,"deductfee":100,
        \\ "distance":3500,"create_time":1700000000,"fetch_code":"FC1","recv_code":"RC1",
        \\ "transporter_info":{"transporter_name":"骑手小王","transporter_phone":"13900139000"},
        \\ "store_info":{"store_name":"门店一","wx_store_id":"WS1","address":"路一","lng":114.05,"lat":22.5,"phone_num":"0755-1234"},
        \\ "receiver_info":{"receiver_name":"李四","address":"路二","phone_num":"13700137000","lng":114.06,"lat":22.51},
        \\ "cargo_info":{"cargo_name":"文件","cargo_weight":2,"cargo_type":1,"cargo_num":1,"cargo_price":100,
        \\   "item_list":[{"item_name":"合同","item_pic_url":"https://example.com/a.png","count":2}]}}
        },
    });
    defer h.deinit();

    var o = switch (h.ma.intracity().queryOrderByWxOrderId(io, "WO1")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer o.deinit();
    // 数字 → 字符串(looseStr,Java String 字段兼容微信回数字)
    try std.testing.expectEqualStrings("1234567890", o.wx_order_id.?);
    try std.testing.expectEqual(@as(?i64, 3), o.order_status);
    try std.testing.expectEqual(@as(f64, 114.05), o.user_lng);
    try std.testing.expectEqualStrings("DN1", o.delivery_no.?);
    try std.testing.expectEqual(@as(?i64, 500), o.actualfee);
    try std.testing.expectEqual(@as(?i64, 100), o.deductfee);
    // 嵌套:配送员/门店/收件人/货品
    try std.testing.expectEqualStrings("骑手小王", o.transporter_info.?.transporter_name.?);
    try std.testing.expectEqualStrings("门店一", o.store_info.?.store_name.?);
    try std.testing.expectEqual(@as(f64, 22.5), o.store_info.?.lat);
    try std.testing.expectEqualStrings("李四", o.receiver_info.?.receiver_name.?);
    try std.testing.expectEqual(@as(f64, 22.51), o.receiver_info.?.lat);
    try std.testing.expectEqualStrings("文件", o.cargo_info.?.cargo_name.?);
    try std.testing.expectEqual(@as(i64, 2), o.cargo_info.?.item_list[0].count);
    // 请求组包
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("WO1", json_util.getStr(p.value, "wx_order_id").?);
    }
}

test "intracity cancelOrder 解析 + cancel_reason 条件组包" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/cancelorder", .response = "{\"errcode\":0,\"wx_order_id\":\"WO1\",\"store_order_id\":\"SO1\",\"wx_store_id\":\"WS1\",\"order_status\":2505,\"appid\":\"MA\",\"deductfee\":0}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    // 无 cancel_reason:不发该键
    var c1 = switch (svc.cancelOrderByWxOrderId(io, "WO1", 5, null)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer c1.deinit();
    try std.testing.expectEqualStrings("WO1", c1.wx_order_id.?);
    try std.testing.expectEqualStrings("2505", c1.order_status.?); // Java String 字段,微信回数字 → looseStr
    try std.testing.expectEqual(@as(?i64, 0), c1.deductfee);
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("WO1", json_util.getStr(p.value, "wx_order_id").?);
        try std.testing.expectEqual(@as(i64, 5), json_util.getInt(p.value, "cancel_reason_id").?);
        try std.testing.expect(json_util.getStr(p.value, "cancel_reason") == null);
    }

    // 带 cancel_reason;按 store 侧查询
    var c2 = switch (svc.cancelOrderByStoreOrderId(io, "WS1", "SO1", 6, "临时取消")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer c2.deinit();
    try std.testing.expectEqualStrings("SO1", c2.store_order_id.?);
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("WS1", json_util.getStr(p.value, "wx_store_id").?);
        try std.testing.expectEqualStrings("SO1", json_util.getStr(p.value, "store_order_id").?);
        try std.testing.expectEqualStrings("临时取消", json_util.getStr(p.value, "cancel_reason").?);
        try std.testing.expectEqual(@as(i64, 6), json_util.getInt(p.value, "cancel_reason_id").?);
    }
}

test "intracity getCity 解析 + 缺 support_list 归一化为空" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 正常回包
    var h1: sig_mock.Harness = undefined;
    try h1.init(gpa, &.{
        .{ .match = "express/intracity/getcity", .response =
        \\{"errcode":0,"support_list":[
        \\  {"service_trans_id":"ST1","city_list":[{"city_name":"深圳","city_code":"0755"},{"city_name":"广州","city_code":"020"}]},
        \\  {"service_trans_id":"ST2"}
        \\]}
        },
    });
    defer h1.deinit();
    var cities = switch (h1.ma.intracity().getCity(io, "ST1")) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer cities.deinit();
    try std.testing.expectEqual(@as(usize, 2), cities.list.len);
    try std.testing.expectEqualStrings("ST1", cities.list[0].service_trans_id.?);
    try std.testing.expectEqual(@as(usize, 2), cities.list[0].city_list.len);
    try std.testing.expectEqualStrings("0755", cities.list[0].city_list[0].city_code.?);
    try std.testing.expectEqual(@as(usize, 0), cities.list[1].city_list.len);
    {
        const p = try json_util.parse(gpa, h1.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqualStrings("ST1", json_util.getStr(p.value, "service_trans_id").?);
    }

    // 缺 support_list(Java 侧 NPE,Zig 归一化空列表)
    var h2: sig_mock.Harness = undefined;
    try h2.init(gpa, &.{
        .{ .match = "express/intracity/getcity", .response = "{\"errcode\":0}" },
    });
    defer h2.deinit();
    var empty = switch (h2.ma.intracity().getCity(io, null)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.list.len);
}

test "intracity storeCharge/storeRefund 解析" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/storecharge", .response = "{\"errcode\":0,\"payurl\":\"https://pay.weixin.qq.com/plat/charge?x=1\"}" },
        .{ .match = "express/intracity/storerefund", .response = "{\"errcode\":0,\"refund_amount\":500}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    const charge = StoreChargeRequest{ .wx_store_id = "WS1", .pay_mode = .store, .amount = 5000 };
    const payurl = switch (svc.storeCharge(io, &charge)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer gpa.free(payurl);
    try std.testing.expectEqualStrings("https://pay.weixin.qq.com/plat/charge?x=1", payurl);

    const refund = StoreRefundRequest{ .wx_store_id = "WS1" };
    const amount = switch (svc.storeRefund(io, &refund)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    try std.testing.expectEqual(@as(i64, 500), amount);
}

test "intracity storeCharge 缺 payurl / storeRefund 缺 refund_amount → .err" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/storecharge", .response = "{\"errcode\":0}" },
        .{ .match = "express/intracity/storerefund", .response = "{\"errcode\":0}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    const charge = StoreChargeRequest{ .wx_store_id = "WS1", .amount = 5000 };
    try expectErr(svc.storeCharge(io, &charge), .internal, -99);
    const refund = StoreRefundRequest{ .wx_store_id = "WS1" };
    try expectErr(svc.storeRefund(io, &refund), .internal, -99); // Java 侧 NPE
}

test "intracity preAddOrder/addOrder 解析 + use_sandbox 条件组包" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/preaddorder", .response = "{\"errcode\":0,\"service_trans_id\":\"ST1\",\"distance\":3500,\"est_fee\":500,\"expected_finished_time\":1700001000,\"promise_delivery_time\":1700002000}" },
        .{ .match = "express/intracity/addorder", .response = "{\"errcode\":0,\"wx_order_id\":\"WO1\",\"store_order_id\":\"SO1\",\"wx_store_id\":\"WS1\",\"service_trans_id\":\"ST1\",\"distance\":3500,\"trans_order_id\":\"TO1\",\"waybill_id\":\"WB1\",\"fee\":500,\"fetch_code\":\"FC1\",\"order_seq\":\"SEQ1\"}" },
    });
    defer h.deinit();
    const svc = h.ma.intracity();

    const cargo = Cargo{ .cargo_name = "文件", .cargo_weight = 2, .cargo_type = 1, .cargo_num = 1, .cargo_price = 100 };
    const pre = PreAddOrderRequest{ .wx_store_id = "WS1", .user_name = "张三", .user_phone = "13800138000", .user_lng = 114.05, .user_lat = 22.5, .user_address = "南山区科技园", .use_sandbox = 1, .cargo = &cargo };
    var pre_out = switch (svc.preAddOrder(io, &pre)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer pre_out.deinit();
    try std.testing.expectEqualStrings("ST1", pre_out.service_trans_id.?);
    try std.testing.expectEqual(@as(?i64, 3500), pre_out.distance);
    try std.testing.expectEqual(@as(?i64, 500), pre_out.est_fee);
    try std.testing.expectEqual(@as(?i64, 1700002000), pre_out.promise_delivery_time);
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expectEqual(@as(i64, 1), json_util.getInt(p.value, "use_sandbox").?); // 设置才发
        try std.testing.expect(std.mem.indexOf(u8, h.mock.last_plain.?, "\"user_lng\":114.05") != null);
    }

    const add = AddOrderRequest{ .wx_store_id = "WS1", .user_name = "张三", .user_phone = "13800138000", .user_lng = 114.05, .user_lat = 22.5, .user_address = "南山区科技园", .cargo = &cargo };
    var add_out = switch (svc.addOrder(io, &add)) {
        .ok => |x| x,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer add_out.deinit();
    try std.testing.expectEqualStrings("WO1", add_out.wx_order_id.?);
    try std.testing.expectEqualStrings("WB1", add_out.waybill_id.?);
    try std.testing.expectEqual(@as(?i64, 500), add_out.fee);
    try std.testing.expectEqualStrings("SEQ1", add_out.order_seq.?);
    {
        const p = try json_util.parse(gpa, h.mock.last_plain.?);
        defer p.deinit();
        try std.testing.expect(json_util.getInt(p.value, "use_sandbox") == null); // 未设置不发
        try std.testing.expectEqual(@as(i64, 0), json_util.getInt(p.value, "verify_code_type").?); // Java 原始 int 恒发
    }
}

test "intracity apply 明文透传(不在签名强制列表)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var h: sig_mock.Harness = undefined;
    try h.init(gpa, &.{
        .{ .match = "express/intracity/apply", .response = "{\"errcode\":0}" },
    });
    defer h.deinit();

    switch (h.ma.intracity().apply(io)) {
        .ok => {},
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expect(!h.mock.signature_verified); // 明文通道
    try std.testing.expectEqualStrings("{}", h.mock.saw_plain_body.?);
    try std.testing.expect(std.mem.endsWith(u8, h.mock.urlPath(), "/apply"));
}
