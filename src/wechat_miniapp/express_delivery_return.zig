//! 物流退货组件服务 —— 对应 Java `api.WxMaExpressDeliveryReturnService` +
//! `api.impl.WxMaExpressDeliveryReturnServiceImpl`。
//!
//! URL 在 Java 接口上声明(非 WxMaApiUrlConstants):
//! - addDeliveryReturn(AddRequest):POST /cgi-bin/express/delivery/return/add;
//! - getDeliveryReturn(returnId):POST .../return/get {"return_id":...};
//! - unbindDeliveryReturn(returnId):POST .../return/unbind {"return_id":...};
//! 三者均返回 ReturnInfo(Java `WxMaExpressReturnInfoResult`,父类仅 errcode/errmsg)。
//!
//! 与 Java 的差异:
//! - Java 的 `status`/`order_status` 声明为 String,但微信实际可能返回数字
//!   (0/1/2…),Gson 会宽容转换;Zig 的 looseStr 同样接受数字并归一化为字符串。
//! - errcode≠0 已由基座折叠为 `.err`,errcode/errmsg 载荷字段不再保留。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const ADD_DELIVERY_RETURN_URL = "https://api.weixin.qq.com/cgi-bin/express/delivery/return/add";
const GET_DELIVERY_RETURN_URL = "https://api.weixin.qq.com/cgi-bin/express/delivery/return/get";
const UNBIND_DELIVERY_RETURN_URL = "https://api.weixin.qq.com/cgi-bin/express/delivery/return/unbind";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

/// 宽容取字符串:接受 .string/.number_string/.integer(对应 Gson 对 String 字段的
/// 数字→字符串宽容转换)。返回 gpa 拥有的副本;字段缺失/类型不识别返回 null。
fn looseStr(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) !?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const c = o.get(key) orelse return null;
    switch (c) {
        .string => |s| return try gpa.dupe(u8, s),
        .number_string => |s| return try gpa.dupe(u8, s),
        .integer => |i| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return null;
            return try gpa.dupe(u8, s);
        },
        else => return null,
    }
}

// --- bean -----------------------------------------------------------------------

/// 对应 `express.request.WxMaExpressOrderPerson`(发件人/收件人信息)。
/// name/province/city/area/address 必填,tel/mobile/company/post_code/country
/// 可空;null 字段序列化时省略(Gson 默认行为)。
pub const Person = struct {
    name: []const u8,
    tel: ?[]const u8 = null,
    mobile: ?[]const u8 = null,
    company: ?[]const u8 = null,
    post_code: ?[]const u8 = null,
    country: ?[]const u8 = null,
    province: []const u8,
    city: []const u8,
    area: []const u8,
    address: []const u8,

    fn writeTo(self: Person, w: *std.Io.Writer) !void {
        try w.writeAll("{\"name\":");
        try js(w, self.name);
        if (self.tel) |v| {
            try w.writeAll(",\"tel\":");
            try js(w, v);
        }
        if (self.mobile) |v| {
            try w.writeAll(",\"mobile\":");
            try js(w, v);
        }
        if (self.company) |v| {
            try w.writeAll(",\"company\":");
            try js(w, v);
        }
        if (self.post_code) |v| {
            try w.writeAll(",\"post_code\":");
            try js(w, v);
        }
        if (self.country) |v| {
            try w.writeAll(",\"country\":");
            try js(w, v);
        }
        try w.writeAll(",\"province\":");
        try js(w, self.province);
        try w.writeAll(",\"city\":");
        try js(w, self.city);
        try w.writeAll(",\"area\":");
        try js(w, self.area);
        try w.writeAll(",\"address\":");
        try js(w, self.address);
        try w.writeByte('}');
    }
};

/// 对应 `express.request.WxMaExpressReturnOrder`(退货商品)。
pub const ReturnOrder = struct {
    name: []const u8,
    url: []const u8,
};

