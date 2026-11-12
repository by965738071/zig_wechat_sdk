//! 顾问·标签服务 —— 对应 Java `api.WxMpGuideTagService` +
//! `api.impl.WxMpGuideTagServiceImpl`,端点常量取自 `enums/WxMpApiUrl.Guide`。
//!
//! 样板见 `services/user.zig`,复用 `sub_util.zig`。逐字对照 WxMpGuideTagServiceImpl
//! (全部 POST)。ACCOUNT="guide_account" / OPENID="guide_openid"(impl:28-29)。
//!   newGuideTagOption     NEW_GUIDE_TAG_OPTION      /cgi-bin/guide/newguidetagoption
//!     {"tag_name","tag_values":[...]} → void
//!   delGuideTagOption     DEL_GUIDE_TAG_OPTION      /cgi-bin/guide/delguidetagoption
//!     {"tag_name"} → void
//!   addGuideTagOption     ADD_GUIDE_TAG_OPTION      /cgi-bin/guide/addguidetagoption
//!     {"tag_name","tag_values":[...]} → void
//!   getGuideTagOption     GET_GUIDE_TAG_OPTION      /cgi-bin/guide/getguidetagoption
//!     new JsonObject() = "{}" → 原样返回(Java 取 "options" 数组后过滤空 tagName)
//!   addGuideBuyerTag      ADD_GUIDE_BUYER_TAG       /cgi-bin/guide/addguidebuyertag
//!     批量:{"guide_account","guide_openid","tag_value","openid_list":[...]} → 原样返回("buyer_resp")
//!     单个:{"guide_account","guide_openid","tag_value","openid"} → void
//!   getGuideBuyerTag      GET_GUIDE_BUYER_TAG       /cgi-bin/guide/getguidebuyertag
//!     {"guide_account","guide_openid","openid"} → 原样返回(Java 取 "tag_values" 数组;
//!     isExclude 仅 Java 侧对结果列表做后处理,不是请求字段,逐字对齐不放)
//!   queryGuideBuyerByTag  QUERY_GUIDE_BUYER_BY_TAG  /cgi-bin/guide/queryguidebuyerbytag
//!     {"guide_account","guide_openid","push_count","tag_values":[...]} → 原样返回("openid_list")
//!   delGuideBuyerTag      DEL_GUIDE_BUYER_TAG       /cgi-bin/guide/delguidebuyertag
//!     批量:{"guide_account","guide_openid","tag_value","openid_list":[...]} → 原样返回("buyer_resp")
//!     单个:{"guide_account","guide_openid","tag_value","openid"} → void
//!   addGuideBuyerDisplayTag ADD_GUIDE_BUYER_DISPLAY_TAG /cgi-bin/guide/addguidebuyerdisplaytag
//!     {"guide_account","guide_openid","openid","display_tag_list":[...]} → void
//!   getGuideBuyerDisplayTag GET_GUIDE_BUYER_DISPLAY_TAG /cgi-bin/guide/getguidebuyerdisplaytag
//!     {"guide_account","guide_openid","openid"} → 原样返回(Java 取 "display_tag_list" 数组)
//!
//! 返回 WxResult([]u8) 的端点与 Java 返回 String/List 的方法同口径:原样返回响应 body,
//! Java 里 `getAsJsonArray(...)` 等字段级解析留待下一轮,不编造字段。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

