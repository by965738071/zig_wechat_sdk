//! 物流助手服务 —— 对应 Java `api.WxMaExpressService` +
//! `api.impl.WxMaExpressServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Express`(/cgi-bin/express/business/):
//! - getAllDelivery:GET delivery/getall → data[] → []Delivery;
//! - getAllAccount:GET account/getall → list[] → []Account;
//! - bindAccount:POST account/bind(BindAccountRequest)→ Done
//!   (Java 解析 InfoResult{errcode,errmsg},errcode≠0 已折叠);
//! - getQuota:POST quota/get(BindAccountRequest)→ quota_num;
//! - updatePrinter:POST printer/update{openid,update_type,tagid_list?};
//! - getPrinter:GET printer/getall → Printer{count?,openid[],tagid_list[]};
//! - addOrder:POST order/add(预构建体)→ OrderInfo;
//! - batchGetOrder:POST order/batchget {"order_list":[预构建条目]} → []OrderInfo;
//! - cancelOrder:POST order/cancel(GetOrderRequest)→ Done;
//! - getOrder:POST order/get(GetOrderRequest)→ OrderInfo;
//! - getPath:POST path/get(GetOrderRequest)→ Path;
//! - testUpdateOrder:POST test_update_order → Done。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const ALL_DELIVERY_URL = "https://api.weixin.qq.com/cgi-bin/express/business/delivery/getall";
const ALL_ACCOUNT_URL = "https://api.weixin.qq.com/cgi-bin/express/business/account/getall";
const BIND_ACCOUNT_URL = "https://api.weixin.qq.com/cgi-bin/express/business/account/bind";
const GET_QUOTA_URL = "https://api.weixin.qq.com/cgi-bin/express/business/quota/get";
const UPDATE_PRINTER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/printer/update";
const GET_PRINTER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/printer/getall";
const ADD_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/order/add";
const BATCH_GET_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/order/batchget";
const CANCEL_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/order/cancel";
const GET_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/order/get";
const GET_PATH_URL = "https://api.weixin.qq.com/cgi-bin/express/business/path/get";
const TEST_UPDATE_ORDER_URL = "https://api.weixin.qq.com/cgi-bin/express/business/test_update_order";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `express.WxMaExpressDelivery.ServiceType`。gpa 拥有。
pub const ServiceType = struct {
    service_type: ?i64,
    service_name: ?[]const u8,
};

/// 对应 `express.WxMaExpressDelivery`。gpa 拥有。
pub const Delivery = struct {
    gpa: std.mem.Allocator,
    delivery_id: ?[]const u8,
    delivery_name: ?[]const u8,
    can_use_cash: ?i64,
    can_get_quota: ?i64,
    cash_biz_id: ?[]const u8,
    service_type: []ServiceType,

    pub fn deinit(self: *Delivery) void {
        const g = self.gpa;
        if (self.delivery_id) |s| g.free(@constCast(s));
        if (self.delivery_name) |s| g.free(@constCast(s));
        if (self.cash_biz_id) |s| g.free(@constCast(s));
        for (self.service_type) |st| {
            if (st.service_name) |s| g.free(@constCast(s));
        }
        g.free(self.service_type);
    }

    pub fn deinitConst(self: *const Delivery) void {
        const g = self.gpa;
        if (self.delivery_id) |s| g.free(s);
        if (self.delivery_name) |s| g.free(s);
        if (self.cash_biz_id) |s| g.free(s);
        for (self.service_type) |st| {
            if (st.service_name) |s| g.free(s);
        }
        g.free(self.service_type);
    }
};

