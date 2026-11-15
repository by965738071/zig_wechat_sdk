//! 摇一摇周边服务 —— 逐字对齐 Java `api.WxMpShakeService` +
//! `api.impl.WxMpShakeServiceImpl`,端点常量取自 `api_url.zig:ShakeAround`
//! (镜像 Java `enums.WxMpApiUrl.ShakeAround`,4 个常量)。
//!
//! Java 接口 4 个方法(名称逐字对齐,impl:26-54):
//!   getShakeInfo(ticket,needPoi)    POST shakearound/user/getshakeinfo
//!                                  {"ticket","need_poi"} → data{page_id,openid,poi_id}
//!   pageAdd(...)                    POST shakearound/page/add
//!                                  {"title","description","page_url","comment","icon_url"}
//!                                  → data{page_id}
//!   deviceBindPageQuery(...)        POST shakearound/device/bindpage
//!                                  {"device_identifier":{...},"page_ids":[...]}
//!   relationSearch(...)             POST shakearound/relation/search
//!                                  type=1 {"type","device_identifier"} /
//!                                  type=2 {"type","page_id","begin","count"}
//!
//! Java↔Zig 差异:
//!   - `WxMpShakeInfoResult.data` 只解析核心字段(page_id/openid/poi_id),
//!     beacon_info 不编造;
//!   - `deviceBindPageQuery` 返回 `WxError`(Java)→ `Done`(errcode!=0 已折叠为 .err);
//!   - `relationSearch` 的 `WxMpShakeAroundRelationSearchResult.data` 只解析
//!     total_count(核心分页字段);
//!   - `WxMpShakeAroundPageAddResult.data` 只解析 page_id。
//!
//! 内存所有权:结果 gpa 拥有,用毕 `deinit()`;`.err` 载荷 `WxError.deinit()`。
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

/// 设备标识 —— 对应 `WxMpDeviceIdentifier.toJsonObject()`。
pub const DeviceIdentifier = struct {
    device_id: i64,
    uuid: []const u8,
    major: i64,
    minor: i64,
};

/// 摇一摇周边页面信息 —— 对应 `WxMpShakeAroundPageAddResult.data`(page_id)。
pub const PageAddResult = struct {
    gpa: std.mem.Allocator,
    page_id: i64 = 0,

    pub fn deinit(self: *PageAddResult) void {
        _ = self;
    }
};

/// 摇一摇用户信息 —— 对应 `WxMpShakeInfoResult.data` 核心字段。
pub const ShakeInfo = struct {
    gpa: std.mem.Allocator,
    page_id: []u8,
    openid: []u8,
    poi_id: []u8,

    pub fn deinit(self: *ShakeInfo) void {
        self.gpa.free(self.page_id);
        self.gpa.free(self.openid);
        self.gpa.free(self.poi_id);
        self.* = undefined;
    }
};

/// 设备与页面关系查询结果 —— 对应 `WxMpShakeAroundRelationSearchResult.data.total_count`。
pub const RelationSearchResult = struct {
    gpa: std.mem.Allocator,
    total_count: i64 = 0,

    pub fn deinit(self: *RelationSearchResult) void {
        _ = self;
    }
};

/// {"device_identifier":{...}} 的内嵌对象。
fn identifierValue(gpa: std.mem.Allocator, d: DeviceIdentifier) !json_util.Value {
    var m: json_util.ObjectMap = .empty;
    try m.put(gpa, "device_id", .{ .integer = d.device_id });
    try m.put(gpa, "uuid", .{ .string = d.uuid });
    try m.put(gpa, "major", .{ .integer = d.major });
    try m.put(gpa, "minor", .{ .integer = d.minor });
    return .{ .object = m };
}