/// 对应 `express.request.WxMaExpressDeliveryReturnAddRequest`(创建退货单请求)。
/// 字段序对齐 Java 声明序(shop_order_id,biz_addr,user_addr,openid,
/// order_path,goods_list,order_price);user_addr/order_price 为 null 时省略。
pub const AddDeliveryReturnRequest = struct {
    /// 商家内部使用的退货编号。
    shop_order_id: []const u8,
    /// 商家退货地址。
    biz_addr: Person,
    /// 用户购物时的收货地址。
    user_addr: ?Person = null,
    /// 退货用户的 openid。
    openid: []const u8,
    /// 退货订单在小程序中的 path。
    order_path: []const u8,
    /// 退货商品列表。
    goods_list: []const ReturnOrder,
    /// 退货订单的金额(单位:分)。
    order_price: ?i64 = null,

    pub fn to_json(self: AddDeliveryReturnRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"shop_order_id\":");
        try js(w, self.shop_order_id);
        try w.writeAll(",\"biz_addr\":");
        try self.biz_addr.writeTo(w);
        if (self.user_addr) |u| {
            try w.writeAll(",\"user_addr\":");
            try u.writeTo(w);
        }
        try w.writeAll(",\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"order_path\":");
        try js(w, self.order_path);
        try w.writeAll(",\"goods_list\":[");
        for (self.goods_list, 0..) |g, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try js(w, g.name);
            try w.writeAll(",\"url\":");
            try js(w, g.url);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        if (self.order_price) |p| try w.print(",\"order_price\":{d}", .{p});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `express.result.WxMaExpressReturnInfoResult`。gpa 拥有。
/// status/order_status 微信可能返回数字,looseStr 归一化为字符串。
pub const ReturnInfo = struct {
    gpa: std.mem.Allocator,
    /// 退货 ID。
    return_id: ?[]const u8,
    /// 0 用户未填写退货信息,1 在线预约,2 自主填写。
    status: ?[]const u8,
    /// 运单 ID。
    waybill_id: ?[]const u8,
    /// 0 已下单待揽件 1 已揽件 2 运输中 3 派件中 4 已签收 5 异常 6 代签收
    /// 7 揽收失败 8 签收失败 11 已取消 13 退件中 14 已退件 99 未知。
    order_status: ?[]const u8,
    /// 运力公司名称。
    delivery_name: ?[]const u8,
    /// 运力公司 ID。
    delivery_id: ?[]const u8,

    pub fn deinit(self: *ReturnInfo) void {
        const g = self.gpa;
        if (self.return_id) |s| g.free(@constCast(s));
        if (self.status) |s| g.free(@constCast(s));
        if (self.waybill_id) |s| g.free(@constCast(s));
        if (self.order_status) |s| g.free(@constCast(s));
        if (self.delivery_name) |s| g.free(@constCast(s));
        if (self.delivery_id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const ReturnInfo) void {
        const g = self.gpa;
        if (self.return_id) |s| g.free(s);
        if (self.status) |s| g.free(s);
        if (self.waybill_id) |s| g.free(s);
        if (self.order_status) |s| g.free(s);
        if (self.delivery_name) |s| g.free(s);
        if (self.delivery_id) |s| g.free(s);
    }
};

// --- 响应解析 -------------------------------------------------------------------

fn parseReturnInfo(gpa: std.mem.Allocator, v: std.json.Value) !ReturnInfo {
    var r = ReturnInfo{
        .gpa = gpa,
        .return_id = null,
        .status = null,
        .waybill_id = null,
        .order_status = null,
        .delivery_name = null,
        .delivery_id = null,
    };
    errdefer r.deinit();
    if (json_util.getStr(v, "return_id")) |s| r.return_id = try gpa.dupe(u8, s);
    r.status = try looseStr(gpa, v, "status");
    if (json_util.getStr(v, "waybill_id")) |s| r.waybill_id = try gpa.dupe(u8, s);
    r.order_status = try looseStr(gpa, v, "order_status");
    if (json_util.getStr(v, "delivery_name")) |s| r.delivery_name = try gpa.dupe(u8, s);
    if (json_util.getStr(v, "delivery_id")) |s| r.delivery_id = try gpa.dupe(u8, s);
    return r;
}

// --- service ----------------------------------------------------------------------

pub const ExpressDeliveryReturnService = struct {
    svc: *mp_service.Service,

    /// 对应 `addDeliveryReturn(WxMaExpressDeliveryReturnAddRequest)`:
    /// POST return/add → ReturnInfo。
    pub fn addDeliveryReturn(self: *ExpressDeliveryReturnService, io: std.Io, req: AddDeliveryReturnRequest) WxResult(ReturnInfo) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, ADD_DELIVERY_RETURN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "delivery return add not json", .{}) };
        defer parsed.deinit();
        const info = parseReturnInfo(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = info };
    }

    /// 对应 `getDeliveryReturn(String returnId)`:POST return/get {"return_id":...}。
    pub fn getDeliveryReturn(self: *ExpressDeliveryReturnService, io: std.Io, return_id: []const u8) WxResult(ReturnInfo) {
        return self.queryReturn(io, GET_DELIVERY_RETURN_URL, return_id, "delivery return get not json");
    }

    /// 对应 `unbindDeliveryReturn(String returnId)`:POST return/unbind {"return_id":...}。
    pub fn unbindDeliveryReturn(self: *ExpressDeliveryReturnService, io: std.Io, return_id: []const u8) WxResult(ReturnInfo) {
        return self.queryReturn(io, UNBIND_DELIVERY_RETURN_URL, return_id, "delivery return unbind not json");
    }

    /// get/unbind 共用:POST {"return_id":...} → ReturnInfo。
    fn queryReturn(self: *ExpressDeliveryReturnService, io: std.Io, url: []const u8, return_id: []const u8, comptime not_json_msg: []const u8) WxResult(ReturnInfo) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"return_id\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, return_id) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeByte('}') catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, not_json_msg, .{}) };
        defer parsed.deinit();
        const info = parseReturnInfo(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = info };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "express delivery return add/get/unbind" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "delivery/return/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"return_id\":\"RID1\",\"status\":2,\"waybill_id\":\"WB1\",\"order_status\":0,\"delivery_name\":\"顺丰速运\",\"delivery_id\":\"SF\"}" },
        .{ .match = "delivery/return/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"return_id\":\"RID1\",\"status\":\"2\",\"waybill_id\":\"WB1\",\"order_status\":\"4\",\"delivery_name\":\"顺丰速运\",\"delivery_id\":\"SF\"}" },
        .{ .match = "delivery/return/unbind", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"return_id\":\"RID1\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ExpressDeliveryReturnService{ .svc = &base };

    // add:全量字段(user_addr/order_price 均包含)
    var added = switch (s.addDeliveryReturn(io, .{
        .shop_order_id = "SHOP-1",
        .biz_addr = .{
            .name = "商家甲",
            .tel = "020-12345678",
            .mobile = "13800000000",
            .company = "某公司",
            .post_code = "510000",
            .country = "中国",
            .province = "广东省",
            .city = "广州市",
            .area = "天河区",
            .address = "XX路XX号",
        },
        .user_addr = .{
            .name = "用户乙",
            .province = "广东省",
            .city = "深圳市",
            .area = "南山区",
            .address = "YY路YY号",
        },
        .openid = "OPENID",
        .order_path = "pages/order/detail?id=1",
        .goods_list = &.{
            .{ .name = "抱枕", .url = "https://img/1.png" },
            .{ .name = "毛巾", .url = "https://img/2.png" },
        },
        .order_price = 9900,
    })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer added.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cgi-bin/express/delivery/return/add") != null);
    try std.testing.expectEqualStrings(
        "{\"shop_order_id\":\"SHOP-1\",\"biz_addr\":{\"name\":\"商家甲\",\"tel\":\"020-12345678\",\"mobile\":\"13800000000\",\"company\":\"某公司\",\"post_code\":\"510000\",\"country\":\"中国\",\"province\":\"广东省\",\"city\":\"广州市\",\"area\":\"天河区\",\"address\":\"XX路XX号\"},\"user_addr\":{\"name\":\"用户乙\",\"province\":\"广东省\",\"city\":\"深圳市\",\"area\":\"南山区\",\"address\":\"YY路YY号\"},\"openid\":\"OPENID\",\"order_path\":\"pages/order/detail?id=1\",\"goods_list\":[{\"name\":\"抱枕\",\"url\":\"https://img/1.png\"},{\"name\":\"毛巾\",\"url\":\"https://img/2.png\"}],\"order_price\":9900}",
        m.last_body,
    );
    // 微信返回数字 status/order_status → 归一化为字符串
    try std.testing.expectEqualStrings("RID1", added.return_id.?);
    try std.testing.expectEqualStrings("2", added.status.?);
    try std.testing.expectEqualStrings("WB1", added.waybill_id.?);
    try std.testing.expectEqualStrings("0", added.order_status.?);
    try std.testing.expectEqualStrings("顺丰速运", added.delivery_name.?);
    try std.testing.expectEqualStrings("SF", added.delivery_id.?);

    // get:POST {"return_id":...},字符串形态 status 原样保留
    var got = switch (s.getDeliveryReturn(io, "RID1")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cgi-bin/express/delivery/return/get") != null);
    try std.testing.expectEqualStrings("{\"return_id\":\"RID1\"}", m.last_body);
    try std.testing.expectEqualStrings("2", got.status.?);
    try std.testing.expectEqualStrings("4", got.order_status.?);

    // unbind:POST {"return_id":...}
    var unbound = switch (s.unbindDeliveryReturn(io, "RID1")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer unbound.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cgi-bin/express/delivery/return/unbind") != null);
    try std.testing.expectEqualStrings("{\"return_id\":\"RID1\"}", m.last_body);
    try std.testing.expectEqualStrings("RID1", unbound.return_id.?);
    try std.testing.expect(unbound.status == null);
}

test "express delivery return add: 可选字段省略" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "delivery/return/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ExpressDeliveryReturnService{ .svc = &base };

    // user_addr/order_price 为 null → 省略;Person 可选字段(tel/mobile/company/
    // post_code/country)为 null → 省略
    switch (s.addDeliveryReturn(io, .{
        .shop_order_id = "SHOP-2",
        .biz_addr = .{
            .name = "商家丙",
            .province = "广东省",
            .city = "广州市",
            .area = "天河区",
            .address = "ZZ路ZZ号",
        },
        .openid = "OPENID",
        .order_path = "p",
        .goods_list = &.{.{ .name = "商品", .url = "https://img/3.png" }},
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings(
        "{\"shop_order_id\":\"SHOP-2\",\"biz_addr\":{\"name\":\"商家丙\",\"province\":\"广东省\",\"city\":\"广州市\",\"area\":\"天河区\",\"address\":\"ZZ路ZZ号\"},\"openid\":\"OPENID\",\"order_path\":\"p\",\"goods_list\":[{\"name\":\"商品\",\"url\":\"https://img/3.png\"}]}",
        m.last_body,
    );
}
