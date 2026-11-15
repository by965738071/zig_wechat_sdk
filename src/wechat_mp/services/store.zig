//! 微信门店(POI)服务 —— 逐字对齐 Java `api.WxMpStoreService` +
//! `api.impl.WxMpStoreServiceImpl`,端点常量取自 `api_url.zig:Store`
//! (镜像 Java `enums.WxMpApiUrl.Store`,6 个常量)。
//!
//! Java 接口 7 个方法(名称逐字对齐,impl:37-125):
//!   add(StoreSpec)        POST cgi-bin/poi/addpoi      {"business":{"base_info":{...}}}
//!   get(poiId)            POST cgi-bin/poi/getpoi      {"poi_id"} → business.base_info
//!   delete(poiId)         POST cgi-bin/poi/delpoi       {"poi_id"}
//!   list(begin,limit)     POST cgi-bin/poi/getpoilist   {"begin","limit"}
//!                         → {total_count,business_list:[{business:{base_info}}]}
//!   listAll()            循环翻页(list,每页 50,直到取完 total_count)
//!   update(StoreSpec)     POST cgi-bin/poi/updatepoi   {"business":{"base_info":{...,"poi_id"}}}
//!   listCategories()     GET  cgi-bin/poi/getwxcategory → category_list:[...]
//!
//! Java↔Zig 差异:
//!   - `WxMpStoreBaseInfo` bean(20+ 字段)→ `StoreSpec` 借用切片,收录核心字段
//!     (sid/business_name/branch_name/province/city/district/address/telephone/
//!     categories/longitude/latitude/photo_list/recommend/special/introduction/
//!     open_time/avg_price/poi_id),photo_list 为 photo_url 数组;未收录字段
//!     (offset_type 固定 1、available_state/update_status 只读)不编造;
//!   - `add` 前的 `BeanUtils.checkRequiredFields` → 简化为非空校验
//!     business_name/branch_name/province/city/address/telephone;
//!   - `get` 返回的 base_info 只解析核心字段(名称/地址/电话/poi_id);
//!   - `List<String>` category_list → `[][]u8`。
//!
//! 内存所有权:请求侧全部借用;响应结果 gpa 拥有,用毕 `deinit()`。
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

/// 门店照片 —— 对应 `WxMpStoreBaseInfo.WxMpStorePhoto`{@SerializedName("photo_url")}。
pub const StorePhoto = struct { photo_url: []const u8 };

/// 门店基础信息规格 —— 对应 `WxMpStoreBaseInfo`(请求侧,切片全借用)。
pub const StoreSpec = struct {
    sid: ?[]const u8 = null,
    business_name: []const u8,
    branch_name: []const u8,
    province: []const u8,
    city: []const u8,
    district: ?[]const u8 = null,
    address: []const u8,
    telephone: []const u8,
    categories: []const []const u8,
    longitude: f64,
    latitude: f64,
    photo_list: []const StorePhoto = &.{},
    recommend: ?[]const u8 = null,
    special: ?[]const u8 = null,
    introduction: ?[]const u8 = null,
    open_time: ?[]const u8 = null,
    avg_price: ?i64 = null,
    /// update 用(对应 bean 的 poi_id 字段)。
    poi_id: ?[]const u8 = null,
};

