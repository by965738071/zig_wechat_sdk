//! 微信营销数据服务 —— 逐字对齐 Java `api.WxMpMarketingService` +
//! `api.impl.WxMpMarketingServiceImpl`,端点常量取自 `api_url.zig:Marketing`
//! (镜像 Java `enums.WxMpApiUrl.Marketing`,4 个常量)。
//!
//! Java 接口 4 个方法(名称逐字对齐,impl:22-66):
//!   addUserActionSets(type,name,desc)
//!                       POST marketing/user_action_sets/add?version=v1.0
//!                       {"type","name","description"} → data.user_action_set_id
//!   getUserActionSets(id) GET marketing/user_action_sets/get
//!                       ?version=v1.0&user_action_set_id=<id> → data.list[]
//!   addUserAction(actions) POST marketing/user_actions/add?version=v1.0
//!                       {"actions":[{user_action_set_id,url,action_time,action_type,
//!                                    (trace:{click_id})?,(action_param:{value,leads_type})?}]}
//!   getAdLeads(...)     GET  marketing/wechat_ad_leads/get
//!                       ?version=v1.0&date_range=<urlencoded>&page=&page_size=
//!                       [&filtering=<urlencoded>] → data{page_info,list}
//!
//! Java↔Zig 差异:
//!   - `WxMpUserAction` bean → `UserActionSpec`(借用切片);trace/action_param
//!     两个可选内嵌对象收为可选子结构(Java 的 actionParam Integer+leadsType
//!     字段组合成 action_param{value,leads_type});
//!   - `WxMpUserActionSet.fromJson` 解析 `data.list[]` → `ActionSetItem` 列表
//!     (核心字段 user_action_set_id/description/activate_status/created_time);
//!   - `WxMpAdLeadResult` 只解析 page_info{page_size,total_page,total_count}
//!     与 list.length(WxMpAdLead 的十几个字段不在本期契约测试范围,
//!     以 `AdLeadResult.total` 收敛);
//!   - Java `WxMpAdLeadFilter.toJsonObject` 构造了 values 数组却漏了 add(Java bug),
//!     Zig 修正:filtering 每项带 values[](与文档一致,header 注明差异);
//!   - Java 的 `URLEncoder.encode`(date_range/filtering)→ `urlEncode`。
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

/// 用户行为源 —— 对应 `WxMpUserActionSet`(响应侧核心字段)。
pub const ActionSetItem = struct {
    gpa: std.mem.Allocator,
    user_action_set_id: i64 = 0,
    description: []u8,
    activate_status: bool = false,
    created_time: []u8,

    pub fn deinit(self: *ActionSetItem) void {
        self.gpa.free(self.description);
        self.gpa.free(self.created_time);
        self.* = undefined;
    }
};

/// 用户行为 —— 对应 `WxMpUserAction`(请求侧,切片全借用)。
/// trace/action_param 为可选内嵌对象(Java 的 if != null 分支)。
pub const UserActionSpec = struct {
    user_action_set_id: i64,
    url: []const u8,
    action_time: i64,
    action_type: []const u8,
    /// `{"click_id":..}` —— 对应 Java 的 traceJson。
    click_id: ?[]const u8 = null,
    /// `{"value":..,"leads_type":..}` —— 对应 Java 的 actionParamJson。
    action_param_value: ?i64 = null,
    action_param_leads_type: ?[]const u8 = null,
};

/// 广告线索过滤 —— 对应 `WxMpAdLeadFilter`(field/operator/values[])。
pub const AdLeadFilter = struct {
    field: []const u8,
    operator: []const u8,
    values: []const []const u8,
};

/// 广告线索结果 —— 对应 `WxMpAdLeadResult`(page_info + list.length 收敛)。
pub const AdLeadResult = struct {
    gpa: std.mem.Allocator,
    page_size: i64 = 0,
    total_page: i64 = 0,
    total_count: i64 = 0,
    list_len: i64 = 0,

    pub fn deinit(self: *AdLeadResult) void {
        _ = self;
    }
};

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

