//! 顾问·客户服务 —— 对应 Java `api.WxMpGuideBuyerService` +
//! `api.impl.WxMpGuideBuyerServiceImpl`,端点常量取自 `enums/WxMpApiUrl.Guide`。
//!
//! 样板见 `services/user.zig`,复用 `sub_util.zig`。逐字对照 WxMpGuideBuyerServiceImpl
//! (全部 POST)。ACCOUNT="guide_account" / OPENID="guide_openid"(impl:24-25)。
//! 带 `List<...>` 参数的方法与单 openid 重载共用同一 URL,Zig 用 `xxxBatch`/`xxx` 区分。
//!   addGuideBuyerRelation    ADD_GUIDE_BUYER_RELATION    /cgi-bin/guide/addguidebuyerrelation
//!     批量:{"guide_account","guide_openid","buyer_list":[{openid,buyer_nickname}]} → buyer_resp
//!     单个:{"guide_account","guide_openid","openid","buyer_nickname"} → void
//!   delGuideBuyerRelation    DEL_GUIDE_BUYER_RELATION    /cgi-bin/guide/delguidebuyerrelation
//!     批量:{"guide_account","guide_openid","openid_list":[...]} → buyer_resp
//!     单个:{"guide_account","guide_openid","openid"} → void
//!   getGuideBuyerRelationList GET_GUIDE_BUYER_RELATION_LIST /cgi-bin/guide/getguidebuyerrelationlist
//!     {"guide_account","guide_openid","page","num"} → WxMpGuideBuyerInfoList(原样返回)
//!   rebindGuideAcctForBuyer  REBIND_GUIDE_ACCT_FOR_BUYER /cgi-bin/guide/rebindguideacctforbuyer
//!     批量:{"old_guide_account","old_guide_openid","new_guide_account","new_guide_openid","openid_list"} → buyer_resp
//!     单个:同上去掉 openid_list 改 "openid" → void
//!   updateGuideBuyerRelation UPDATE_GUIDE_BUYER_RELATION /cgi-bin/guide/updateguidebuyerrelation
//!     {"guide_account","guide_openid","openid","buyer_nickname"} → void
//!   getGuideBuyerRelationByBuyer GET_GUIDE_BUYER_RELATION_BY_BUYER /cgi-bin/guide/getguidebuyerrelationbybuyer
//!     {"openid"} → WxMpGuideBuyerRelation(原样返回)
//!   getGuideBuyerRelation    GET_GUIDE_BUYER_RELATION    /cgi-bin/guide/getguidebuyerrelation
//!     {"guide_account","guide_openid","openid"} → WxMpGuideBuyerInfo(原样返回)
//!
//! 返回 WxResult([]u8) 的端点与 Java 返回 String/bean 的方法同口径:原样返回响应 body,
//! Java 里 `getAsJsonArray("buyer_resp")` 等字段级解析留待下一轮,不编造字段。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 对应 Java `WxMpAddGuideBuyerInfo`:@SerializedName("openid") /
/// @SerializedName("buyer_nickname")(两字段均为普通字符串,buildJsonObject 时都拼入)。
pub const GuideBuyerInfo = struct {
    openid: []const u8,
    buyer_nickname: []const u8,
};

