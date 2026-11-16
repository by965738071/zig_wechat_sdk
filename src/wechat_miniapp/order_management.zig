//! 订单管理(订单中心)服务 —— 对应 Java `api.WxMaOrderManagementService` +
//! `api.impl.WxMaOrderManagementServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.OrderManagement`:
//! - getOrderDetailPath:POST /wxa/sec/order/get_order_detail_path(空请求体 {})
//!   → GetOrderDetailPath{path}(未配置过时 path 为 "");
//! - updateOrderDetailPath:POST /wxa/sec/order/update_order_detail_path {path}
//!   (path 必须包含 "${商品订单号}",调用前需先签署订单中心授权协议)。
//! errcode≠0 已由基座折叠为 `.err`;Java 的 errcode/errmsg 载荷字段不再保留。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_ORDER_DETAIL_PATH_URL = "https://api.weixin.qq.com/wxa/sec/order/get_order_detail_path";
const UPDATE_ORDER_DETAIL_PATH_URL = "https://api.weixin.qq.com/wxa/sec/order/update_order_detail_path";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean -----------------------------------------------------------------------

/// 对应 `order.WxMaOrderManagementGetOrderDetailPath`(path)。gpa 拥有。
pub const GetOrderDetailPath = struct {
    gpa: std.mem.Allocator,
    /// 订单详情路径;未配置过时为空字符串(微信返回 path:"" 也归一化为 "")。
    path: []const u8,

    pub fn deinit(self: *GetOrderDetailPath) void {
        const g = self.gpa;
        g.free(@constCast(self.path));
        self.* = undefined;
    }
};

// --- service ----------------------------------------------------------------------

pub const OrderManagementService = struct {
    svc: *mp_service.Service,

    /// 对应 `getOrderDetailPath()`:POST get_order_detail_path(空请求体)。
    /// 注意:未配置过订单详情路径时返回成功且 path 为 ""。
    pub fn getOrderDetailPath(self: *OrderManagementService, io: std.Io) WxResult(GetOrderDetailPath) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_ORDER_DETAIL_PATH_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "order detail path not json", .{}) };
        defer parsed.deinit();
        const path = json_util.getStr(parsed.value, "path") orelse "";
        const owned = gpa.dupe(u8, path) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .path = owned } };
    }

    /// 对应 `updateOrderDetailPath(String)`:POST update_order_detail_path {path}。
    pub fn updateOrderDetailPath(self: *OrderManagementService, io: std.Io, path: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"path\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, path) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_ORDER_DETAIL_PATH_URL, &.{}, body)) {
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

test "order management get/update order detail path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_order_detail_path", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"path\":\"pages/order/detail?id=${out_trade_no}\"}" },
        .{ .match = "update_order_detail_path", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OrderManagementService{ .svc = &base };

    // get:POST 空请求体,解析 path
    var got = switch (s.getOrderDetailPath(io)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/get_order_detail_path") != null);
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expectEqualStrings("pages/order/detail?id=${out_trade_no}", got.path);

    // 未配置过:path 为 ""(微信返回空字符串,归一化)
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_order_detail_path", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"path\":\"\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = OrderManagementService{ .svc = &base2 };
    var got2 = switch (s2.getOrderDetailPath(io)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got2.deinit();
    try std.testing.expectEqualStrings("", got2.path);

    // update:POST {path}
    const updated = switch (s.updateOrderDetailPath(io, "pages/order/detail?id=${out_trade_no}")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    _ = updated;
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "sec/order/update_order_detail_path") != null);
    try std.testing.expectEqualStrings("{\"path\":\"pages/order/detail?id=${out_trade_no}\"}", m.last_body);
}