pub const MarketingService = struct {
    svc: *service_mod.Service,

    /// 对应 `#addUserActionSets`(impl:22-31):
    /// POST {"type","name","description"} → data.user_action_set_id。
    pub fn addUserActionSets(self: *MarketingService, io: std.Io, mtype: []const u8, name: []const u8, description: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("name", name) catch return .{ .err = oom(gpa) };
        ob.putStr("description", description) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Marketing.user_action_sets_add, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "user_action_sets/add response not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "user_action_sets/add response missing data", .{}) };
        return .{ .ok = json_util.getIntOr(data, "user_action_set_id", 0) };
    }

    /// 对应 `#getUserActionSets`(impl:33-37):
    /// GET ?version=v1.0&user_action_set_id=<id> → data.list[]。
    pub fn getUserActionSets(self: *MarketingService, io: std.Io, user_action_set_id: i64) WxResult([]ActionSetItem) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?version=v1.0&user_action_set_id={d}", .{
            service_mod.api_host_url, api_url.Marketing.user_action_sets_get, user_action_set_id,
        }) catch return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "user_action_sets/get response not json", .{}) };
        defer parsed.deinit();
        var list: std.ArrayList(ActionSetItem) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getObject(parsed.value, "data")) |data| {
            if (json_util.getArray(data, "list")) |arr| {
                for (arr.items) |item| {
                    var it = ActionSetItem{
                        .gpa = gpa,
                        .user_action_set_id = json_util.getIntOr(item, "user_action_set_id", 0),
                        .description = gpa.dupe(u8, json_util.getStrOr(item, "description", "")) catch
                            return .{ .err = oom(gpa) },
                        .activate_status = json_util.getBool(item, "activate_status") orelse false,
                        .created_time = gpa.dupe(u8, json_util.getStrOr(item, "created_time", "")) catch
                            return .{ .err = oom(gpa) },
                    };
                    errdefer it.deinit();
                    list.append(gpa, it) catch return .{ .err = oom(gpa) };
                }
            }
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch return .{ .err = oom(gpa) } };
    }

    /// 对应 `#addUserAction`(impl:39-41):
    /// POST {"actions":[...]}(WxMpUserAction.listToJson)。
    pub fn addUserAction(self: *MarketingService, io: std.Io, actions: []const UserActionSpec) Done {
        const gpa = self.svc.gpa;
        // 容器树(actions 数组/每项对象/内嵌 trace、action_param)一次性组包进 arena
        // (照 guide.zig 的 arena 模式);字符串全部借用自入参。
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var arr: std.ArrayList(json_util.Value) = .empty;
        for (actions) |act| {
            var m: json_util.ObjectMap = .empty;
            m.put(a, "user_action_set_id", .{ .integer = act.user_action_set_id }) catch
                return .{ .err = oom(gpa) };
            m.put(a, "url", .{ .string = act.url }) catch
                return .{ .err = oom(gpa) };
            m.put(a, "action_time", .{ .integer = act.action_time }) catch
                return .{ .err = oom(gpa) };
            m.put(a, "action_type", .{ .string = act.action_type }) catch
                return .{ .err = oom(gpa) };
            if (act.click_id) |cid| {
                var trace: json_util.ObjectMap = .empty;
                trace.put(a, "click_id", .{ .string = cid }) catch
                    return .{ .err = oom(gpa) };
                m.put(a, "trace", .{ .object = trace }) catch
                    return .{ .err = oom(gpa) };
            }
            if (act.action_param_value) |v| {
                var param: json_util.ObjectMap = .empty;
                param.put(a, "value", .{ .integer = v }) catch
                    return .{ .err = oom(gpa) };
                if (act.action_param_leads_type) |lt| {
                    param.put(a, "leads_type", .{ .string = lt }) catch
                        return .{ .err = oom(gpa) };
                }
                m.put(a, "action_param", .{ .object = param }) catch
                    return .{ .err = oom(gpa) };
            }
            arr.append(a, .{ .object = m }) catch
                return .{ .err = oom(gpa) };
        }
        var root: json_util.ObjectMap = .empty;
        root.put(a, "actions", .{ .array = arr }) catch
            return .{ .err = oom(gpa) };
        const body = json_util.stringify(gpa, json_util.Value{ .object = root }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Marketing.user_actions_add, body);
    }

    /// 对应 `#getAdLeads`(impl:43-66):
    /// GET ?version=v1.0&date_range=<urlencoded {"begin_date","end_date"}>
    ///        &page=&page_size=[&filtering=<urlencoded [{field,operator,values[]}]>]
    /// → data{page_info,list}(只解析 page_info + list.length)。
    pub fn getAdLeads(self: *MarketingService, io: std.Io, begin_date: []const u8, end_date: []const u8, filtering: []const AdLeadFilter, page: i64, page_size: i64) WxResult(AdLeadResult) {
        const gpa = self.svc.gpa;
        // date_range JSON(urlencoded):{"begin_date":..,"end_date":..}(容器进 arena)
        const dr_body = blk: {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var dr: json_util.ObjectMap = .empty;
            dr.put(a, "begin_date", .{ .string = begin_date }) catch return .{ .err = oom(gpa) };
            dr.put(a, "end_date", .{ .string = end_date }) catch return .{ .err = oom(gpa) };
            break :blk json_util.stringify(gpa, json_util.Value{ .object = dr }) catch return .{ .err = oom(gpa) };
        };
        defer gpa.free(dr_body);
        const dr_enc = service_mod.urlEncode(gpa, dr_body) catch return .{ .err = oom(gpa) };
        defer gpa.free(dr_enc);

        // 手拼 query(对应 Java 的 params 字符串拼接):
        // version=v1.0&date_range=..&page=..&page_size=..[&filtering=..]
        var qs: std.ArrayList(u8) = .empty;
        defer qs.deinit(gpa);
        qs.appendSlice(gpa, "version=v1.0&date_range=") catch return .{ .err = oom(gpa) };
        qs.appendSlice(gpa, dr_enc) catch return .{ .err = oom(gpa) };
        const page_part = std.fmt.allocPrint(gpa, "&page={d}&page_size={d}", .{ page, page_size }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(page_part);
        qs.appendSlice(gpa, page_part) catch return .{ .err = oom(gpa) };
        if (filtering.len > 0) {
            const flt_body = self.filtersJson(gpa, filtering) catch return .{ .err = oom(gpa) };
            defer gpa.free(flt_body);
            const flt_enc = service_mod.urlEncode(gpa, flt_body) catch return .{ .err = oom(gpa) };
            defer gpa.free(flt_enc);
            qs.appendSlice(gpa, "&filtering=") catch return .{ .err = oom(gpa) };
            qs.appendSlice(gpa, flt_enc) catch return .{ .err = oom(gpa) };
        }
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?{s}", .{
            service_mod.api_host_url, api_url.Marketing.wechat_ad_leads_get, qs.items,
        }) catch return .{ .err = oom(gpa) };
        defer gpa.free(uri);

        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "wechat_ad_leads/get response not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getObject(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "wechat_ad_leads/get response missing data", .{}) };
        var r = AdLeadResult{ .gpa = gpa };
        if (json_util.getObject(data, "page_info")) |pi| {
            r.page_size = json_util.getIntOr(pi, "page_size", 0);
            r.total_page = json_util.getIntOr(pi, "total_page", 0);
            r.total_count = json_util.getIntOr(pi, "total_count", 0);
        }
        if (json_util.getArray(data, "list")) |arr| {
            r.list_len = @intCast(arr.items.len);
        }
        return .{ .ok = r };
    }

    /// filtering 数组 JSON:[{field,operator,values[]}](Java 漏 add values 的 bug
    /// 在 Zig 侧修正,values 一并序列化)。
    fn filtersJson(self: *MarketingService, gpa: std.mem.Allocator, filtering: []const AdLeadFilter) ![]u8 {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var arr: std.ArrayList(json_util.Value) = .empty;
        for (filtering) |f| {
            var m: json_util.ObjectMap = .empty;
            try m.put(a, "field", .{ .string = f.field });
            try m.put(a, "operator", .{ .string = f.operator });
            var vs: std.ArrayList(json_util.Value) = .empty;
            for (f.values) |v| try vs.append(a, .{ .string = v });
            try m.put(a, "values", .{ .array = vs });
            try arr.append(a, .{ .object = m });
        }
        return json_util.stringify(gpa, json_util.Value{ .array = arr });
    }
};

