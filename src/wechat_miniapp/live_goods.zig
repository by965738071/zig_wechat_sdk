//! 直播商品服务 —— 对应 Java `api.WxMaLiveGoodsService` +
//! `api.impl.WxMaLiveGoodsServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Broadcast.Goods`
//! (/wxaapi/broadcast/goods/)与 /wxa/business/getgoodswarehouse:
//! - addGoods:POST add {"goodsInfo":预构建体} → LiveResult(total/audit_id/goods_id);
//! - resetAudit:POST resetaudit {auditId,goodsId}(驼峰)→ Done;
//! - auditGoods:POST audit {goodsId}(驼峰)→ audit_id;
//! - deleteGoods:POST delete {goodsId}(驼峰)→ Done;
//! - updateGoods:POST update {"goodsInfo":预构建体} → Done;
//! - getGoodsWareHouse:POST /wxa/business/getgoodswarehouse {goods_ids:[]}
//!   → LiveResult.goods;
//! - getApprovedGoods:GET getapproved?status&offset&limit
//!   → LiveResult.goods(响应为驼峰 key,补全为规范下划线 key,与 Java 变异一致);
//! - setKey:POST setkey {"goodsKey":[...]} → Done;
//! - getKey:GET getkey → vendorGoodsKey[](gpa 拥有)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

// 内部:写单个 JSON 字符串值(新建 Stringify,避免同一实例二次 write 报
// "JSON document already complete")。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

const ADD_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/add";
const RESET_AUDIT_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/resetaudit";
const AUDIT_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/audit";
const DELETE_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/delete";
const UPDATE_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/update";
const GET_GOODS_WARE_HOUSE_URL = "https://api.weixin.qq.com/wxa/business/getgoodswarehouse";
const GET_APPROVED_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/getapproved";
const SET_KEY_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/setkey";
const GET_KEY_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/getkey";

// --- bean ---------------------------------------------------------------------

/// 对应 `live.WxMaLiveResult.Goods`。gpa 拥有。
pub const Goods = struct {
    gpa: std.mem.Allocator,
    goods_id: ?i64,
    cover_img_url: ?[]const u8,
    cover_img: ?[]const u8,
    name: ?[]const u8,
    url: ?[]const u8,
    price_type: ?i64,
    audit_status: ?i64,
    price: ?f64,
    price2: ?f64,
    third_party_tag: ?[]const u8,
    third_party_appid: ?[]const u8,

    pub fn deinit(self: *Goods) void {
        const g = self.gpa;
        if (self.cover_img_url) |s| g.free(@constCast(s));
        if (self.cover_img) |s| g.free(@constCast(s));
        if (self.name) |s| g.free(@constCast(s));
        if (self.url) |s| g.free(@constCast(s));
        if (self.third_party_tag) |s| g.free(@constCast(s));
        if (self.third_party_appid) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const Goods) void {
        const g = self.gpa;
        if (self.cover_img_url) |s| g.free(s);
        if (self.cover_img) |s| g.free(s);
        if (self.name) |s| g.free(s);
        if (self.url) |s| g.free(s);
        if (self.third_party_tag) |s| g.free(s);
        if (self.third_party_appid) |s| g.free(s);
    }
};

/// 对应 `live.WxMaLiveResult`(total/audit_id/goods_id/goods[])。gpa 拥有。
pub const LiveResult = struct {
    gpa: std.mem.Allocator,
    total: ?i64,
    audit_id: ?i64,
    goods_id: ?i64,
    goods: []Goods,

    pub fn deinit(self: *LiveResult) void {
        const g = self.gpa;
        for (self.goods) |*item| item.deinit();
        g.free(self.goods);
    }

    pub fn deinitConst(self: *const LiveResult) void {
        const g = self.gpa;
        for (self.goods) |*item| item.deinitConst();
        g.free(self.goods);
    }
};

// --- service -------------------------------------------------------------------