/// 对应 `express.WxMaExpressAccount`。gpa 拥有。
pub const Account = struct {
    gpa: std.mem.Allocator,
    biz_id: ?[]const u8,
    delivery_id: ?[]const u8,
    create_time: ?i64,
    update_time: ?i64,
    status_code: ?i64,
    alias: ?[]const u8,
    remark_wrong_msg: ?[]const u8,
    remark_content: ?[]const u8,
    quota_num: ?i64,
    quota_update_time: ?i64,
    service_type: []ServiceType,

    pub fn deinit(self: *Account) void {
        const g = self.gpa;
        if (self.biz_id) |s| g.free(@constCast(s));
        if (self.delivery_id) |s| g.free(@constCast(s));
        if (self.alias) |s| g.free(@constCast(s));
        if (self.remark_wrong_msg) |s| g.free(@constCast(s));
        if (self.remark_content) |s| g.free(@constCast(s));
        for (self.service_type) |st| {
            if (st.service_name) |s| g.free(@constCast(s));
        }
        g.free(self.service_type);
    }

    pub fn deinitConst(self: *const Account) void {
        const g = self.gpa;
        if (self.biz_id) |s| g.free(s);
        if (self.delivery_id) |s| g.free(s);
        if (self.alias) |s| g.free(s);
        if (self.remark_wrong_msg) |s| g.free(s);
        if (self.remark_content) |s| g.free(s);
        for (self.service_type) |st| {
            if (st.service_name) |s| g.free(s);
        }
        g.free(self.service_type);
    }
};

