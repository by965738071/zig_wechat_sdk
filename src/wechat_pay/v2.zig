//! V2(XML)接口的常量与响应对象 —— 对应 Java:
//! - `constant/WxPayConstants` + `service/impl/BaseWxPayServiceImpl` 各方法内的 URL 常量;
//! - `bean/order/query/WxPayOrderQueryResult`、`bean/refund/...` 等响应 POJO 的常用字段子集。
//!
//! 响应对象约定(与 `User` 样板一致):所有字符串字段由结构体**拥有**(dupe),
//! 用毕调用 `deinit`;缺失字段以空串 `""` 表示(对应 Java 的 null,但免掉判空成本)。
const std = @import("std");
const xml = @import("common").xml;
const sign_mod = @import("sign.zig");

/// V2 接口基址(对应 `WxPayConfig.getPayBaseUrl()`,骨架只支持大陆默认域名)。
pub const api_host = "https://api.mch.weixin.qq.com";

/// 对应 BaseWxPayServiceImpl 各方法拼接的 URL 后缀。
pub const url = struct {
    pub const order_query = "/pay/orderquery";
    pub const close_order = "/pay/closeorder";
    /// Java `reverse` 走 /secapi/pay/reverse(需商户证书,mTLS)。
    pub const reverse = "/secapi/pay/reverse";
    /// Java `refund` 走 /secapi/pay/refund(需商户证书,mTLS)。
    pub const refund = "/secapi/pay/refund";
    pub const refund_query = "/pay/refundquery";
};