pub const GuideTagService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *GuideTagService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,errcode==0 即完成。
    fn postDone(self: *GuideTagService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    /// Java `this.mpService.post(url, new JsonObject())` —— 请求体为 "{}"。
    fn postEmpty(self: *GuideTagService, io: std.Io, which: service_mod.ApiUrl) WxResult([]u8) {
        return h.apiPost(self.svc, io, which.asUri(), "{}");
    }

    /// 对应 `WxMpGuideTagServiceImpl#newGuideTagOption`(impl:32-38):
    /// {"tag_name","tag_values"} → void。
    pub fn newGuideTagOption(self: *GuideTagService, io: std.Io, tag_name: []const u8, values: []const []const u8) Done {
        return self.postDone(io, .guide_new_tag_option, .{ .tag_name = tag_name, .tag_values = values });
    }

    /// 对应 `WxMpGuideTagServiceImpl#delGuideTagOption`(impl:40-43):{"tag_name"} → void。
    pub fn delGuideTagOption(self: *GuideTagService, io: std.Io, tag_name: []const u8) Done {
        return self.postDone(io, .guide_del_tag_option, .{ .tag_name = tag_name });
    }

    /// 对应 `WxMpGuideTagServiceImpl#addGuideTagOption`(impl:45-51):
    /// {"tag_name","tag_values"} → void。
    pub fn addGuideTagOption(self: *GuideTagService, io: std.Io, tag_name: []const u8, values: []const []const u8) Done {
        return self.postDone(io, .guide_add_tag_option, .{ .tag_name = tag_name, .tag_values = values });
    }

    /// 对应 `WxMpGuideTagServiceImpl#getGuideTagOption`(impl:53-60):new JsonObject() → "{}"。
    pub fn getGuideTagOption(self: *GuideTagService, io: std.Io) WxResult([]u8) {
        return self.postEmpty(io, .guide_get_tag_option);
    }

    /// 对应 `WxMpGuideTagServiceImpl#addGuideBuyerTag`(impl:62-73,批量):
    /// {"guide_account","guide_openid","tag_value","openid_list"} → 原样返回("buyer_resp")。
    pub fn addGuideBuyerTagBatch(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, value: []const u8, user_openids: []const []const u8) WxResult([]u8) {
        return self.post(io, .guide_add_buyer_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .tag_value = value,
            .openid_list = user_openids,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#addGuideBuyerTag`(impl:75-83,单个):
    /// {"guide_account","guide_openid","tag_value","openid"} → void。
    pub fn addGuideBuyerTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, value: []const u8, user_openid: []const u8) Done {
        return self.postDone(io, .guide_add_buyer_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .tag_value = value,
            .openid = user_openid,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#getGuideBuyerTag`(impl:85-101):
    /// {"guide_account","guide_openid","openid"} → 原样返回("tag_values")。
    /// 注意:isExclude 参数只用于 Java 侧对返回列表做后处理(去掉末尾含 "\n" 的元素),
    /// 不属于 HTTP 请求字段,逐字对齐 GsonHelper.buildJsonObject 不放。
    pub fn getGuideBuyerTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_buyer_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#queryGuideBuyerByTag`(impl:103-114):
    /// {"guide_account","guide_openid","push_count","tag_values"} → 原样返回("openid_list")。
    pub fn queryGuideBuyerByTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, push_count: i64, value: []const []const u8) WxResult([]u8) {
        return self.post(io, .guide_query_buyer_by_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .push_count = push_count,
            .tag_values = value,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#delGuideBuyerTag`(impl:116-127,批量):
    /// {"guide_account","guide_openid","tag_value","openid_list"} → 原样返回("buyer_resp")。
    pub fn delGuideBuyerTagBatch(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, value: []const u8, user_openids: []const []const u8) WxResult([]u8) {
        return self.post(io, .guide_del_buyer_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .tag_value = value,
            .openid_list = user_openids,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#delGuideBuyerTag`(impl:129-137,单个):
    /// {"guide_account","guide_openid","tag_value","openid"} → void。
    pub fn delGuideBuyerTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, value: []const u8, user_openid: []const u8) Done {
        return self.postDone(io, .guide_del_buyer_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .tag_value = value,
            .openid = user_openid,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#addGuideBuyerDisplayTag`(impl:139-147):
    /// {"guide_account","guide_openid","openid","display_tag_list"} → void。
    pub fn addGuideBuyerDisplayTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8, msg_list: []const []const u8) Done {
        return self.postDone(io, .guide_add_buyer_display_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
            .display_tag_list = msg_list,
        });
    }

    /// 对应 `WxMpGuideTagServiceImpl#getGuideBuyerDisplayTag`(impl:149-159):
    /// {"guide_account","guide_openid","openid"} → 原样返回("display_tag_list")。
    pub fn getGuideBuyerDisplayTag(self: *GuideTagService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_buyer_display_tag, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
        });
    }
};

// ---------------------------------------------------------------------------
// 契约测试:10 端点 URL/method/请求体字段名(逐字对照 WxMpApiUrl.Guide +
// WxMpGuideTagServiceImpl);批量/单 openid 两个重载均覆盖。
// ---------------------------------------------------------------------------

test "Guide Tag 契约: 10 端点 URL/method/请求体 (WxMpGuideTagServiceImpl)" {
    const gpa = testing.allocator;
    // 兜底响应含所有 Java `getAsJsonArray(...)` 用到的响应字段名。
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/", .response = "{\"errcode\":0,\"options\":[],\"buyer_resp\":[],\"tag_values\":[\"T1\"],\"openid_list\":[\"U1\"],\"display_tag_list\":[\"D1\"]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideTagService{ .svc = &fx.svc };
    const io = fx.threaded.io();
    const values = [_][]const u8{ "V1", "V2" };
    const openids = [_][]const u8{ "U1", "U2" };

    // 1 NEW_GUIDE_TAG_OPTION: {"tag_name","tag_values"}
    switch (svc.newGuideTagOption(io, "TAG", &values)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagNew;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/newguidetagoption") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"tag_name\":\"TAG\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"tag_values\":[\"V1\",\"V2\"]") != null);

    // 2 DEL_GUIDE_TAG_OPTION: {"tag_name"}
    switch (svc.delGuideTagOption(io, "TAG")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagDel;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidetagoption") != null);
    try testing.expectEqualStrings("{\"tag_name\":\"TAG\"}", mock.body());

    // 3 ADD_GUIDE_TAG_OPTION: {"tag_name","tag_values"}
    switch (svc.addGuideTagOption(io, "TAG", &values)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagAdd;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguidetagoption") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"tag_values\":[\"V1\",\"V2\"]") != null);

    // 4 GET_GUIDE_TAG_OPTION: body "{}" (new JsonObject()),响应字段名 "options"
    switch (svc.getGuideTagOption(io)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"options\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidetagoption") != null);
    try testing.expectEqualStrings("{}", mock.body());

    // 5 ADD_GUIDE_BUYER_TAG 批量: tag_value + openid_list
    switch (svc.addGuideBuyerTagBatch(io, "ACC", "GOPEN", "V1", &openids)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"buyer_resp\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagAddBuyerBatch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguidebuyertag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"tag_value\":\"V1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"U1\",\"U2\"]") != null);

    // 5b ADD_GUIDE_BUYER_TAG 单个: tag_value + openid
    switch (svc.addGuideBuyerTag(io, "ACC", "GOPEN", "V1", "U1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagAddBuyer;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);

    // 6 GET_GUIDE_BUYER_TAG: {"guide_account","guide_openid","openid"},响应 "tag_values"
    switch (svc.getGuideBuyerTag(io, "ACC", "GOPEN", "U1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"tag_values\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagGetBuyer;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyertag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "is_exclude") == null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "isExclude") == null);

    // 7 QUERY_GUIDE_BUYER_BY_TAG: push_count + tag_values,响应 "openid_list"
    switch (svc.queryGuideBuyerByTag(io, "ACC", "GOPEN", 3, &values)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"openid_list\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagQuery;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/queryguidebuyerbytag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"push_count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"tag_values\":[\"V1\",\"V2\"]") != null);

    // 8 DEL_GUIDE_BUYER_TAG 批量: tag_value + openid_list
    switch (svc.delGuideBuyerTagBatch(io, "ACC", "GOPEN", "V1", &openids)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagDelBuyerBatch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidebuyertag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"U1\",\"U2\"]") != null);

    // 8b DEL_GUIDE_BUYER_TAG 单个: tag_value + openid
    switch (svc.delGuideBuyerTag(io, "ACC", "GOPEN", "V1", "U1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagDelBuyer;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);

    // 9 ADD_GUIDE_BUYER_DISPLAY_TAG: display_tag_list
    switch (svc.addGuideBuyerDisplayTag(io, "ACC", "GOPEN", "U1", &values)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagAddDisplay;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguidebuyerdisplaytag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"display_tag_list\":[\"V1\",\"V2\"]") != null);

    // 10 GET_GUIDE_BUYER_DISPLAY_TAG: {"guide_account","guide_openid","openid"},
    //     响应字段名 "display_tag_list"
    switch (svc.getGuideBuyerDisplayTag(io, "ACC", "GOPEN", "U1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"display_tag_list\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideTagGetDisplay;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyerdisplaytag") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);

    // 10 端点 + 2 个单 openid 重载 = 12 次 POST
    try testing.expectEqual(@as(usize, 12), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}
