//! 门店 Wi-Fi 服务 —— 逐字对齐 Java `api.WxMpWifiService` +
//! `api.impl.WxMpWifiServiceImpl`,端点常量取自 `api_url.zig:Wifi`
//! (镜像 Java `enums.WxMpApiUrl.Wifi`,3 个常量)。
//!
//! Java 接口 3 个方法(名称逐字对齐,impl:20-52):
//!   listShop(pageIndex,pageSize)       POST bizwifi/shop/list   {"pageindex","pagesize"}
//!                                      → data{totalcount,pageindex,pagecount,records[...]}
//!   getShopWifiInfo(shopId)            POST bizwifi/shop/get    {"shop_id"}
//!                                      → data{shop_name,ssid,ssid_list[...],protocol_type,...}
//!   updateShopWifiInfo(shopId,oldSsid,ssid,password)
//!                                      POST bizwifi/shop/update{"shop_id","old_ssid","ssid","password"?}
//!
//! Java↔Zig 差异:
//!   - `boolean` 返回值 → `Done`(`.ok`=true、`.err`=WxError);
//!   - 响应 bean 只建模核心字段(records 的 shop_id/shop_name/ssid、data 的 shop_name/ssid/
//!     ssid_list),其余字段(如 poi_id/sid/ssid_password_list)不编造,需要时调用方
//!     取原始响应自行解析;
//!   - `updateShopWifiInfo` 的 password 为 null 时省略字段(Java impl:46-49)。
//!
//! 内存所有权:结果结构体持有 gpa,用毕 `deinit()`;`.err` 载荷 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;

/// 一家门店的 Wi-Fi 记录 —— 对应 `WxMpWifiShopListResult.Record`
/// 的 @SerializedName 核心字段(shop_id/shop_name/ssid)。全部 gpa 拥有。
pub const ShopRecord = struct {
    gpa: std.mem.Allocator,
    shop_id: i64 = 0,
    shop_name: []u8,
    ssid: []u8,

    pub fn deinit(self: *ShopRecord) void {
        self.gpa.free(self.shop_name);
        self.gpa.free(self.ssid);
        self.* = undefined;
    }
};