/// 门店 base_info 序列化为 std.json.Value(字段缺省则不输出)。
/// 容器树(嵌套 ObjectMap/ArrayList)一次性组包进 arena,序列化后整体释放
/// (照 guide.zig 的 arena 模式);字符串全部借用自 StoreSpec。
fn baseInfoValue(a: std.mem.Allocator, s: StoreSpec) !json_util.Value {
    var m: json_util.ObjectMap = .empty;
    try m.put(a, "business_name", .{ .string = s.business_name });
    try m.put(a, "branch_name", .{ .string = s.branch_name });
    try m.put(a, "province", .{ .string = s.province });
    try m.put(a, "city", .{ .string = s.city });
    if (s.district) |v| try m.put(a, "district", .{ .string = v });
    try m.put(a, "address", .{ .string = s.address });
    try m.put(a, "telephone", .{ .string = s.telephone });
    var cats: std.ArrayList(json_util.Value) = .empty;
    for (s.categories) |c| try cats.append(a, .{ .string = c });
    try m.put(a, "categories", .{ .array = cats });
    // offset_type 固定 1(Java bean @Builder.Default offsetType = 1)
    try m.put(a, "offset_type", .{ .integer = 1 });
    try m.put(a, "longitude", .{ .float = s.longitude });
    try m.put(a, "latitude", .{ .float = s.latitude });
    if (s.photo_list.len > 0) {
        var photos: std.ArrayList(json_util.Value) = .empty;
        for (s.photo_list) |p| {
            var pm: json_util.ObjectMap = .empty;
            try pm.put(a, "photo_url", .{ .string = p.photo_url });
            try photos.append(a, .{ .object = pm });
        }
        try m.put(a, "photo_list", .{ .array = photos });
    }
    if (s.recommend) |v| try m.put(a, "recommend", .{ .string = v });
    if (s.special) |v| try m.put(a, "special", .{ .string = v });
    if (s.introduction) |v| try m.put(a, "introduction", .{ .string = v });
    if (s.open_time) |v| try m.put(a, "open_time", .{ .string = v });
    if (s.avg_price) |v| try m.put(a, "avg_price", .{ .integer = v });
    if (s.poi_id) |v| try m.put(a, "poi_id", .{ .string = v });
    return .{ .object = m };
}

/// {"business":{"base_info":{...}}} —— 对应 `WxMpStoreBaseInfo.toJson()`。
/// 输出串由 gpa 拥有(调用方 free);中间容器进 arena,函数返回即释放。
fn storeSpecBody(gpa: std.mem.Allocator, s: StoreSpec) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try baseInfoValue(a, s);
    var base_wrap: json_util.ObjectMap = .empty;
    try base_wrap.put(a, "base_info", base);
    var biz: json_util.ObjectMap = .empty;
    try biz.put(a, "business", .{ .object = base_wrap });
    return json_util.stringify(gpa, json_util.Value{ .object = biz });
}

/// 门店信息(响应侧核心字段)—— 对应 `business.base_info` 的核心 @SerializedName。
pub const Store = struct {
    gpa: std.mem.Allocator,
    poi_id: []u8,
    business_name: []u8,
    branch_name: []u8,
    address: []u8,
    telephone: []u8,

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.poi_id);
        self.gpa.free(self.business_name);
        self.gpa.free(self.branch_name);
        self.gpa.free(self.address);
        self.gpa.free(self.telephone);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !Store {
        var s = Store{
            .gpa = gpa,
            .poi_id = try gpa.dupe(u8, json_util.getStrOr(v, "poi_id", "")),
            .business_name = try gpa.dupe(u8, json_util.getStrOr(v, "business_name", "")),
            .branch_name = try gpa.dupe(u8, json_util.getStrOr(v, "branch_name", "")),
            .address = try gpa.dupe(u8, json_util.getStrOr(v, "address", "")),
            .telephone = try gpa.dupe(u8, json_util.getStrOr(v, "telephone", "")),
        };
        errdefer s.deinit();
        return s;
    }
};