pub const LiveGoodsService = struct {
    svc: *mp_service.Service,

    /// 对应 `addGoods(WxMaLiveGoodInfo)`:POST add {"goodsInfo":预构建体}
    /// → LiveResult(total/audit_id/goods_id)。
    pub fn addGoods(self: *LiveGoodsService, io: std.Io, goods_info_json: []const u8) WxResult(LiveResult) {
        const gpa = self.svc.gpa;
        const body = std.mem.concat(gpa, u8, &.{ "{\"goodsInfo\":", goods_info_json, "}" }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, ADD_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseLiveResult(gpa, resp);
    }

    /// 对应 `resetAudit(auditId, goodsId)`:POST resetaudit
    /// {auditId,goodsId}(驼峰,与 Java 一致)→ Done(Java 返回 true)。
    pub fn resetAudit(self: *LiveGoodsService, io: std.Io, audit_id: i64, goods_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"auditId\":{d},\"goodsId\":{d}}}", .{ audit_id, goods_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, RESET_AUDIT_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `auditGoods(goodsId)`:POST audit {goodsId}(驼峰)→ audit_id。
    pub fn auditGoods(self: *LiveGoodsService, io: std.Io, goods_id: i64) WxResult(i64) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"goodsId\":{d}}}", .{goods_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, AUDIT_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live audit goods not json", .{}) };
        defer parsed.deinit();
        const n = json_util.getInt(parsed.value, "auditId") orelse
            return .{ .err = WxError.transport(gpa, "live audit goods missing `auditId`", .{}) };
        return .{ .ok = n };
    }

    /// 对应 `deleteGoods(goodsId)`:POST delete {goodsId}(驼峰)→ Done。
    pub fn deleteGoods(self: *LiveGoodsService, io: std.Io, goods_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"goodsId\":{d}}}", .{goods_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DELETE_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `updateGoods(WxMaLiveGoodInfo)`:POST update
    /// {"goodsInfo":预构建体} → Done(Java 返回 true)。
    pub fn updateGoods(self: *LiveGoodsService, io: std.Io, goods_info_json: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.mem.concat(gpa, u8, &.{ "{\"goodsInfo\":", goods_info_json, "}" }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getGoodsWareHouse(goodsIds)`:POST /wxa/business/getgoodswarehouse
    /// {goods_ids:[...]} → LiveResult.goods。
    pub fn getGoodsWareHouse(self: *LiveGoodsService, io: std.Io, goods_ids: []const i64) WxResult(LiveResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"goods_ids\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (goods_ids, 0..) |id, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print("{d}", .{id}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, GET_GOODS_WARE_HOUSE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseLiveResult(gpa, resp);
    }

    /// 对应 `getApprovedGoods(offset, limit, status)`:GET getapproved
    /// ?status&offset&limit(全必填,与 Java ImmutableMap 一致)
    /// → LiveResult.goods。
    /// 响应 goods 数组为驼峰 key(goodsId/coverImgUrl/priceType/thirdPartyTag),
    /// 补全为规范下划线 key 且 audit_status = 入参 status,与 Java 变异一致。
    pub fn getApprovedGoods(self: *LiveGoodsService, io: std.Io, offset: i64, limit: i64, status: i64) WxResult(LiveResult) {
        const gpa = self.svc.gpa;
        var offset_buf: [24]u8 = undefined;
        var limit_buf: [24]u8 = undefined;
        var status_buf: [24]u8 = undefined;
        const resp = switch (self.svc.get(io, GET_APPROVED_GOODS_URL, &.{
            .{ .key = "status", .value = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "" },
            .{ .key = "offset", .value = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch "" },
            .{ .key = "limit", .value = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch "" },
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        // 解析驼峰 key 并归一化为 Goods
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live approved goods not json", .{}) };
        defer parsed.deinit();
        var out = LiveResult{ .gpa = gpa, .total = json_util.getInt(parsed.value, "total"), .audit_id = null, .goods_id = null, .goods = &[_]Goods{} };
        errdefer out.deinit();
        if (json_util.getArray(parsed.value, "goods")) |arr| {
            const items = gpa.alloc(Goods, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*g| g.deinit();
                gpa.free(items);
            }
            for (arr.items) |item| {
                var g = Goods{
                    .gpa = gpa,
                    .goods_id = json_util.getInt(item, "goodsId") orelse json_util.getInt(item, "goods_id"),
                    .cover_img_url = null,
                    .cover_img = null,
                    .name = null,
                    .url = null,
                    .price_type = json_util.getInt(item, "priceType") orelse json_util.getInt(item, "price_type"),
                    .audit_status = json_util.getInt(item, "audit_status") orelse status,
                    .price = null,
                    .price2 = null,
                    .third_party_tag = null,
                    .third_party_appid = null,
                };
                if (json_util.getStr(item, "coverImgUrl")) |s| g.cover_img_url = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "name")) |s| g.name = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "url")) |s| g.url = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "thirdPartyTag")) |s| g.third_party_tag = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                g.price = getFloat(item, "price");
                g.price2 = getFloat(item, "price2");
                items[filled] = g;
                filled += 1;
            }
            out.goods = items;
        }
        return .{ .ok = out };
    }

    /// 对应 `setKey(goodsKey)`:POST setkey {"goodsKey":[...]} → Done。
    pub fn setKey(self: *LiveGoodsService, io: std.Io, goods_key: []const []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"goodsKey\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (goods_key, 0..) |k, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, k) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, SET_KEY_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getKey()`:GET getkey → vendorGoodsKey[](gpa 拥有;
    /// 缺失时返回空切片,Java 返回 null)。
    pub fn getKey(self: *LiveGoodsService, io: std.Io) WxResult([][]const u8) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_KEY_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live getkey not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "vendorGoodsKey") orelse
            return .{ .ok = &[_][]const u8{} };
        const items = gpa.alloc([]const u8, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |s| gpa.free(@constCast(s));
            gpa.free(items);
        }
        for (arr.items) |item| {
            if (item != .string) continue;
            items[filled] = gpa.dupe(u8, item.string) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        return .{ .ok = items };
    }
};

// --- 解析辅助 ------------------------------------------------------------------

// 内部:解析 LiveResult(total/audit_id/goods_id/goods[],goods 元素为下划线 key)。
fn parseLiveResult(gpa: std.mem.Allocator, resp: []const u8) WxResult(LiveResult) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "live result not json", .{}) };
    defer parsed.deinit();
    var out = LiveResult{
        .gpa = gpa,
        .total = json_util.getInt(parsed.value, "total"),
        .audit_id = json_util.getInt(parsed.value, "audit_id"),
        .goods_id = json_util.getInt(parsed.value, "goods_id"),
        .goods = &[_]Goods{},
    };
    errdefer out.deinit();
    if (json_util.getArray(parsed.value, "goods")) |arr| {
        const items = gpa.alloc(Goods, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |*g| g.deinit();
            gpa.free(items);
        }
        for (arr.items) |item| {
            items[filled] = parseGoods(gpa, item) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        out.goods = items;
    }
    return .{ .ok = out };
}

// 内部:解析单个 Goods(下划线 key 变体)。pub 供 live.zig 复用
// (Java WxMaLiveResult.Goods 同一 bean 也用于 RoomInfo.goods)。
pub fn parseGoods(gpa: std.mem.Allocator, item: std.json.Value) !Goods {
    var g = Goods{
        .gpa = gpa,
        .goods_id = json_util.getInt(item, "goods_id"),
        .cover_img_url = null,
        .cover_img = null,
        .name = null,
        .url = null,
        .price_type = json_util.getInt(item, "price_type"),
        .audit_status = json_util.getInt(item, "audit_status"),
        .price = null,
        .price2 = null,
        .third_party_tag = null,
        .third_party_appid = null,
    };
    errdefer g.deinit();
    if (json_util.getStr(item, "cover_img_url")) |s| g.cover_img_url = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "cover_img")) |s| g.cover_img = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "name")) |s| g.name = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "url")) |s| g.url = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "third_party_tag")) |s| g.third_party_tag = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "thirdPartyAppid")) |s| g.third_party_appid = try gpa.dupe(u8, s);
    g.price = getFloat(item, "price");
    g.price2 = getFloat(item, "price2");
    return g;
}