pub const ShakeService = struct {
    svc: *service_mod.Service,

    /// 对应 `#getShakeInfo`(impl:26-31):POST {"ticket","need_poi"} → data 剥壳。
    pub fn getShakeInfo(self: *ShakeService, io: std.Io, ticket: []const u8, need_poi: bool) WxResult(ShakeInfo) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("ticket", ticket) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putInt("need_poi", if (need_poi) 1 else 0) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.ShakeAround.shakearound_user_getshakeinfo, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getshakeinfo response not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "getshakeinfo response missing data", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .page_id = gpa.dupe(u8, json_util.getStrOr(data, "page_id", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            .openid = gpa.dupe(u8, json_util.getStrOr(data, "openid", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            .poi_id = gpa.dupe(u8, json_util.getStrOr(data, "poi_id", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
        } };
    }

    /// 对应 `#pageAdd`(impl:33-38):POST 5 字段 → data.page_id。
    pub fn pageAdd(self: *ShakeService, io: std.Io, title: []const u8, description: []const u8, page_url: []const u8, comment: []const u8, icon_url: []const u8) WxResult(PageAddResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("title", title) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("description", description) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("page_url", page_url) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("comment", comment) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("icon_url", icon_url) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.ShakeAround.shakearound_page_add, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "page/add response not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "page/add response missing data", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .page_id = json_util.getIntOr(data, "page_id", 0),
        } };
    }

    /// 对应 `#deviceBindPageQuery`(impl:40-45):
    /// POST {"device_identifier":{...},"page_ids":[...]}。
    /// Java 返回 `WxError` → `Done`(errcode!=0 已在 Service 折叠为 .err)。
    pub fn deviceBindPageQuery(self: *ShakeService, io: std.Io, identifier: DeviceIdentifier, page_ids: []const i64) Done {
        const gpa = self.svc.gpa;
        // 容器树(数组/内嵌对象)一次性组包进 arena,序列化后整体释放(照 guide.zig)。
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var ids: std.ArrayList(json_util.Value) = .empty;
        for (page_ids) |id| ids.append(a, .{ .integer = id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const ident = identifierValue(a, identifier) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var m: json_util.ObjectMap = .empty;
        m.put(a, "device_identifier", ident) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "page_ids", .{ .array = ids }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = json_util.stringify(gpa, json_util.Value{ .object = m }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.ShakeAround.shakearound_device_bindpage, body);
    }

    /// 对应 `#relationSearch`(impl:47-54):
    /// type=1 按设备查关联页面,type=2 按页面查关联设备(Java switch 语义)。
    pub fn relationSearchByDevice(self: *ShakeService, io: std.Io, identifier: DeviceIdentifier) WxResult(RelationSearchResult) {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ident = identifierValue(a, identifier) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var m: json_util.ObjectMap = .empty;
        m.put(a, "type", .{ .integer = 1 }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "device_identifier", ident) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.relationSearchPost(io, .{ .object = m });
    }

    /// 对应 `#relationSearch` type=2 分支:{"type":2,"page_id","begin","count"}。
    pub fn relationSearchByPage(self: *ShakeService, io: std.Io, page_id: i64, begin: i64, count: i64) WxResult(RelationSearchResult) {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var m: json_util.ObjectMap = .empty;
        m.put(a, "type", .{ .integer = 2 }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "page_id", .{ .integer = page_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "begin", .{ .integer = begin }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "count", .{ .integer = count }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return self.relationSearchPost(io, .{ .object = m });
    }

    fn relationSearchPost(self: *ShakeService, io: std.Io, v: json_util.Value) WxResult(RelationSearchResult) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.ShakeAround.shakearound_relation_search, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "relation/search response not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "relation/search response missing data", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .total_count = json_util.getIntOr(data, "total_count", 0),
        } };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:4 端点 URL/method/请求体 + data 剥壳解析
// (逐字对照 WxMpApiUrl.ShakeAround + WxMpShakeServiceImpl)
// ---------------------------------------------------------------------------

test "Shake 契约: 4 端点 URL/method/请求体 (WxMpApiUrl.ShakeAround)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "shakearound/user/getshakeinfo", .response = "{\"errcode\":0,\"data\":{\"page_id\":\"123\",\"openid\":\"oX\",\"poi_id\":\"POI1\",\"beacon_info\":{\"distance\":0.5}}}" },
        .{ .match = "shakearound/page/add", .response = "{\"errcode\":0,\"data\":{\"page_id\":321}}" },
        .{ .match = "shakearound/device/bindpage", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "shakearound/relation/search", .response = "{\"errcode\":0,\"data\":{\"total_count\":7}}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = ShakeService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // getShakeInfo: {"ticket","need_poi"} → data{page_id,openid,poi_id}
    switch (svc.getShakeInfo(io, "TICKET", true)) {
        .ok => |*r| {
            var i = r.*;
            defer i.deinit();
            try testing.expectEqualStrings("123", i.page_id);
            try testing.expectEqualStrings("oX", i.openid);
            try testing.expectEqualStrings("POI1", i.poi_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedShakeInfo;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "shakearound/user/getshakeinfo") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"ticket\":\"TICKET\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"need_poi\":1") != null);

    // pageAdd: 5 字段 → data.page_id
    switch (svc.pageAdd(io, "主标题", "副标题", "https://example.com", "备注", "https://img.example.com/icon")) {
        .ok => |*r| {
            try testing.expectEqual(@as(i64, 321), r.page_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedShakePageAdd;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "shakearound/page/add") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page_url\":\"https://example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"icon_url\":\"https://img.example.com/icon\"") != null);

    // deviceBindPageQuery: {"device_identifier":{device_id,uuid,major,minor},"page_ids":[...]}
    switch (svc.deviceBindPageQuery(io, .{ .device_id = 1, .uuid = "UUID1", .major = 100, .minor = 200 }, &.{ 1, 2 })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedShakeBindPage;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "shakearound/device/bindpage") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"device_identifier\":{\"device_id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page_ids\":[1,2]") != null);

    // relationSearch type=1 / type=2(Java switch 语义)
    switch (svc.relationSearchByDevice(io, .{ .device_id = 1, .uuid = "UUID1", .major = 100, .minor = 200 })) {
        .ok => |*r| try testing.expectEqual(@as(i64, 7), r.total_count),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedShakeRelationSearch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"device_identifier\"") != null);

    switch (svc.relationSearchByPage(io, 321, 0, 10)) {
        .ok => |*r| try testing.expectEqual(@as(i64, 7), r.total_count),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedShakeRelationSearch2;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":2") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page_id\":321") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"begin\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"count\":10") != null);
    try testing.expectEqual(@as(usize, 5), mock.calls);
}