/// 门店列表页 —— 对应 `WxMpStoreListResult`{total_count,business_list}。
pub const StoreList = struct {
    gpa: std.mem.Allocator,
    total_count: i64 = 0,
    stores: []Store = &.{},

    pub fn deinit(self: *StoreList) void {
        for (self.stores) |*s| s.deinit();
        if (self.stores.len > 0) self.gpa.free(self.stores);
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !StoreList {
        var r = StoreList{ .gpa = gpa };
        errdefer r.deinit();
        r.total_count = json_util.getIntOr(v, "total_count", 0);
        var list: std.ArrayList(Store) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getArray(v, "business_list")) |arr| {
            for (arr.items) |item| {
                // business_list[i].business.base_info
                const biz = json_util.getObject(item, "business") orelse continue;
                const base = json_util.getObject(biz, "base_info") orelse continue;
                try list.append(gpa, try Store.fromJson(gpa, base));
            }
        }
        r.stores = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// 非空校验 —— 对应 `BeanUtils.checkRequiredFields`(impl:40)。
fn checkRequired(gpa: std.mem.Allocator, s: StoreSpec) ?WxError {
    if (s.business_name.len == 0 or s.branch_name.len == 0 or s.province.len == 0 or
        s.city.len == 0 or s.address.len == 0 or s.telephone.len == 0)
    {
        return WxError.configError(gpa, "门店必填字段缺失(business_name/branch_name/province/city/address/telephone)", .{});
    }
    return null;
}

pub const StoreService = struct {
    svc: *service_mod.Service,

    /// 对应 `#add`(impl:37-46):POST addpoi + checkRequiredFields。
    pub fn add(self: *StoreService, io: std.Io, s: StoreSpec) Done {
        const gpa = self.svc.gpa;
        if (checkRequired(gpa, s)) |e| return .{ .err = e };
        const body = storeSpecBody(gpa, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Store.poi_add_url, body);
    }

    /// 对应 `#get`(impl:48-61):POST getpoi {"poi_id"} → business.base_info。
    pub fn get(self: *StoreService, io: std.Io, poi_id: []const u8) WxResult(Store) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("poi_id", poi_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Store.poi_get_url, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getpoi response not json", .{}) };
        defer parsed.deinit();
        const biz = json_util.getObject(parsed.value, "business") orelse
            return .{ .err = WxError.transport(gpa, "getpoi response missing business", .{}) };
        const base = json_util.getObject(biz, "base_info") orelse
            return .{ .err = WxError.transport(gpa, "getpoi response missing base_info", .{}) };
        const store = Store.fromJson(gpa, base) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = store };
    }

    /// 对应 `#delete`(impl:63-71):POST delpoi {"poi_id"}。
    pub fn delete(self: *StoreService, io: std.Io, poi_id: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("poi_id", poi_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Store.poi_del_url, body);
    }

    /// 对应 `#list`(impl:73-88):POST getpoilist {"begin","limit"}。
    pub fn list(self: *StoreService, io: std.Io, begin: i64, limit: i64) WxResult(StoreList) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("begin", begin) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("limit", limit) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Store.poi_list_url, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getpoilist response not json", .{}) };
        defer parsed.deinit();
        const r = StoreList.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "getpoilist parse failed", .{}) };
        return .{ .ok = r };
    }

    /// 对应 `#listAll`(impl:90-108):每页 50,翻页直到取完 total_count。
    pub fn listAll(self: *StoreService, io: std.Io) WxResult([]Store) {
        const gpa = self.svc.gpa;
        const limit: i64 = 50;
        const first = switch (self.list(io, 0, limit)) {
            .ok => |l| l,
            .err => |e| return .{ .err = e },
        };
        var acc: std.ArrayList(Store) = .empty;
        errdefer {
            for (acc.items) |*it| it.deinit();
            acc.deinit(gpa);
        }
        const total = first.total_count;
        for (first.stores) |st| acc.append(gpa, st) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        // 首页切片由 first 拥有但元素所有权已转移给 acc;只释放切片本身
        if (first.stores.len > 0) gpa.free(first.stores);
        if (total > limit) {
            var begin: i64 = limit;
            while (true) {
                var page = switch (self.list(io, begin, limit)) {
                    .ok => |l| l,
                    .err => |e| {
                        for (acc.items) |*it| it.deinit();
                        acc.deinit(gpa);
                        return .{ .err = e };
                    },
                };
                if (page.stores.len == 0) {
                    page.deinit();
                    break;
                }
                for (page.stores) |st| acc.append(gpa, st) catch {
                    page.deinit();
                    for (acc.items) |*it| it.deinit();
                    acc.deinit(gpa);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                if (page.stores.len > 0) gpa.free(page.stores);
                begin += limit;
                if (begin >= total) break;
            }
        }
        return .{ .ok = acc.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `#update`(impl:110-118):POST updatepoi(请求体同 addpoi,
    /// bean 的 poi_id 字段带上)。
    pub fn update(self: *StoreService, io: std.Io, s: StoreSpec) Done {
        const gpa = self.svc.gpa;
        if (s.poi_id == null or s.poi_id.?.len == 0)
            return .{ .err = WxError.configError(gpa, "更新门店必须提供 poi_id", .{}) };
        if (checkRequired(gpa, s)) |e| return .{ .err = e };
        const body = storeSpecBody(gpa, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Store.poi_update_url, body);
    }

    /// 对应 `#listCategories`(impl:120-125):GET getwxcategory → category_list。
    pub fn listCategories(self: *StoreService, io: std.Io) WxResult([][]u8) {
        const gpa = self.svc.gpa;
        const resp = switch (h.apiGet(self.svc, io, api_url.Store.poi_get_wx_category_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getwxcategory response not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "category_list") orelse
            return .{ .err = WxError.transport(gpa, "getwxcategory response missing category_list", .{}) };
        var cats: std.ArrayList([]u8) = .empty;
        errdefer {
            for (cats.items) |s| gpa.free(s);
            cats.deinit(gpa);
        }
        for (arr.items) |v| switch (v) {
            .string => |s| cats.append(gpa, gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            else => {},
        };
        return .{ .ok = cats.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:6 端点 URL/method/请求体 + business/base_info 解析 + listAll 翻页
// (逐字对照 WxMpApiUrl.Store + WxMpStoreServiceImpl + WxMpStoreListResult)
// ---------------------------------------------------------------------------

fn freeStores(gpa: std.mem.Allocator, stores: []Store) void {
    for (stores) |*s| s.deinit();
    if (stores.len > 0) gpa.free(stores);
}

test "Store 契约: add/get/delete/list/update/listCategories (WxMpApiUrl.Store)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/poi/addpoi", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "cgi-bin/poi/getpoilist", .response = "{\"errcode\":0,\"total_count\":1,\"business_list\":[{\"business\":{\"base_info\":{\"poi_id\":\"P1\",\"business_name\":\"国美\",\"branch_name\":\"王府井店\",\"address\":\"王府井大街1号\",\"telephone\":\"010-12345678\"}}}]}" },
        .{ .match = "cgi-bin/poi/delpoi", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/poi/getpoi", .response = "{\"errcode\":0,\"business\":{\"base_info\":{\"poi_id\":\"P1\",\"business_name\":\"国美\",\"branch_name\":\"王府井店\",\"address\":\"王府井大街1号\",\"telephone\":\"010-12345678\"}}}" },
        .{ .match = "cgi-bin/poi/updatepoi", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/poi/getwxcategory", .response = "{\"errcode\":0,\"category_list\":[\"美食,川菜,火锅\",\"美食,江浙菜\"]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = StoreService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    const spec = StoreSpec{
        .business_name = "国美",
        .branch_name = "王府井店",
        .province = "北京市",
        .city = "北京市",
        .district = "东城区",
        .address = "王府井大街1号",
        .telephone = "010-12345678",
        .categories = &.{ "美食", "川菜" },
        .longitude = 116.4108,
        .latitude = 39.9109,
        .photo_list = &.{.{ .photo_url = "https://mmbiz.qpic.cn/1.jpg" }},
        .open_time = "8:00-20:00",
        .avg_price = 50,
    };

    // add: {"business":{"base_info":{...}}}(嵌套结构逐字对照 toJson)
    switch (svc.add(io, spec)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreAdd;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/addpoi") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"business\":{\"base_info\":") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"business_name\":\"国美\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"photo_list\":[{\"photo_url\":") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"offset_type\":1") != null);

    // add: 必填字段缺失 → configError(对应 checkRequiredFields)
    switch (svc.add(io, .{ .business_name = "", .branch_name = "", .province = "", .city = "", .address = "", .telephone = "", .categories = &.{}, .longitude = 0, .latitude = 0 })) {
        .ok => return error.StoreAddShouldFail,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }

    // get: {"poi_id"} → business.base_info
    switch (svc.get(io, "P1")) {
        .ok => |*r| {
            var st = r.*;
            defer st.deinit();
            try testing.expectEqualStrings("P1", st.poi_id);
            try testing.expectEqualStrings("国美", st.business_name);
            try testing.expectEqualStrings("王府井大街1号", st.address);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/getpoi") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"poi_id\":\"P1\"") != null);

    // delete
    switch (svc.delete(io, "P1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreDelete;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/delpoi") != null);

    // list: {"begin","limit"} → total_count + business_list[].business.base_info
    switch (svc.list(io, 0, 20)) {
        .ok => |*r| {
            var l = r.*;
            defer l.deinit();
            try testing.expectEqual(@as(i64, 1), l.total_count);
            try testing.expectEqual(@as(usize, 1), l.stores.len);
            try testing.expectEqualStrings("国美", l.stores[0].business_name);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/getpoilist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"begin\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"limit\":20") != null);

    // update: 请求体带 poi_id;缺 poi_id → configError
    switch (svc.update(io, .{ .poi_id = "P1", .business_name = "国美", .branch_name = "王府井店", .province = "北京市", .city = "北京市", .address = "王府井大街1号", .telephone = "010-12345678", .categories = &.{}, .longitude = 116.4108, .latitude = 39.9109 })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreUpdate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/updatepoi") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"poi_id\":\"P1\"") != null);
    switch (svc.update(io, spec)) {
        .ok => return error.StoreUpdateShouldFail,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
        },
    }

    // listCategories: GET → category_list[]
    switch (svc.listCategories(io)) {
        .ok => |cats| {
            defer {
                for (cats) |c| gpa.free(c);
                gpa.free(cats);
            }
            try testing.expectEqual(@as(usize, 2), cats.len);
            try testing.expectEqualStrings("美食,川菜,火锅", cats[0]);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreCategories;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/poi/getwxcategory") != null);
}

test "Store listAll: 翻页跨页累加(每页 50,直到 begin >= total)" {
    const gpa = testing.allocator;
    // page1(begin=0): 50 家 + total 51;page2(begin=50): 1 家
    var page1 = std.ArrayList(u8).empty;
    defer page1.deinit(gpa);
    try page1.appendSlice(gpa, "{\"errcode\":0,\"total_count\":51,\"business_list\":[");
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (i != 0) try page1.append(gpa, ',');
        try page1.appendSlice(gpa, "{\"business\":{\"base_info\":{\"poi_id\":\"P\",\"business_name\":\"国美\",\"branch_name\":\"店\",\"address\":\"a\",\"telephone\":\"t\"}}}");
    }
    try page1.appendSlice(gpa, "]}");
    var page2 = std.ArrayList(u8).empty;
    defer page2.deinit(gpa);
    try page2.appendSlice(gpa, "{\"errcode\":0,\"total_count\":51,\"business_list\":[{\"business\":{\"base_info\":{\"poi_id\":\"P50\",\"business_name\":\"国美\",\"branch_name\":\"店\",\"address\":\"a\",\"telephone\":\"t\"}}}]}");

    var mock = h.Recorder{
        .gpa = gpa,
        .entries = &.{
            // 同一 URI 两页:靠 body_match 区分翻页请求体(begin 在 body 里)
            .{ .match = "cgi-bin/poi/getpoilist", .body_match = "\"begin\":0", .response = page1.items },
            .{ .match = "cgi-bin/poi/getpoilist", .body_match = "\"begin\":50", .response = page2.items },
        },
    };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = StoreService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    switch (svc.listAll(io)) {
        .ok => |stores| {
            defer freeStores(gpa, stores);
            try testing.expectEqual(@as(usize, 51), stores.len);
            try testing.expectEqualStrings("P50", stores[50].poi_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedStoreListAll;
        },
    }
    try testing.expectEqual(@as(usize, 2), mock.calls);
}