/// 门店 Wi-Fi 列表 —— 对应 `WxMpWifiShopListResult`(data 剥壳后)。
pub const ShopListResult = struct {
    gpa: std.mem.Allocator,
    total_count: i64 = 0,
    page_index: i64 = 0,
    page_count: i64 = 0,
    records: []ShopRecord = &.{},

    pub fn deinit(self: *ShopListResult) void {
        for (self.records) |*r| r.deinit();
        if (self.records.len > 0) self.gpa.free(self.records);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !ShopListResult {
        var r = ShopListResult{ .gpa = gpa };
        errdefer r.deinit();
        r.total_count = json_util.getIntOr(v, "totalcount", 0);
        r.page_index = json_util.getIntOr(v, "pageindex", 0);
        r.page_count = json_util.getIntOr(v, "pagecount", 0);
        var list: std.ArrayList(ShopRecord) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getArray(v, "records")) |arr| {
            for (arr.items) |item| {
                var rec = ShopRecord{
                    .gpa = gpa,
                    .shop_id = json_util.getIntOr(item, "shop_id", 0),
                    .shop_name = try gpa.dupe(u8, json_util.getStrOr(item, "shop_name", "")),
                    .ssid = try gpa.dupe(u8, json_util.getStrOr(item, "ssid", "")),
                };
                errdefer rec.deinit();
                try list.append(gpa, rec);
            }
        }
        r.records = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// 单店 Wi-Fi 数据 —— 对应 `WxMpWifiShopDataResult`(data 剥壳后)。
pub const ShopDataResult = struct {
    gpa: std.mem.Allocator,
    shop_name: []u8,
    ssid: []u8,
    ssid_list: [][]u8 = &.{},

    pub fn deinit(self: *ShopDataResult) void {
        self.gpa.free(self.shop_name);
        self.gpa.free(self.ssid);
        for (self.ssid_list) |s| self.gpa.free(s);
        if (self.ssid_list.len > 0) self.gpa.free(self.ssid_list);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !ShopDataResult {
        var r = ShopDataResult{
            .gpa = gpa,
            .shop_name = try gpa.dupe(u8, json_util.getStrOr(v, "shop_name", "")),
            .ssid = try gpa.dupe(u8, json_util.getStrOr(v, "ssid", "")),
        };
        errdefer r.deinit();
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        if (json_util.getArray(v, "ssid_list")) |arr| {
            for (arr.items) |item| switch (item) {
                .string => |s| try list.append(gpa, try gpa.dupe(u8, s)),
                else => {},
            };
        }
        r.ssid_list = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// 解析 `"data"` 剥壳(Java `GsonParser.parse(json).get("data")` 在 fromJson 内完成)。
fn dataField(gpa: std.mem.Allocator, resp: []const u8, what: []const u8) WxResult(std.json.Parsed(json_util.Value)) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "{s} response not json", .{what}) };
    if (json_util.getObject(parsed.value, "data") == null)
        return .{ .err = WxError.transport(gpa, "{s} response missing data", .{what}) };
    return .{ .ok = parsed };
}

pub const WifiService = struct {
    svc: *service_mod.Service,

    /// 对应 `#listShop`(impl:20-27):POST {"pageindex","pagesize"} → data 剥壳解析。
    pub fn listShop(self: *WifiService, io: std.Io, page_index: i64, page_size: i64) WxResult(ShopListResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("pageindex", page_index) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("pagesize", page_size) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Wifi.bizwifi_shop_list, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = switch (dataField(gpa, resp, "bizwifi/shop/list")) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data").?;
        const r = ShopListResult.fromJson(gpa, data) catch
            return .{ .err = WxError.transport(gpa, "bizwifi/shop/list parse failed", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `#getShopWifiInfo`(impl:29-35):POST {"shop_id"} → data 剥壳解析。
    pub fn getShopWifiInfo(self: *WifiService, io: std.Io, shop_id: i64) WxResult(ShopDataResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("shop_id", shop_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Wifi.bizwifi_shop_get, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = switch (dataField(gpa, resp, "bizwifi/shop/get")) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data").?;
        const r = ShopDataResult.fromJson(gpa, data) catch
            return .{ .err = WxError.transport(gpa, "bizwifi/shop/get parse failed", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `#updateShopWifiInfo`(impl:37-45):POST {"shop_id","old_ssid","ssid","password"?}。
    pub fn updateShopWifiInfo(self: *WifiService, io: std.Io, shop_id: i64, old_ssid: []const u8, ssid: []const u8, password: ?[]const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("shop_id", shop_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("old_ssid", old_ssid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("ssid", ssid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (password) |p| ob.putStr("password", p) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Wifi.bizwifi_shop_update, body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:3 端点 URL/method/请求体 + data 剥壳解析
// (逐字对照 WxMpApiUrl.Wifi + WxMpWifiServiceImpl + WxMpWifiShop*Result)
// ---------------------------------------------------------------------------

test "Wifi 契约: 3 端点 URL/method/请求体 + data 剥壳 (WxMpApiUrl.Wifi)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "bizwifi/shop/list", .response = "{\"errcode\":0,\"data\":{\"totalcount\":2,\"pageindex\":1,\"pagecount\":1,\"records\":[{\"shop_id\":101,\"shop_name\":\"门店A\",\"ssid\":\"WiFi-A\",\"poi_id\":\"P1\"},{\"shop_id\":102,\"shop_name\":\"门店B\",\"ssid\":\"WiFi-B\"}]}}" },
        .{ .match = "bizwifi/shop/get", .response = "{\"errcode\":0,\"data\":{\"shop_name\":\"门店A\",\"ssid\":\"WiFi-A\",\"ssid_list\":[\"WiFi-A\",\"WiFi-A-5G\"],\"protocol_type\":4}}" },
        .{ .match = "bizwifi/shop/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = WifiService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // listShop: {"pageindex","pagesize"} → data{totalcount,records[]}
    switch (svc.listShop(io, 1, 20)) {
        .ok => |*r| {
            var l = r.*;
            defer l.deinit();
            try testing.expectEqual(@as(i64, 2), l.total_count);
            try testing.expectEqual(@as(i64, 1), l.page_index);
            try testing.expectEqual(@as(usize, 2), l.records.len);
            try testing.expectEqual(@as(i64, 101), l.records[0].shop_id);
            try testing.expectEqualStrings("门店A", l.records[0].shop_name);
            try testing.expectEqualStrings("WiFi-A", l.records[0].ssid);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedWifiListShop;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "bizwifi/shop/list") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"pageindex\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"pagesize\":20") != null);

    // getShopWifiInfo: {"shop_id"} → data{shop_name,ssid,ssid_list[]}
    switch (svc.getShopWifiInfo(io, 101)) {
        .ok => |*r| {
            var d = r.*;
            defer d.deinit();
            try testing.expectEqualStrings("门店A", d.shop_name);
            try testing.expectEqualStrings("WiFi-A", d.ssid);
            try testing.expectEqual(@as(usize, 2), d.ssid_list.len);
            try testing.expectEqualStrings("WiFi-A-5G", d.ssid_list[1]);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedWifiGetShop;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "bizwifi/shop/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"shop_id\":101") != null);

    // updateShopWifiInfo: password 可选
    switch (svc.updateShopWifiInfo(io, 101, "WiFi-A", "WiFi-New", "pass123")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedWifiUpdateShop;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "bizwifi/shop/update") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"old_ssid\":\"WiFi-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"ssid\":\"WiFi-New\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"password\":\"pass123\"") != null);

    // password = null → 不出现 "password" 字段
    switch (svc.updateShopWifiInfo(io, 101, "WiFi-A", "WiFi-New", null)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedWifiUpdateShop2;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"password\"") == null);
    try testing.expectEqual(@as(usize, 4), mock.calls);
}