/// 对应 `express.request.WxMaExpressBindAccountRequest`
/// (type,biz_id,delivery_id,password,remark_content,null 省略)。
pub const BindAccountRequest = struct {
    type_: i64,
    biz_id: []const u8,
    delivery_id: []const u8,
    password: []const u8,
    remark_content: []const u8,

    pub fn to_json(self: BindAccountRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"type\":{d},\"biz_id\":", .{self.type_});
        try js(w, self.biz_id);
        try w.writeAll(",\"delivery_id\":");
        try js(w, self.delivery_id);
        try w.writeAll(",\"password\":");
        try js(w, self.password);
        try w.writeAll(",\"remark_content\":");
        try js(w, self.remark_content);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `express.request.WxMaExpressGetOrderRequest`
/// (order_id,openid?,delivery_id,waybill_id;null 省略,与 Gson 默认一致)。
pub const GetOrderRequest = struct {
    order_id: []const u8,
    openid: ?[]const u8 = null,
    delivery_id: []const u8,
    waybill_id: []const u8,

    pub fn to_json(self: GetOrderRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"order_id\":");
        try js(w, self.order_id);
        if (self.openid) |v| {
            try w.writeAll(",\"openid\":");
            try js(w, v);
        }
        try w.writeAll(",\"delivery_id\":");
        try js(w, self.delivery_id);
        try w.writeAll(",\"waybill_id\":");
        try js(w, self.waybill_id);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `express.request.WxMaExpressPrinterUpdateRequest`
/// (openid,update_type,tagid_list?)。
pub const PrinterUpdateRequest = struct {
    openid: []const u8,
    update_type: []const u8,
    tagid_list: ?[]const u8 = null,

    pub fn to_json(self: PrinterUpdateRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"update_type\":");
        try js(w, self.update_type);
        if (self.tagid_list) |v| {
            try w.writeAll(",\"tagid_list\":");
            try js(w, v);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `express.request.WxMaExpressTestUpdateOrderRequest`
/// (biz_id 缺省 "test_biz_id",delivery_id 缺省 "TEST")。
pub const TestUpdateOrderRequest = struct {
    order_id: []const u8,
    waybill_id: []const u8,
    action_time: i64,
    action_type: i64,
    action_msg: []const u8,
    biz_id: []const u8 = "test_biz_id",
    delivery_id: []const u8 = "TEST",

    pub fn to_json(self: TestUpdateOrderRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"biz_id\":");
        try js(w, self.biz_id);
        try w.writeAll(",\"delivery_id\":");
        try js(w, self.delivery_id);
        try w.writeAll(",\"order_id\":");
        try js(w, self.order_id);
        try w.writeAll(",\"waybill_id\":");
        try js(w, self.waybill_id);
        try w.print(",\"action_time\":{d},\"action_type\":{d},\"action_msg\":", .{ self.action_time, self.action_type });
        try js(w, self.action_msg);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `express.WxMaExpressPrinter`(count?,openid[],tagid_list[])。gpa 拥有。
pub const Printer = struct {
    gpa: std.mem.Allocator,
    count: ?i64,
    openid: [][]const u8,
    tagid_list: [][]const u8,

    pub fn deinit(self: *Printer) void {
        const g = self.gpa;
        for (self.openid) |s| g.free(@constCast(s));
        g.free(self.openid);
        for (self.tagid_list) |s| g.free(@constCast(s));
        g.free(self.tagid_list);
    }

    pub fn deinitConst(self: *const Printer) void {
        const g = self.gpa;
        for (self.openid) |s| g.free(s);
        g.free(self.openid);
        for (self.tagid_list) |s| g.free(s);
        g.free(self.tagid_list);
    }
};

/// 对应 `express.result.WxMaExpressOrderInfoResult`。gpa 拥有;
/// waybill_data 保留原始 JSON 文本(Java 为 List<WaybillData>,此处原样)。
pub const OrderInfo = struct {
    gpa: std.mem.Allocator,
    order_id: ?[]const u8,
    waybill_id: ?[]const u8,
    print_html: ?[]const u8,
    waybill_data: ?[]const u8,
    order_status: ?i64,

    pub fn deinit(self: *OrderInfo) void {
        const g = self.gpa;
        if (self.order_id) |s| g.free(@constCast(s));
        if (self.waybill_id) |s| g.free(@constCast(s));
        if (self.print_html) |s| g.free(@constCast(s));
        if (self.waybill_data) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const OrderInfo) void {
        const g = self.gpa;
        if (self.order_id) |s| g.free(s);
        if (self.waybill_id) |s| g.free(s);
        if (self.print_html) |s| g.free(s);
        if (self.waybill_data) |s| g.free(s);
    }
};

/// 对应 `express.WxMaExpressPath`。gpa 拥有。
pub const Path = struct {
    gpa: std.mem.Allocator,
    openid: ?[]const u8,
    delivery_id: ?[]const u8,
    waybill_id: ?[]const u8,
    path_item_num: ?i64,
    path_item_list: []PathItem,

    pub const PathItem = struct {
        action_time: ?i64,
        action_type: ?i64,
        action_msg: ?[]const u8,
    };

    pub fn deinit(self: *Path) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(@constCast(s));
        if (self.delivery_id) |s| g.free(@constCast(s));
        if (self.waybill_id) |s| g.free(@constCast(s));
        for (self.path_item_list) |item| {
            if (item.action_msg) |s| g.free(@constCast(s));
        }
        g.free(self.path_item_list);
    }

    pub fn deinitConst(self: *const Path) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(s);
        if (self.delivery_id) |s| g.free(s);
        if (self.waybill_id) |s| g.free(s);
        for (self.path_item_list) |item| {
            if (item.action_msg) |s| g.free(s);
        }
        g.free(self.path_item_list);
    }
};

fn deinitDeliveries(gpa: std.mem.Allocator, list: []Delivery) void {
    for (list) |*d| d.deinit();
    gpa.free(list);
}

fn deinitAccounts(gpa: std.mem.Allocator, list: []Account) void {
    for (list) |*a| a.deinit();
    gpa.free(list);
}

fn deinitOrders(gpa: std.mem.Allocator, list: []OrderInfo) void {
    for (list) |*o| o.deinit();
    gpa.free(list);
}

// --- service -------------------------------------------------------------------

pub const ExpressService = struct {
    svc: *mp_service.Service,

    /// 对应 `getAllDelivery()`:GET delivery/getall → data[]。
    pub fn getAllDelivery(self: *ExpressService, io: std.Io) WxResult([]Delivery) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, ALL_DELIVERY_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express delivery not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "data") orelse
            return .{ .ok = &[_]Delivery{} };
        const list = gpa.alloc(Delivery, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*d| d.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = parseDelivery(gpa, item) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        return .{ .ok = list };
    }

    /// 对应 `getAllAccount()`:GET account/getall → list[]。
    pub fn getAllAccount(self: *ExpressService, io: std.Io) WxResult([]Account) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, ALL_ACCOUNT_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express account not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "list") orelse
            return .{ .ok = &[_]Account{} };
        const list = gpa.alloc(Account, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*a| a.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = parseAccount(gpa, item) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        return .{ .ok = list };
    }

    /// 对应 `bindAccount(request)`:POST account/bind → Done。
    pub fn bindAccount(self: *ExpressService, io: std.Io, req: BindAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, BIND_ACCOUNT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getQuota(request)`:POST quota/get → quota_num。
    pub fn getQuota(self: *ExpressService, io: std.Io, req: BindAccountRequest) WxResult(i64) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_QUOTA_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express quota not json", .{}) };
        defer parsed.deinit();
        const n = json_util.getInt(parsed.value, "quota_num") orelse
            return .{ .err = WxError.transport(gpa, "express quota missing `quota_num`", .{}) };
        return .{ .ok = n };
    }

    /// 对应 `updatePrinter(request)`:POST printer/update → Done。
    pub fn updatePrinter(self: *ExpressService, io: std.Io, req: PrinterUpdateRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_PRINTER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getPrinter()`:GET printer/getall → Printer。
    pub fn getPrinter(self: *ExpressService, io: std.Io) WxResult(Printer) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_PRINTER_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express printer not json", .{}) };
        defer parsed.deinit();
        var out = Printer{ .gpa = gpa, .count = null, .openid = &[_][]const u8{}, .tagid_list = &[_][]const u8{} };
        errdefer out.deinit();
        out.count = json_util.getInt(parsed.value, "count");
        if (json_util.getArray(parsed.value, "openid")) |arr| {
            out.openid = dupeStrArray(gpa, arr) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (json_util.getArray(parsed.value, "tagid_list")) |arr| {
            out.tagid_list = dupeStrArray(gpa, arr) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out };
    }

    /// 对应 `addOrder(request)`:POST order/add(请求体字段多且嵌套深,
    /// 由调用方预构建,与 complaint 模式一致)→ OrderInfo。
    pub fn addOrder(self: *ExpressService, io: std.Io, body: []const u8) WxResult(OrderInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, ADD_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseOrderInfo(gpa, resp);
    }

    /// 对应 `batchGetOrder(requests)`:POST order/batchget
    /// {"order_list":[预构建条目...]}(条目为 GetOrderRequest 的 JSON 或
    /// 任意预构建对象文本)→ order_list[] → []OrderInfo。
    pub fn batchGetOrder(self: *ExpressService, io: std.Io, order_json_items: []const []const u8) WxResult([]OrderInfo) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"order_list\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (order_json_items, 0..) |item, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.writeAll(item) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, BATCH_GET_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express batchget not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "order_list") orelse
            return .{ .ok = &[_]OrderInfo{} };
        const list = gpa.alloc(OrderInfo, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*o| o.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = parseOrderInfoValue(gpa, item) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        return .{ .ok = list };
    }

    /// 对应 `cancelOrder(request)`:POST order/cancel → Done。
    pub fn cancelOrder(self: *ExpressService, io: std.Io, req: GetOrderRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, CANCEL_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getOrder(request)`:POST order/get → OrderInfo。
    pub fn getOrder(self: *ExpressService, io: std.Io, req: GetOrderRequest) WxResult(OrderInfo) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseOrderInfo(gpa, resp);
    }

    /// 对应 `getPath(request)`:POST path/get → Path。
    pub fn getPath(self: *ExpressService, io: std.Io, req: GetOrderRequest) WxResult(Path) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_PATH_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "express path not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = Path{
            .gpa = gpa,
            .openid = null,
            .delivery_id = null,
            .waybill_id = null,
            .path_item_num = null,
            .path_item_list = &[_]Path.PathItem{},
        };
        errdefer out.deinit();
        if (json_util.getStr(v, "openid")) |s| out.openid = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "delivery_id")) |s| out.delivery_id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "waybill_id")) |s| out.waybill_id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        out.path_item_num = json_util.getInt(v, "path_item_num");
        if (json_util.getArray(v, "path_item_list")) |arr| {
            const items = gpa.alloc(Path.PathItem, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |item| {
                    if (item.action_msg) |s| gpa.free(@constCast(s));
                }
                gpa.free(items);
            }
            for (arr.items) |item| {
                var it = Path.PathItem{ .action_time = null, .action_type = null, .action_msg = null };
                it.action_time = json_util.getInt(item, "action_time");
                it.action_type = json_util.getInt(item, "action_type");
                if (json_util.getStr(item, "action_msg")) |s| it.action_msg = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                items[filled] = it;
                filled += 1;
            }
            out.path_item_list = items;
        }
        return .{ .ok = out };
    }

    /// 对应 `testUpdateOrder(request)`:POST test_update_order → Done。
    pub fn testUpdateOrder(self: *ExpressService, io: std.Io, req: TestUpdateOrderRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, TEST_UPDATE_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// --- 解析辅助 ------------------------------------------------------------------

fn parseServiceTypes(gpa: std.mem.Allocator, obj: std.json.Value) ![]ServiceType {
    const arr = json_util.getArray(obj, "service_type") orelse
        return &[_]ServiceType{};
    const list = try gpa.alloc(ServiceType, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |st| {
            if (st.service_name) |s| gpa.free(@constCast(s));
        }
        gpa.free(list);
    }
    for (arr.items) |item| {
        var st = ServiceType{ .service_type = null, .service_name = null };
        st.service_type = json_util.getInt(item, "service_type");
        if (json_util.getStr(item, "service_name")) |s| st.service_name = try gpa.dupe(u8, s);
        list[filled] = st;
        filled += 1;
    }
    return list;
}

fn parseDelivery(gpa: std.mem.Allocator, obj: std.json.Value) !Delivery {
    var d = Delivery{
        .gpa = gpa,
        .delivery_id = null,
        .delivery_name = null,
        .can_use_cash = null,
        .can_get_quota = null,
        .cash_biz_id = null,
        .service_type = &[_]ServiceType{},
    };
    errdefer d.deinit();
    if (json_util.getStr(obj, "delivery_id")) |s| d.delivery_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "delivery_name")) |s| d.delivery_name = try gpa.dupe(u8, s);
    d.can_use_cash = json_util.getInt(obj, "can_use_cash");
    d.can_get_quota = json_util.getInt(obj, "can_get_quota");
    if (json_util.getStr(obj, "cash_biz_id")) |s| d.cash_biz_id = try gpa.dupe(u8, s);
    d.service_type = try parseServiceTypes(gpa, obj);
    return d;
}

fn parseAccount(gpa: std.mem.Allocator, obj: std.json.Value) !Account {
    var a = Account{
        .gpa = gpa,
        .biz_id = null,
        .delivery_id = null,
        .create_time = null,
        .update_time = null,
        .status_code = null,
        .alias = null,
        .remark_wrong_msg = null,
        .remark_content = null,
        .quota_num = null,
        .quota_update_time = null,
        .service_type = &[_]ServiceType{},
    };
    errdefer a.deinit();
    if (json_util.getStr(obj, "biz_id")) |s| a.biz_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "delivery_id")) |s| a.delivery_id = try gpa.dupe(u8, s);
    a.create_time = json_util.getInt(obj, "create_time");
    a.update_time = json_util.getInt(obj, "update_time");
    a.status_code = json_util.getInt(obj, "status_code");
    if (json_util.getStr(obj, "alias")) |s| a.alias = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "remark_wrong_msg")) |s| a.remark_wrong_msg = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "remark_content")) |s| a.remark_content = try gpa.dupe(u8, s);
    a.quota_num = json_util.getInt(obj, "quota_num");
    a.quota_update_time = json_util.getInt(obj, "quota_update_time");
    a.service_type = try parseServiceTypes(gpa, obj);
    return a;
}

fn parseOrderInfo(gpa: std.mem.Allocator, resp: []const u8) WxResult(OrderInfo) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "express order not json", .{}) };
    defer parsed.deinit();
    const info = parseOrderInfoValue(gpa, parsed.value) catch
        return .{ .err = WxError.internal(gpa, "oom", .{}) };
    return .{ .ok = info };
}

fn parseOrderInfoValue(gpa: std.mem.Allocator, v: std.json.Value) !OrderInfo {
    var o = OrderInfo{
        .gpa = gpa,
        .order_id = null,
        .waybill_id = null,
        .print_html = null,
        .waybill_data = null,
        .order_status = null,
    };
    errdefer o.deinit();
    if (json_util.getStr(v, "order_id")) |s| o.order_id = try gpa.dupe(u8, s);
    if (json_util.getStr(v, "waybill_id")) |s| o.waybill_id = try gpa.dupe(u8, s);
    if (json_util.getStr(v, "print_html")) |s| o.print_html = try gpa.dupe(u8, s);
    // waybill_data 为对象数组,原样保留 JSON 文本
    if (json_util.getArray(v, "waybill_data")) |wd| {
        o.waybill_data = try json_util.stringify(gpa, wd);
    }
    o.order_status = json_util.getInt(v, "order_status");
    return o;
}

fn dupeStrArray(gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value)) ![][]const u8 {
    const list = try gpa.alloc([]const u8, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |s| gpa.free(@constCast(s));
        gpa.free(list);
    }
    for (arr.items) |item| {
        if (item != .string) continue;
        list[filled] = try gpa.dupe(u8, item.string);
        filled += 1;
    }
    return list[0..filled];
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "express delivery/account/printer" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "delivery/getall", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":[{\"delivery_id\":\"SF\",\"delivery_name\":\"顺丰速运\",\"can_use_cash\":1,\"can_get_quota\":0,\"cash_biz_id\":\"CASH\",\"service_type\":[{\"service_type\":1,\"service_name\":\"标准快递\"}]}]}" },
        .{ .match = "account/getall", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"list\":[{\"biz_id\":\"BIZ\",\"delivery_id\":\"SF\",\"create_time\":1690000000,\"update_time\":1690000001,\"status_code\":0,\"alias\":\"别名\",\"remark_wrong_msg\":\"\",\"remark_content\":\"备注\",\"quota_num\":100,\"quota_update_time\":1690000002,\"service_type\":[{\"service_type\":1,\"service_name\":\"标准快递\"}]}]}" },
        .{ .match = "account/bind", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "quota/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"quota_num\":45678}" },
        .{ .match = "printer/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "printer/getall", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"count\":2,\"openid\":[\"oP1\",\"oP2\"],\"tagid_list\":[\"12\",\"34\"]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ExpressService{ .svc = &base };

    // getAllDelivery:data[] + service_type[]
    const deliveries = switch (s.getAllDelivery(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer deinitDeliveries(gpa, deliveries);
    try std.testing.expectEqual(@as(usize, 1), deliveries.len);
    const d = deliveries[0];
    try std.testing.expectEqualStrings("SF", d.delivery_id.?);
    try std.testing.expectEqualStrings("顺丰速运", d.delivery_name.?);
    try std.testing.expectEqual(@as(i64, 1), d.can_use_cash.?);
    try std.testing.expectEqualStrings("CASH", d.cash_biz_id.?);
    try std.testing.expectEqual(@as(usize, 1), d.service_type.len);
    try std.testing.expectEqualStrings("标准快递", d.service_type[0].service_name.?);

    // getAllAccount:list[]
    const accounts = switch (s.getAllAccount(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer deinitAccounts(gpa, accounts);
    try std.testing.expectEqual(@as(usize, 1), accounts.len);
    const a = accounts[0];
    try std.testing.expectEqualStrings("BIZ", a.biz_id.?);
    try std.testing.expectEqual(@as(i64, 100), a.quota_num.?);
    try std.testing.expectEqual(@as(usize, 1), a.service_type.len);

    // bindAccount:POST → Done
    try std.testing.expect(!s.bindAccount(io, .{ .type_ = 1, .biz_id = "BIZ", .delivery_id = "SF", .password = "PWD", .remark_content = "备注" }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "account/bind") != null);
    const bind_body = try std.json.parseFromSlice(std.json.Value, gpa, m.last_body, .{});
    defer bind_body.deinit();
    try std.testing.expectEqualStrings("SF", bind_body.value.object.get("delivery_id").?.string);

    // getQuota:quota_num
    const quota = switch (s.getQuota(io, .{ .type_ = 1, .biz_id = "BIZ", .delivery_id = "SF", .password = "PWD", .remark_content = "备注" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 45678), quota);

    // updatePrinter
    try std.testing.expect(!s.updatePrinter(io, .{ .openid = "oP1", .update_type = "bind", .tagid_list = "123,456" }).failed());
    try std.testing.expectEqualStrings("{\"openid\":\"oP1\",\"update_type\":\"bind\",\"tagid_list\":\"123,456\"}", m.last_body);

    // getPrinter
    const printer = switch (s.getPrinter(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var p = printer;
        p.deinit();
    }
    try std.testing.expectEqual(@as(i64, 2), printer.count.?);
    try std.testing.expectEqual(@as(usize, 2), printer.openid.len);
    try std.testing.expectEqualStrings("oP2", printer.openid[1]);
    try std.testing.expectEqualStrings("34", printer.tagid_list[1]);
}

test "express order add/batchget/cancel/get + path + testUpdateOrder" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "order/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order_id\":\"OID1\",\"waybill_id\":\"SF123\",\"print_html\":\"<html/>\",\"waybill_data\":[{\"key\":\"A\"}],\"order_status\":0}" },
        .{ .match = "order/batchget", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order_list\":[{\"order_id\":\"OID1\",\"waybill_id\":\"SF123\",\"order_status\":0},{\"order_id\":\"OID2\",\"waybill_id\":\"SF124\",\"order_status\":1}]}" },
        .{ .match = "order/cancel", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "order/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order_id\":\"OID1\",\"waybill_id\":\"SF123\",\"order_status\":1}" },
        .{ .match = "path/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openid\":\"oP1\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF123\",\"path_item_num\":2,\"path_item_list\":[{\"action_time\":1690000000,\"action_type\":1001,\"action_msg\":\"已揽收\"},{\"action_time\":1690003600,\"action_type\":2002,\"action_msg\":\"运输中\"}]}" },
        .{ .match = "test_update_order", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ExpressService{ .svc = &base };

    // addOrder:预构建体原样发出
    const add_body = "{\"order_id\":\"OID1\",\"openid\":\"oP1\",\"delivery_id\":\"SF\",\"biz_id\":\"BIZ\"}";
    const order = switch (s.addOrder(io, add_body)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var o = order;
        o.deinit();
    }
    try std.testing.expectEqualStrings(add_body, m.last_body);
    try std.testing.expectEqualStrings("OID1", order.order_id.?);
    try std.testing.expectEqualStrings("SF123", order.waybill_id.?);
    try std.testing.expect(std.mem.indexOf(u8, order.waybill_data.?, "\"key\":\"A\"") != null);

    // batchGetOrder:order_list[] 拼接预构建条目
    const orders = switch (s.batchGetOrder(io, &.{ "{\"order_id\":\"OID1\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF123\"}", "{\"order_id\":\"OID2\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF124\"}" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer deinitOrders(gpa, orders);
    try std.testing.expectEqualStrings("{\"order_list\":[{\"order_id\":\"OID1\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF123\"},{\"order_id\":\"OID2\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF124\"}]}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), orders.len);
    try std.testing.expectEqualStrings("SF124", orders[1].waybill_id.?);

    // cancelOrder:null openid 省略
    try std.testing.expect(!s.cancelOrder(io, .{ .order_id = "OID1", .delivery_id = "SF", .waybill_id = "SF123" }).failed());
    try std.testing.expectEqualStrings("{\"order_id\":\"OID1\",\"delivery_id\":\"SF\",\"waybill_id\":\"SF123\"}", m.last_body);

    // getOrder:openid 存在时输出
    const got = switch (s.getOrder(io, .{ .order_id = "OID1", .openid = "oP1", .delivery_id = "SF", .waybill_id = "SF123" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var o = got;
        o.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"openid\":\"oP1\"") != null);
    try std.testing.expectEqual(@as(i64, 1), got.order_status.?);

    // getPath
    const path = switch (s.getPath(io, .{ .order_id = "OID1", .delivery_id = "SF", .waybill_id = "SF123" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var p = path;
        p.deinit();
    }
    try std.testing.expectEqualStrings("oP1", path.openid.?);
    try std.testing.expectEqual(@as(i64, 2), path.path_item_num.?);
    try std.testing.expectEqual(@as(usize, 2), path.path_item_list.len);
    try std.testing.expectEqualStrings("已揽收", path.path_item_list[0].action_msg.?);
    try std.testing.expectEqual(@as(i64, 1001), path.path_item_list[0].action_type.?);

    // testUpdateOrder:默认 biz_id/delivery_id
    try std.testing.expect(!s.testUpdateOrder(io, .{ .order_id = "OID1", .waybill_id = "SF123", .action_time = 1690000000, .action_type = 1001, .action_msg = "已揽收" }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"biz_id\":\"test_biz_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"delivery_id\":\"TEST\"") != null);
}