/// StringHashMap(键按 ASCII 升序,天然满足字典序)→ 签名字段列表。
///
/// **所有权/借用契约**(对应 `xml.parse`:key 借用输入报文、value 是 map 拥有的 dupe):
/// 返回的 `[]Field` 本身由 gpa 分配(调用方 free 切片),但每个 Field 的
/// key/value 均为**借用**——key 借用原始 xml,value 借用 map——因此 Field 列表
/// 必须在 map 释放前、且原始报文存活期间使用;不在此函数内 dupe。
pub fn mapToFields(gpa: std.mem.Allocator, map: *xml.Map) ![]sign_mod.Field {
    var list = std.ArrayList(sign_mod.Field).empty;
    errdefer list.deinit(gpa);
    var it = map.iterator();
    while (it.next()) |kv| {
        try list.append(gpa, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
    }
    return list.toOwnedSlice(gpa);
}

fn get(map: xml.Map, key: []const u8) []const u8 {
    return map.get(key) orelse "";
}

/// dupe map 里的若干字段到一个 struct 字段数组(样板:POJO 字段填充)。
fn dupeFields(gpa: std.mem.Allocator, map: xml.Map, keys: []const []const u8, out: []([]u8)) !void {
    for (keys, 0..) |k, i| out[i] = try gpa.dupe(u8, get(map, k));
}

/// 对应 `BaseWxPayResult` 的公共字段(return/result 两级状态)。
pub const BaseResult = struct {
    gpa: std.mem.Allocator,
    return_code: []u8 = "",
    return_msg: []u8 = "",
    result_code: []u8 = "",
    err_code: []u8 = "",
    err_code_des: []u8 = "",

    const field_keys = [_][]const u8{ "return_code", "return_msg", "result_code", "err_code", "err_code_des" };

    pub fn fromMap(gpa: std.mem.Allocator, map: xml.Map) !BaseResult {
        var self = BaseResult{ .gpa = gpa };
        var out = [_][]u8{ "", "", "", "", "" };
        errdefer for (out) |s| gpa.free(s);
        try dupeFields(gpa, map, &field_keys, &out);
        self.return_code = out[0];
        self.return_msg = out[1];
        self.result_code = out[2];
        self.err_code = out[3];
        self.err_code_des = out[4];
        return self;
    }

    pub fn deinit(self: *BaseResult) void {
        const g = self.gpa;
        g.free(self.return_code);
        g.free(self.return_msg);
        g.free(self.result_code);
        g.free(self.err_code);
        g.free(self.err_code_des);
        self.* = undefined;
    }

    /// 通信 + 业务双层 SUCCESS(对应 Java 里层层 `checkResult` 的语义)。
    pub fn businessOk(self: *const BaseResult) bool {
        return std.mem.eql(u8, self.return_code, "SUCCESS") and
            std.mem.eql(u8, self.result_code, "SUCCESS");
    }
};

/// 对应 `WxPayOrderQueryResult`(常用字段子集)。
pub const OrderQueryResult = struct {
    gpa: std.mem.Allocator,
    base: BaseResult,
    trade_state: []u8 = "",
    trade_state_desc: []u8 = "",
    out_trade_no: []u8 = "",
    transaction_id: []u8 = "",
    openid: []u8 = "",
    is_subscribe: []u8 = "",
    total_fee: []u8 = "",

    const extra_keys = [_][]const u8{
        "trade_state",    "trade_state_desc", "out_trade_no",
        "transaction_id", "openid",           "is_subscribe",
        "total_fee",
    };

    pub fn fromMap(gpa: std.mem.Allocator, map: xml.Map) !OrderQueryResult {
        var self = OrderQueryResult{ .gpa = gpa, .base = try BaseResult.fromMap(gpa, map) };
        errdefer self.base.deinit();
        var out: [extra_keys.len][]u8 = undefined;
        for (&out) |*s| s.* = "";
        errdefer for (out) |s| gpa.free(s);
        try dupeFields(gpa, map, &extra_keys, &out);
        self.trade_state = out[0];
        self.trade_state_desc = out[1];
        self.out_trade_no = out[2];
        self.transaction_id = out[3];
        self.openid = out[4];
        self.is_subscribe = out[5];
        self.total_fee = out[6];
        return self;
    }

    pub fn deinit(self: *OrderQueryResult) void {
        const g = self.gpa;
        self.base.deinit();
        for ([_][]u8{
            self.trade_state,    self.trade_state_desc, self.out_trade_no,
            self.transaction_id, self.openid,           self.is_subscribe,
            self.total_fee,
        }) |s| g.free(s);
        self.* = undefined;
    }
};

/// 对应 `WxPayRefundResult`(申请退款响应常用字段)。
pub const RefundResult = struct {
    gpa: std.mem.Allocator,
    base: BaseResult,
    refund_id: []u8 = "",
    out_refund_no: []u8 = "",
    out_trade_no: []u8 = "",
    refund_fee: []u8 = "",
    total_fee: []u8 = "",

    const extra_keys = [_][]const u8{ "refund_id", "out_refund_no", "out_trade_no", "refund_fee", "total_fee" };

    pub fn fromMap(gpa: std.mem.Allocator, map: xml.Map) !RefundResult {
        var self = RefundResult{ .gpa = gpa, .base = try BaseResult.fromMap(gpa, map) };
        errdefer self.base.deinit();
        var out: [extra_keys.len][]u8 = undefined;
        for (&out) |*s| s.* = "";
        errdefer for (out) |s| gpa.free(s);
        try dupeFields(gpa, map, &extra_keys, &out);
        self.refund_id = out[0];
        self.out_refund_no = out[1];
        self.out_trade_no = out[2];
        self.refund_fee = out[3];
        self.total_fee = out[4];
        return self;
    }

    pub fn deinit(self: *RefundResult) void {
        const g = self.gpa;
        self.base.deinit();
        for ([_][]u8{ self.refund_id, self.out_refund_no, self.out_trade_no, self.refund_fee, self.total_fee }) |s| g.free(s);
        self.* = undefined;
    }
};

/// 逐笔退款代金券 —— 对应 `WxPayRefundCouponInfo`(键 `coupon_refund_id_N_M` 一族)。
pub const RefundCoupon = struct {
    coupon_refund_id: []u8 = "",
    coupon_refund_fee: []u8 = "",
    coupon_type: []u8 = "",

    fn fromIndex(gpa: std.mem.Allocator, map: xml.Map, i: usize, j: usize) !RefundCoupon {
        var kb: [40]u8 = undefined;
        var c = RefundCoupon{};
        errdefer c.deinit(gpa);
        c.coupon_refund_id = try idxDupe(gpa, map, &kb, "coupon_refund_id", i, j);
        c.coupon_refund_fee = try idxDupe(gpa, map, &kb, "coupon_refund_fee", i, j);
        c.coupon_type = try idxDupe(gpa, map, &kb, "coupon_type", i, j);
        return c;
    }

    pub fn deinit(self: *RefundCoupon, g: std.mem.Allocator) void {
        for ([_][]u8{ self.coupon_refund_id, self.coupon_refund_fee, self.coupon_type }) |s| g.free(s);
        self.* = undefined;
    }
};

/// 单笔退款记录 —— 对应 `WxPayRefundQueryResult.RefundRecord`
/// (字段来自 xml 里带下标的 `*_N` 键,全部 gpa 拥有)。
pub const RefundRecord = struct {
    gpa: std.mem.Allocator,
    out_refund_no: []u8 = "",
    refund_id: []u8 = "",
    refund_channel: []u8 = "",
    refund_fee: []u8 = "",
    settlement_refund_fee: []u8 = "",
    refund_account: []u8 = "",
    coupon_refund_fee: []u8 = "",
    coupon_refund_count: []u8 = "",
    refund_status: []u8 = "",
    refund_recv_accout: []u8 = "",
    refund_success_time: []u8 = "",
    /// 该笔退款使用的代金券明细(键 `coupon_*_N_M`,`_M` 下标,见 coupon_refund_count)。
    refund_coupons: []RefundCoupon = &.{},

    /// 对应 Java `composeRefundRecords` 第 i 条记录的字段填充。
    pub fn fromIndex(gpa: std.mem.Allocator, map: xml.Map, i: usize) !RefundRecord {
        var kb: [40]u8 = undefined;
        var r = RefundRecord{ .gpa = gpa };
        errdefer r.deinit();
        r.out_refund_no = try idxDupe(gpa, map, &kb, "out_refund_no", i, null);
        r.refund_id = try idxDupe(gpa, map, &kb, "refund_id", i, null);
        r.refund_channel = try idxDupe(gpa, map, &kb, "refund_channel", i, null);
        r.refund_fee = try idxDupe(gpa, map, &kb, "refund_fee", i, null);
        r.settlement_refund_fee = try idxDupe(gpa, map, &kb, "settlement_refund_fee", i, null);
        r.refund_account = try idxDupe(gpa, map, &kb, "refund_account", i, null);
        r.coupon_refund_fee = try idxDupe(gpa, map, &kb, "coupon_refund_fee", i, null);
        r.coupon_refund_count = try idxDupe(gpa, map, &kb, "coupon_refund_count", i, null);
        r.refund_status = try idxDupe(gpa, map, &kb, "refund_status", i, null);
        r.refund_recv_accout = try idxDupe(gpa, map, &kb, "refund_recv_accout", i, null);
        r.refund_success_time = try idxDupe(gpa, map, &kb, "refund_success_time", i, null);

        // 代金券明细:coupon_refund_count 给 M 层数
        const coupon_n = std.fmt.parseInt(usize, r.coupon_refund_count, 10) catch 0;
        if (coupon_n > 0) {
            var coupons: std.ArrayList(RefundCoupon) = .empty;
            errdefer for (coupons.items) |*c| c.deinit(gpa);
            for (0..coupon_n) |j| try coupons.append(gpa, try RefundCoupon.fromIndex(gpa, map, i, j));
            r.refund_coupons = try coupons.toOwnedSlice(gpa);
        }
        return r;
    }

    pub fn deinit(self: *RefundRecord) void {
        const g = self.gpa;
        for ([_][]u8{
            self.out_refund_no,      self.refund_id,           self.refund_channel,
            self.refund_fee,         self.refund_account,      self.settlement_refund_fee,
            self.coupon_refund_fee,  self.coupon_refund_count, self.refund_status,
            self.refund_recv_accout, self.refund_success_time,
        }) |s| g.free(s);
        for (self.refund_coupons) |*c| c.deinit(g);
        if (self.refund_coupons.len > 0) g.free(self.refund_coupons);
        self.* = undefined;
    }
};

/// 读取 `name_N`/`name_N_M` 形式的键并 dupe(缺失=空串,与 mapToFields.borrow 语义一致)。
fn idxDupe(gpa: std.mem.Allocator, map: xml.Map, kb: []u8, comptime name: []const u8, i: usize, j: ?usize) ![]u8 {
    const key = if (j) |jj|
        std.fmt.bufPrint(kb, name ++ "_{d}_{d}", .{ i, jj }) catch unreachable
    else
        std.fmt.bufPrint(kb, name ++ "_{d}", .{i}) catch unreachable;
    return gpa.dupe(u8, get(map, key));
}

/// 对应 `WxPayRefundQueryResult`:顶层字段 + `refund_count` 条退款记录
/// (对应 Java `loadXml` + `composeRefundRecords`)。
/// 所有权:切片逐元素 deinit;`len != 0` 时由调用方 `free` 切片本身。
pub const RefundQueryResult = struct {
    gpa: std.mem.Allocator,
    base: BaseResult,
    device_info: []u8 = "",
    transaction_id: []u8 = "",
    out_trade_no: []u8 = "",
    fee_type: []u8 = "",
    total_fee: []u8 = "",
    /// 退款记录数(字符串原样保存;记录见 refund_records)
    refund_count: []u8 = "",
    /// 对应 Java `refundRecords`(由 refund_count 驱动,解析 `*_N` 字段)。
    refund_records: []RefundRecord = &.{},

    const top_keys = [_][]const u8{ "device_info", "transaction_id", "out_trade_no", "fee_type", "total_fee", "refund_count" };

    pub fn fromMap(gpa: std.mem.Allocator, map: xml.Map) !RefundQueryResult {
        var self = RefundQueryResult{ .gpa = gpa, .base = try BaseResult.fromMap(gpa, map) };
        errdefer self.base.deinit();
        var out: [top_keys.len][]u8 = undefined;
        for (&out) |*s| s.* = "";
        errdefer for (out) |s| gpa.free(s);
        try dupeFields(gpa, map, &top_keys, &out);
        self.device_info = out[0];
        self.transaction_id = out[1];
        self.out_trade_no = out[2];
        self.fee_type = out[3];
        self.total_fee = out[4];
        self.refund_count = out[5];

        // 记录数由 refund_count 驱动(对应 Java composeRefundRecords 的 for i<refundCount)
        const n = std.fmt.parseInt(usize, self.refund_count, 10) catch 0;
        if (n > 0) {
            var records: std.ArrayList(RefundRecord) = .empty;
            errdefer {
                for (records.items) |*rec| rec.deinit();
                records.deinit(gpa);
            }
            for (0..n) |i| try records.append(gpa, try RefundRecord.fromIndex(gpa, map, i));
            self.refund_records = try records.toOwnedSlice(gpa);
        }
        return self;
    }

    pub fn deinit(self: *RefundQueryResult) void {
        const g = self.gpa;
        self.base.deinit();
        for ([_][]u8{ self.device_info, self.transaction_id, self.out_trade_no, self.fee_type, self.total_fee, self.refund_count }) |s| g.free(s);
        for (self.refund_records) |*rec| rec.deinit();
        if (self.refund_records.len > 0) g.free(self.refund_records);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "v2 sign fixed vectors (MD5 / HMAC-SHA256, python3 交叉验证)" {
    const gpa = std.testing.allocator;
    // 待签串(字典序 + 跳空 + 末尾 &key=):
    // appid=wxtest&mch_id=1900010&nonce_str=Nn1&out_trade_no=T20261108&total_fee=1&key=TESTKEY123
    const fields = [_]sign_mod.Field{
        .{ .key = "out_trade_no", .value = "T20261108" },
        .{ .key = "nonce_str", .value = "Nn1" },
        .{ .key = "appid", .value = "wxtest" },
        .{ .key = "total_fee", .value = "1" },
        .{ .key = "mch_id", .value = "1900010" },
        .{ .key = "body", .value = "" }, // 空值跳过
    };
    const md5_sig = try sign_mod.signV2(gpa, &fields, "TESTKEY123", .md5);
    defer gpa.free(md5_sig);
    try std.testing.expectEqualStrings("F88B4BE4021A9E9D4E2677726588DFFF", md5_sig);

    const hmac_sig = try sign_mod.signV2(gpa, &fields, "TESTKEY123", .hmac_sha256);
    defer gpa.free(hmac_sig);
    try std.testing.expectEqualStrings(
        "AC9C891770B113FA1D60CF618D4AEC3A45F54E666B278672DA4BE3B9904BE4CD",
        hmac_sig,
    );
}

test "xml map -> fields roundtrip (borrow contract)" {
    const gpa = std.testing.allocator;
    const resp =
        \\<xml><return_code><![CDATA[SUCCESS]]></return_code><result_code><![CDATA[SUCCESS]]></result_code><out_trade_no><![CDATA[T1]]></out_trade_no><sign><![CDATA[ABC]]></sign></xml>
    ;
    var m = try xml.parse(gpa, resp);
    defer xml.freeMap(&m);
    const fields = try mapToFields(gpa, &m);
    defer gpa.free(fields);
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    // key 借用原始报文:与输入指针同段内存
    for (fields) |f| {
        try std.testing.expect(
            @intFromPtr(f.key.ptr) >= @intFromPtr(resp.ptr) and
                @intFromPtr(f.key.ptr) < @intFromPtr(resp.ptr) + resp.len,
        );
    }
}

test "v2 order query result parse + businessOk" {
    const gpa = std.testing.allocator;
    const resp =
        \\<xml><return_code><![CDATA[SUCCESS]]></return_code><result_code><![CDATA[SUCCESS]]></result_code><trade_state><![CDATA[SUCCESS]]></trade_state><out_trade_no><![CDATA[T1]]></out_trade_no><transaction_id><![CDATA[wx42]]></transaction_id><total_fee><![CDATA[1]]></total_fee></xml>
    ;
    var m = try xml.parse(gpa, resp);
    defer xml.freeMap(&m);
    var r = try OrderQueryResult.fromMap(gpa, m);
    defer r.deinit();
    try std.testing.expect(r.base.businessOk());
    try std.testing.expectEqualStrings("SUCCESS", r.trade_state);
    try std.testing.expectEqualStrings("wx42", r.transaction_id);
    try std.testing.expectEqualStrings("", r.openid); // 缺失字段=空串
}