pub const GuideBuyerService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *GuideBuyerService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,errcode==0 即完成。
    fn postDone(self: *GuideBuyerService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#addGuideBuyerRelation`(impl:28-39,批量):
    /// {"guide_account","guide_openid","buyer_list":[...]} → 原样返回(Java 取 "buyer_resp")。
    pub fn addGuideBuyerRelationBatch(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, infos: []const GuideBuyerInfo) WxResult([]u8) {
        return self.post(io, .guide_add_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .buyer_list = infos,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#addGuideBuyerRelation`(impl:41-45,单个):
    /// {"guide_account","guide_openid","openid","buyer_nickname"} → void。
    pub fn addGuideBuyerRelation(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8, nickname: []const u8) Done {
        return self.postDone(io, .guide_add_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
            .buyer_nickname = nickname,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#delGuideBuyerRelation`(impl:47-58,批量):
    /// {"guide_account","guide_openid","openid_list":[...]} → 原样返回("buyer_resp")。
    pub fn delGuideBuyerRelationBatch(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, buyer_openids: []const []const u8) WxResult([]u8) {
        return self.post(io, .guide_del_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid_list = buyer_openids,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#delGuideBuyerRelation`(impl:60-64,单个):
    /// {"guide_account","guide_openid","openid"} → void。
    pub fn delGuideBuyerRelation(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8) Done {
        return self.postDone(io, .guide_del_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#getGuideBuyerRelationList`(impl:66-70):
    /// {"guide_account","guide_openid","page","num"} → 原样返回。
    pub fn getGuideBuyerRelationList(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, page: i64, num: i64) WxResult([]u8) {
        return self.post(io, .guide_get_buyer_relation_list, .{
            .guide_account = account,
            .guide_openid = openid,
            .page = page,
            .num = num,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#rebindGuideAcctForBuyer`(impl:72-85,批量):
    /// 5 字段(注意 old_/new_ 前缀)→ 原样返回("buyer_resp")。
    pub fn rebindGuideAcctForBuyerBatch(self: *GuideBuyerService, io: std.Io, old_account: []const u8, old_openid: []const u8, account: []const u8, openid: []const u8, buyer_openids: []const []const u8) WxResult([]u8) {
        return self.post(io, .guide_rebind_buyer, .{
            .old_guide_account = old_account,
            .old_guide_openid = old_openid,
            .new_guide_account = account,
            .new_guide_openid = openid,
            .openid_list = buyer_openids,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#rebindGuideAcctForBuyer`(impl:87-97,单个):
    /// 5 字段(单个 openid)→ void。
    pub fn rebindGuideAcctForBuyer(self: *GuideBuyerService, io: std.Io, old_account: []const u8, old_openid: []const u8, account: []const u8, openid: []const u8, user_openid: []const u8) Done {
        return self.postDone(io, .guide_rebind_buyer, .{
            .old_guide_account = old_account,
            .old_guide_openid = old_openid,
            .new_guide_account = account,
            .new_guide_openid = openid,
            .openid = user_openid,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#updateGuideBuyerRelation`(impl:99-104):
    /// {"guide_account","guide_openid","openid","buyer_nickname"} → void。
    pub fn updateGuideBuyerRelation(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8, nickname: []const u8) Done {
        return self.postDone(io, .guide_update_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
            .buyer_nickname = nickname,
        });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#getGuideBuyerRelationByBuyer`(impl:106-110):
    /// {"openid"} → 原样返回。
    pub fn getGuideBuyerRelationByBuyer(self: *GuideBuyerService, io: std.Io, user_openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_buyer_relation_by_buyer, .{ .openid = user_openid });
    }

    /// 对应 `WxMpGuideBuyerServiceImpl#getGuideBuyerRelation`(impl:112-117):
    /// {"guide_account","guide_openid","openid"} → 原样返回。
    pub fn getGuideBuyerRelation(self: *GuideBuyerService, io: std.Io, account: []const u8, openid: []const u8, user_openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_buyer_relation, .{
            .guide_account = account,
            .guide_openid = openid,
            .openid = user_openid,
        });
    }
};

// ---------------------------------------------------------------------------
// 契约测试:7 端点 URL/method/请求体字段名(逐字对照 WxMpApiUrl.Guide +
// WxMpGuideBuyerServiceImpl);批量/单 openid 两个重载均覆盖。
// ---------------------------------------------------------------------------

test "Guide Buyer 契约: 7 端点 URL/method/请求体 (WxMpGuideBuyerServiceImpl)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/", .response = "{\"errcode\":0,\"buyer_resp\":[{\"openid\":\"U1\"}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideBuyerService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 ADD_GUIDE_BUYER_RELATION 批量:buyer_list 为 {openid,buyer_nickname} 数组
    const infos = [_]GuideBuyerInfo{
        .{ .openid = "U1", .buyer_nickname = "N1" },
    };
    switch (svc.addGuideBuyerRelationBatch(io, "ACC", "GOPEN", &infos)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"buyer_resp\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerAddBatch;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguidebuyerrelation") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"buyer_list\":[{\"openid\":\"U1\",\"buyer_nickname\":\"N1\"}]") != null);

    // 1b ADD_GUIDE_BUYER_RELATION 单个:openid + buyer_nickname → void
    switch (svc.addGuideBuyerRelation(io, "ACC", "GOPEN", "U1", "N1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerAdd;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"buyer_nickname\":\"N1\"") != null);

    // 2 DEL_GUIDE_BUYER_RELATION 批量:openid_list 字符串数组
    const openids = [_][]const u8{ "U1", "U2" };
    switch (svc.delGuideBuyerRelationBatch(io, "ACC", "GOPEN", &openids)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerDelBatch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidebuyerrelation") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"U1\",\"U2\"]") != null);

    // 2b DEL_GUIDE_BUYER_RELATION 单个:openid → void
    switch (svc.delGuideBuyerRelation(io, "ACC", "GOPEN", "U1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerDel;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);

    // 3 GET_GUIDE_BUYER_RELATION_LIST:{"page","num"}
    switch (svc.getGuideBuyerRelationList(io, "ACC", "GOPEN", 2, 20)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyerrelationlist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page\":2") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"num\":20") != null);

    // 4 REBIND_GUIDE_ACCT_FOR_BUYER 批量:old_/new_ 四个前缀字段 + openid_list
    switch (svc.rebindGuideAcctForBuyerBatch(io, "OLDACC", "OLDOPEN", "ACC", "GOPEN", &openids)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerRebindBatch;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/rebindguideacctforbuyer") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"old_guide_account\":\"OLDACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"old_guide_openid\":\"OLDOPEN\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"new_guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"new_guide_openid\":\"GOPEN\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid_list\":[\"U1\",\"U2\"]") != null);

    // 4b REBIND_GUIDE_ACCT_FOR_BUYER 单个:改为 "openid" → void
    switch (svc.rebindGuideAcctForBuyer(io, "OLDACC", "OLDOPEN", "ACC", "GOPEN", "U1")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerRebind;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "openid_list") == null);

    // 5 UPDATE_GUIDE_BUYER_RELATION:openid + buyer_nickname → void
    switch (svc.updateGuideBuyerRelation(io, "ACC", "GOPEN", "U1", "N2")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerUpdate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/updateguidebuyerrelation") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"buyer_nickname\":\"N2\"") != null);

    // 6 GET_GUIDE_BUYER_RELATION_BY_BUYER:{"openid"}
    switch (svc.getGuideBuyerRelationByBuyer(io, "U1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerByBuyer;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyerrelationbybuyer") != null);
    try testing.expectEqualStrings("{\"openid\":\"U1\"}", mock.body());

    // 7 GET_GUIDE_BUYER_RELATION:{"guide_account","guide_openid","openid"}
    switch (svc.getGuideBuyerRelation(io, "ACC", "GOPEN", "U1")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideBuyerRelation;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyerrelation?") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"U1\"") != null);

    // 7 端点 + 3 个单 openid 重载 = 10 次 POST
    try testing.expectEqual(@as(usize, 10), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}