// ---------------------------------------------------------------------------
// 契约测试:4 端点 URL/method/请求体 + data 剥壳解析
// (逐字对照 WxMpApiUrl.Marketing + WxMpMarketingServiceImpl + WxMpUserActionSet)
// ---------------------------------------------------------------------------

test "Marketing 契约: addUserActionSets/getUserActionSets/addUserAction/getAdLeads (WxMpApiUrl.Marketing)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "marketing/user_action_sets/add", .response = "{\"errcode\":0,\"data\":{\"user_action_set_id\":1024}}" },
        .{ .match = "marketing/user_action_sets/get", .response = "{\"errcode\":0,\"data\":{\"list\":[{\"user_action_set_id\":1024,\"description\":\"测试行为源\",\"activate_status\":true,\"created_time\":\"2026-01-08\"}]}}" },
        .{ .match = "marketing/user_actions/add", .response = "{\"errcode\":0}" },
        .{ .match = "marketing/wechat_ad_leads/get", .response = "{\"errcode\":0,\"data\":{\"page_info\":{\"page_size\":100,\"total_page\":1,\"total_count\":2},\"list\":[{\"click_id\":\"c1\"},{\"click_id\":\"c2\"}]}}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = MarketingService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // addUserActionSets: {"type","name","description"} → data.user_action_set_id
    switch (svc.addUserActionSets(io, "WEB", "行为源", "测试")) {
        .ok => |id| try testing.expectEqual(@as(i64, 1024), id),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMarketingAddActionSets;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "marketing/user_action_sets/add?version=v1.0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":\"WEB\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"description\":\"测试\"") != null);

    // getUserActionSets: GET ?version=v1.0&user_action_set_id= → data.list[]
    switch (svc.getUserActionSets(io, 1024)) {
        .ok => |items| {
            defer {
                for (items) |*it| it.deinit();
                if (items.len > 0) gpa.free(items);
            }
            try testing.expectEqual(@as(usize, 1), items.len);
            try testing.expectEqual(@as(i64, 1024), items[0].user_action_set_id);
            try testing.expect(items[0].activate_status);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMarketingGetActionSets;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "marketing/user_action_sets/get?version=v1.0&user_action_set_id=1024") != null);

    // addUserAction: {"actions":[{...,trace,action_param}]}
    switch (svc.addUserAction(io, &.{.{
        .user_action_set_id = 1024,
        .url = "https://example.com",
        .action_time = 1736294400,
        .action_type = "RESERVE",
        .click_id = "CLICK1",
        .action_param_value = 1,
        .action_param_leads_type = "MOBILE",
    }})) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMarketingAddUserAction;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "marketing/user_actions/add?version=v1.0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"actions\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"user_action_set_id\":1024") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"trace\":{\"click_id\":\"CLICK1\"}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"action_param\":{\"value\":1,\"leads_type\":\"MOBILE\"}") != null);

    // getAdLeads: date_range/filtering urlencoded
    switch (svc.getAdLeads(io, "2026-01-01", "2026-01-08", &.{.{ .field = "campaign_name", .operator = "EQUAL", .values = &.{"推广"} }}, 1, 100)) {
        .ok => |*r| {
            try testing.expectEqual(@as(i64, 100), r.page_size);
            try testing.expectEqual(@as(i64, 2), r.total_count);
            try testing.expectEqual(@as(i64, 2), r.list_len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMarketingGetAdLeads;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "marketing/wechat_ad_leads/get?version=v1.0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "&page=1&page_size=100") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "%22begin_date%22%3A%222026-01-01%22") != null);
}