// 内部:数值字段(BigDecimal → f64;integer/float 均可)。
fn getFloat(v: std.json.Value, key: []const u8) ?f64 {
    const o = json_util.object(v) orelse return null;
    const c = o.get(key) orelse return null;
    return switch (c) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "live goods add/resetAudit/audit/delete/update" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "broadcast/goods/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"audit_id\":123,\"goods_id\":456}" },
        .{ .match = "broadcast/goods/resetaudit", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "broadcast/goods/audit", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"auditId\":789}" },
        .{ .match = "broadcast/goods/delete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "broadcast/goods/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveGoodsService{ .svc = &base };

    // addGoods:{"goodsInfo":预构建体}
    const goods_info = "{\"goodsId\":1,\"coverImgUrl\":\"https://img\",\"priceType\":1,\"price\":9.9,\"price2\":19.9,\"name\":\"商品A\",\"url\":\"pages/a\"}";
    const added = switch (s.addGoods(io, goods_info)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = added;
        r.deinit();
    }
    try std.testing.expectEqualStrings("{\"goodsInfo\":" ++ goods_info ++ "}", m.last_body);
    try std.testing.expectEqual(@as(i64, 1), added.total.?);
    try std.testing.expectEqual(@as(i64, 123), added.audit_id.?);
    try std.testing.expectEqual(@as(i64, 456), added.goods_id.?);

    // resetAudit:驼峰 key
    try std.testing.expect(!s.resetAudit(io, 123, 456).failed());
    try std.testing.expectEqualStrings("{\"auditId\":123,\"goodsId\":456}", m.last_body);

    // auditGoods:auditId
    const audit = switch (s.auditGoods(io, 456)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 789), audit);
    try std.testing.expectEqualStrings("{\"goodsId\":456}", m.last_body);

    // deleteGoods
    try std.testing.expect(!s.deleteGoods(io, 456).failed());
    try std.testing.expectEqualStrings("{\"goodsId\":456}", m.last_body);

    // updateGoods
    try std.testing.expect(!s.updateGoods(io, goods_info).failed());
    try std.testing.expectEqualStrings("{\"goodsInfo\":" ++ goods_info ++ "}", m.last_body);
}

test "live goods warehouse/approved/key" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getgoodswarehouse", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":2,\"goods\":[{\"goods_id\":1,\"cover_img_url\":\"https://img1\",\"name\":\"商品1\",\"url\":\"pages/1\",\"price_type\":1,\"audit_status\":2,\"price\":9.9,\"price2\":19.9,\"third_party_tag\":\"1\"},{\"goods_id\":2,\"cover_img_url\":\"https://img2\",\"name\":\"商品2\",\"price\":5.5}]}" },
        .{ .match = "goods/getapproved", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"goods\":[{\"goodsId\":9,\"coverImgUrl\":\"https://img9\",\"priceType\":1,\"thirdPartyTag\":\"1\",\"name\":\"商品9\",\"url\":\"pages/9\",\"price\":8.8}]}" },
        .{ .match = "goods/setkey", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/getkey", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"vendorGoodsKey\":[\"k1\",\"k2\"]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveGoodsService{ .svc = &base };

    // getGoodsWareHouse:{goods_ids:[...]} → goods[](下划线 key)
    const wh = switch (s.getGoodsWareHouse(io, &.{ 1, 2 })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = wh;
        r.deinit();
    }
    try std.testing.expectEqualStrings("{\"goods_ids\":[1,2]}", m.last_body);
    try std.testing.expectEqual(@as(i64, 2), wh.total.?);
    try std.testing.expectEqual(@as(usize, 2), wh.goods.len);
    try std.testing.expectEqual(@as(i64, 1), wh.goods[0].goods_id.?);
    try std.testing.expectEqualStrings("商品1", wh.goods[0].name.?);
    try std.testing.expectEqual(@as(f64, 9.9), wh.goods[0].price.?);
    try std.testing.expectEqual(@as(f64, 19.9), wh.goods[0].price2.?);
    try std.testing.expectEqual(@as(i64, 2), wh.goods[0].audit_status.?);
    try std.testing.expectEqual(@as(i64, 2), wh.goods[1].goods_id.?);
    try std.testing.expect(wh.goods[1].audit_status == null);

    // getApprovedGoods:驼峰 key 归一化 + audit_status 回填
    const ap = switch (s.getApprovedGoods(io, 0, 10, 2)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = ap;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "goods/getapproved?status=2&offset=0&limit=10") != null);
    try std.testing.expectEqual(@as(usize, 1), ap.goods.len);
    const g9 = ap.goods[0];
    try std.testing.expectEqual(@as(i64, 9), g9.goods_id.?);
    try std.testing.expectEqualStrings("https://img9", g9.cover_img_url.?);
    try std.testing.expectEqual(@as(i64, 1), g9.price_type.?);
    try std.testing.expectEqual(@as(i64, 2), g9.audit_status.?);
    try std.testing.expectEqual(@as(f64, 8.8), g9.price.?);

    // setKey:{"goodsKey":[...]}
    try std.testing.expect(!s.setKey(io, &.{ "k1", "k2" }).failed());
    try std.testing.expectEqualStrings("{\"goodsKey\":[\"k1\",\"k2\"]}", m.last_body);

    // getKey:vendorGoodsKey[]
    const keys = switch (s.getKey(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        for (keys) |k| gpa.free(@constCast(k));
        gpa.free(keys);
    }
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("k1", keys[0]);
    try std.testing.expectEqualStrings("k2", keys[1]);
}
