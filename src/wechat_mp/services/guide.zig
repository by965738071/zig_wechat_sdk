//! 顾问(对话能力)服务 —— 对应 Java `api.WxMpGuideService` +
//! `api.impl.WxMpGuideServiceImpl`,端点常量取自 `enums/WxMpApiUrl.Guide`。
//!
//! 样板见 `services/user.zig`,复用 `sub_util.zig`(h.apiPost/h.postVoid/h.strField/
//! h.intField/Recorder/Fixture)。逐字对照 WxMpGuideServiceImpl(全部 POST):
//!   addGuide          ADD_GUIDE          /cgi-bin/guide/addguideacct
//!                     {"guide_account","guide_headimgurl","guide_nickname","guide_openid"} → void
//!   updateGuide       UPDATE_GUIDE       /cgi-bin/guide/updateguideacct        (同上 body) → void
//!   getGuide          GET_GUIDE          /cgi-bin/guide/getguideacct
//!                     {"guide_account","guide_openid"} → WxMpGuideInfo.fromJson(原样返回)
//!   delGuide          DEL_GUIDE          /cgi-bin/guide/delguideacct          (同上 body) → void
//!   listGuide         LIST_GUIDE         /cgi-bin/guide/getguideacctlist       {"page","num"} → WxMpGuideList(原样返回)
//!   createGuideQrCode CREATE_QR_CODE     /cgi-bin/guide/guidecreateqrcode
//!                     {"guide_account","guide_openid","qrcode_info"} → get("qrcode_url")
//!   getGuideChatRecord GET_GUIDE_CHAT_RECORD /cgi-bin/guide/getguidebuyerchatrecord
//!                     {"guide_account","guide_openid","begin_time","end_time","page","num"}
//!                     (注意:Java 方法签名含 clientOpenid 但 buildJsonObject 未放入该字段,逐字对齐不放)
//!   getGuideConfig    GET_GUIDE_CONFIG   /cgi-bin/guide/getguideconfig         {"guide_account","guide_openid"}
//!   getGuideAcctConfig GET_GUIDE_ACCT_CONFIG /cgi-bin/guide/getguideacctconfig  new JsonObject() = "{}"
//!   setGuideConfig    SET_GUIDE_CONFIG   /cgi-bin/guide/setguideconfig
//!                     LinkedHashMap: guide_account/guide_openid/is_delete/guide_fast_reply_list
//!                     ([{"content":..}] 数组)/guide_auto_reply/guide_auto_reply_plus
//!                     (WxMpAddGuideAutoReply: {"content","msgtype"}) → void
//!   setGuideAcctConfig SET_GUIDE_ACCT_CONFIG /cgi-bin/guide/setguideacctconfig
//!                     {"is_delete","black_keyword":{"values":[...]},"guide_auto_reply":{"content":..}} → void
//!   pushShowWxaPathMenu PUSH_SHOW_WX_PATH_MENU /cgi-bin/guide/pushshowwxapathmenu
//!                     {"wxa_appid","wx_username"} → void
//!   newGuideGroup     NEW_GUIDE_GROUP    /cgi-bin/guide/newguidegroup
//!                     {"group_name"} → get("group_id") (Long)
//!   getGuideGroupList GET_GUIDE_GROUP_LIST /cgi-bin/guide/getguidegrouplist
//!                     new JsonObject() = "{}" → getAsJsonArray("group_list")
//!   getGroupInfo      GET_GROUP_GUIDE_INFO /cgi-bin/guide/getgroupinfo
//!                     {"group_id","page","num"} → WxMpGuideGroupInfoList(原样返回)
//!   addGuide2GuideGroup ADD_GROUP_GUIDE  /cgi-bin/guide/addguide2guidegroup   {"group_id","guide_account"} → void
//!   delGuide2GuideGroup DEL_GROUP_GUIDE  /cgi-bin/guide/delguide2guidegroup   {"group_id","guide_account"} → void
//!   getGroupByGuide   GET_GROUP_ON_GUIDE /cgi-bin/guide/getgroupbyguide
//!                     {"guide_account"} → getAsJsonArray("group_id_list")
//!   delGuideGroup     DEL_GROUP          /cgi-bin/guide/delguidegroup         {"group_id"} → void
//!
//! setGuideConfig / setGuideAcctConfig 的嵌套对象逐字取自 impl 装配代码与
//! WxMpAddGuideAutoReply 的 @SerializedName("content")/"msgtype"。setGuideConfig 走
//! WxGsonBuilder.toJson(Map)(WxGsonBuilder.java 未开启 serializeNulls,Gson 默认省略
//! null 值/字段);Zig 侧对两个 set* 的 null 可选参数统一 omit 对应 key,契约测试用
//! 全非空入参固定 URL/字段名/嵌套结构,不对 JsonObject.toString() 的 null 细节下断言。
//! 字段级响应解析同 getGuideConfig 口径留待下一轮,不编造字段。
//! 返回 WxResult([]u8) 的端点与 Java 返回 String 的方法(如 getCardDetail)同口径:
//! 原样返回响应 body(调用方 free)。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 对应 Java `WxMpAddGuideAutoReply`:@SerializedName("content") +
/// @SerializedName("msgtype")(1 文字 / 2 图片 / 3 小程序卡片)。
pub const GuideAutoReply = struct {
    content: []const u8,
    msgtype: ?i64 = null,
};

fn oom(gpa: std.mem.Allocator) Done {
    return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
}

/// WxMpAddGuideAutoReply 的 Gson 序列化:{"content":..[,"msgtype":..]}。
fn autoReplyValue(a: std.mem.Allocator, r: GuideAutoReply) !json_util.Value {
    var o: json_util.ObjectMap = .empty;
    try o.put(a, "content", .{ .string = r.content });
    if (r.msgtype) |mt| try o.put(a, "msgtype", .{ .integer = mt });
    return .{ .object = o };
}

/// guide_fast_reply_list:Java 把每个字符串包成 {"content":it} 的 JsonArray。
fn fastReplyArray(a: std.mem.Allocator, list: []const []const u8) !json_util.Value {
    var arr: std.ArrayList(json_util.Value) = .empty;
    for (list) |it| {
        var o: json_util.ObjectMap = .empty;
        try o.put(a, "content", .{ .string = it });
        try arr.append(a, .{ .object = o });
    }
    return .{ .array = arr };
}

pub const GuideService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *GuideService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,errcode==0 即完成。
    fn postDone(self: *GuideService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    /// Java `this.mpService.post(url, new JsonObject())` —— 请求体为 "{}"。
    fn postEmpty(self: *GuideService, io: std.Io, which: service_mod.ApiUrl) WxResult([]u8) {
        return h.apiPost(self.svc, io, which.asUri(), "{}");
    }

    /// 对应 `WxMpGuideServiceImpl#addGuide`:ACCOUNT="guide_account",
    /// OPENID="guide_openid"(impl:28-35)。
    pub fn addGuide(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8, head_img_url: []const u8, nick_name: []const u8) Done {
        return self.postDone(io, .guide_add, .{
            .guide_account = account,
            .guide_headimgurl = head_img_url,
            .guide_nickname = nick_name,
            .guide_openid = openid,
        });
    }

    /// 对应 `WxMpGuideServiceImpl#updateGuide`(impl:47-55):与 addGuide 同 body。
    pub fn updateGuide(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8, head_img_url: []const u8, nick_name: []const u8) Done {
        return self.postDone(io, .guide_update, .{
            .guide_account = account,
            .guide_headimgurl = head_img_url,
            .guide_nickname = nick_name,
            .guide_openid = openid,
        });
    }

    /// 对应 `WxMpGuideServiceImpl#getGuide`(impl:57-61):WxMpGuideInfo.fromJson。
    pub fn getGuide(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get, .{ .guide_account = account, .guide_openid = openid });
    }

    /// 对应 `WxMpGuideServiceImpl#delGuide`(impl:63-67)。
    pub fn delGuide(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8) Done {
        return self.postDone(io, .guide_del, .{ .guide_account = account, .guide_openid = openid });
    }

    /// 对应 `WxMpGuideServiceImpl#listGuide`(impl:69-73):{"page","num"}。
    pub fn listGuide(self: *GuideService, io: std.Io, page: i64, num: i64) WxResult([]u8) {
        return self.post(io, .guide_list, .{ .page = page, .num = num });
    }

    /// 对应 `WxMpGuideServiceImpl#createGuideQrCode`(impl:75-80):取 "qrcode_url"。
    pub fn createGuideQrCode(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8, qrcode_info: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const resp = switch (self.post(io, .guide_create_qrcode, .{
            .guide_account = account,
            .guide_openid = openid,
            .qrcode_info = qrcode_info,
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.strField(gpa, resp, "qrcode_url");
    }

    /// 对应 `WxMpGuideServiceImpl#getGuideChatRecord`(impl:82-91)。
    pub fn getGuideChatRecord(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8, begin_time: i64, end_time: i64, page: i64, num: i64) WxResult([]u8) {
        return self.post(io, .guide_chat_record, .{
            .guide_account = account,
            .guide_openid = openid,
            .begin_time = begin_time,
            .end_time = end_time,
            .page = page,
            .num = num,
        });
    }

    /// 对应 `WxMpGuideServiceImpl#getGuideConfig`(impl:115-119)。
    pub fn getGuideConfig(self: *GuideService, io: std.Io, account: []const u8, openid: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_config, .{ .guide_account = account, .guide_openid = openid });
    }

    /// 对应 `WxMpGuideServiceImpl#getGuideAcctConfig`(impl:144-147):new JsonObject()。
    pub fn getGuideAcctConfig(self: *GuideService, io: std.Io) WxResult([]u8) {
        return self.postEmpty(io, .guide_get_acct_config);
    }

    /// 对应 `WxMpGuideServiceImpl#pushShowWxaPathMenu`(impl:149-153)。
    pub fn pushShowWxaPathMenu(self: *GuideService, io: std.Io, appid: []const u8, username: []const u8) Done {
        return self.postDone(io, .guide_push_wxa_path, .{ .wxa_appid = appid, .wx_username = username });
    }

    /// 对应 `WxMpGuideServiceImpl#newGuideGroup`(impl:155-160):取 "group_id" (Long)。
    pub fn newGuideGroup(self: *GuideService, io: std.Io, group_name: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const resp = switch (self.post(io, .guide_new_group, .{ .group_name = group_name })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return h.intField(gpa, resp, "group_id");
    }

    /// 对应 `WxMpGuideServiceImpl#getGuideGroupList`(impl:162-168):new JsonObject()。
    pub fn getGuideGroupList(self: *GuideService, io: std.Io) WxResult([]u8) {
        return self.postEmpty(io, .guide_group_list);
    }

    /// 对应 `WxMpGuideServiceImpl#getGroupInfo`(impl:170-175)。
    pub fn getGroupInfo(self: *GuideService, io: std.Io, group_id: i64, page: i64, num: i64) WxResult([]u8) {
        return self.post(io, .guide_group_info, .{ .group_id = group_id, .page = page, .num = num });
    }

    /// 对应 `WxMpGuideServiceImpl#addGuide2GuideGroup`(impl:177-181)。
    pub fn addGuide2GuideGroup(self: *GuideService, io: std.Io, group_id: i64, account: []const u8) Done {
        return self.postDone(io, .guide_add_to_group, .{ .group_id = group_id, .guide_account = account });
    }

    /// 对应 `WxMpGuideServiceImpl#delGuide2GuideGroup`(impl:183-187)。
    pub fn delGuide2GuideGroup(self: *GuideService, io: std.Io, group_id: i64, account: []const u8) Done {
        return self.postDone(io, .guide_del_from_group, .{ .group_id = group_id, .guide_account = account });
    }

    /// 对应 `WxMpGuideServiceImpl#getGroupByGuide`(impl:189-196):{"guide_account"}。
    pub fn getGroupByGuide(self: *GuideService, io: std.Io, account: []const u8) WxResult([]u8) {
        return self.post(io, .guide_group_by_guide, .{ .guide_account = account });
    }

    /// 对应 `WxMpGuideServiceImpl#delGuideGroup`(impl:198-202):{"group_id"}。
    pub fn delGuideGroup(self: *GuideService, io: std.Io, group_id: i64) Done {
        return self.postDone(io, .guide_del_group, .{ .group_id = group_id });
    }

    /// 对应 `WxMpGuideServiceImpl#setGuideConfig`(impl:93-113):
    /// body 为 LinkedHashMap,字段顺序 guide_account / guide_openid / is_delete /
    /// guide_fast_reply_list / guide_auto_reply / guide_auto_reply_plus。
    /// WxGsonBuilder.create() 未 serializeNulls,null 值与 bean 的 null 字段均被 Gson
    /// 省略,故可选参数为 null 时 omit 对应 key(契约测试用全非空入参固定结构)。
    pub fn setGuideConfig(
        self: *GuideService,
        io: std.Io,
        account: []const u8,
        openid: []const u8,
        is_delete: bool,
        guide_fast_reply_list: ?[]const []const u8,
        guide_auto_reply: ?GuideAutoReply,
        guide_auto_reply_plus: ?GuideAutoReply,
    ) Done {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("guide_account", account) catch return oom(gpa);
        ob.putStr("guide_openid", openid) catch return oom(gpa);
        ob.putBool("is_delete", is_delete) catch return oom(gpa);
        if (guide_fast_reply_list) |list| {
            const v = fastReplyArray(a, list) catch return oom(gpa);
            ob.putValue("guide_fast_reply_list", v) catch return oom(gpa);
        }
        if (guide_auto_reply) |r| {
            const v = autoReplyValue(a, r) catch return oom(gpa);
            ob.putValue("guide_auto_reply", v) catch return oom(gpa);
        }
        if (guide_auto_reply_plus) |r| {
            const v = autoReplyValue(a, r) catch return oom(gpa);
            ob.putValue("guide_auto_reply_plus", v) catch return oom(gpa);
        }
        const body = ob.toJson() catch return oom(gpa);
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.guide_set_config.asUri(), body);
    }

    /// 对应 `WxMpGuideServiceImpl#setGuideAcctConfig`(impl:121-142):
    /// GsonHelper.buildJsonObject("is_delete", isDelete, "black_keyword", jsonObject1,
    /// "guide_auto_reply", jsonObject2)。blackKeyWord 非空 → {"values":[..]};
    /// guideAutoReply 非 null → {"content":..};否则该字段为 null(被 Gson 省略)。
    pub fn setGuideAcctConfig(
        self: *GuideService,
        io: std.Io,
        is_delete: bool,
        black_keyword: ?[]const []const u8,
        guide_auto_reply: ?[]const u8,
    ) Done {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putBool("is_delete", is_delete) catch return oom(gpa);
        if (black_keyword) |kw| {
            if (kw.len > 0) { // Java: blackKeyWord != null && !blackKeyWord.isEmpty()
                var arr: std.ArrayList(json_util.Value) = .empty;
                for (kw) |s| arr.append(a, .{ .string = s }) catch return oom(gpa);
                var o: json_util.ObjectMap = .empty;
                o.put(a, "values", .{ .array = arr }) catch return oom(gpa);
                ob.putValue("black_keyword", .{ .object = o }) catch return oom(gpa);
            }
        }
        if (guide_auto_reply) |reply| {
            var o: json_util.ObjectMap = .empty;
            o.put(a, "content", .{ .string = reply }) catch return oom(gpa);
            ob.putValue("guide_auto_reply", .{ .object = o }) catch return oom(gpa);
        }
        const body = ob.toJson() catch return oom(gpa);
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.guide_set_acct_config.asUri(), body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:17 端点 URL/method/请求体 + 明确 get(...) 的响应字段
// (逐字对照 WxMpApiUrl.Guide + WxMpGuideServiceImpl)
// ---------------------------------------------------------------------------

test "Guide 契约: 17 端点 URL/method/请求体 + 响应字段 (WxMpApiUrl.Guide)" {
    const gpa = testing.allocator;
    // 一个兜底响应服务全部端点:errcode=0 有效;含 createGuideQrCode 的
    // "qrcode_url"、newGuideGroup 的 "group_id"、getGuideGroupList 的
    // "group_list"、getGroupByGuide 的 "group_id_list"(均为 impl 里出现的字段名)。
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/", .response = "{\"errcode\":0,\"qrcode_url\":\"QRURL\",\"group_id\":77,\"group_list\":[{\"group_id\":1}],\"group_id_list\":[1,2]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 ADD_GUIDE: guide_account/guide_headimgurl/guide_nickname/guide_openid
    switch (svc.addGuide(io, "ACC", "OPEN", "IMG", "NICK")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideAdd;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguideacct") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_headimgurl\":\"IMG\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_nickname\":\"NICK\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_openid\":\"OPEN\"") != null);

    // 2 UPDATE_GUIDE: 同 body
    switch (svc.updateGuide(io, "ACC", "OPEN", "IMG2", "NICK2")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideUpdate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/updateguideacct") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_nickname\":\"NICK2\"") != null);

    // 3 GET_GUIDE: {"guide_account","guide_openid"} → 原样返回
    switch (svc.getGuide(io, "ACC", "OPEN")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "qrcode_url") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguideacct?") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_openid\":\"OPEN\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "guide_headimgurl") == null); // getGuide 不放头像字段

    // 4 DEL_GUIDE
    switch (svc.delGuide(io, "ACC", "OPEN")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDel;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguideacct") != null);

    // 5 LIST_GUIDE: {"page","num"}
    switch (svc.listGuide(io, 2, 20)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"errcode\":0") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguideacctlist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page\":2") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"num\":20") != null);

    // 6 CREATE_QR_CODE: {"guide_account","guide_openid","qrcode_info"} → qrcode_url
    switch (svc.createGuideQrCode(io, "ACC", "OPEN", "INFO")) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expectEqualStrings("QRURL", u);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideQrcode;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/guidecreateqrcode") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"qrcode_info\":\"INFO\"") != null);

    // 7 GET_GUIDE_CHAT_RECORD: 7 字段(注意无 client_openid,逐字对齐 Java)
    switch (svc.getGuideChatRecord(io, "ACC", "OPEN", 100, 200, 1, 10)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideChat;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidebuyerchatrecord") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"begin_time\":100") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"end_time\":200") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"num\":10") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "client_openid") == null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "clientOpenid") == null);

    // 8 GET_GUIDE_CONFIG
    switch (svc.getGuideConfig(io, "ACC", "OPEN")) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGetConfig;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguideconfig") != null);

    // 9 GET_GUIDE_ACCT_CONFIG: body = "{}" (new JsonObject())
    switch (svc.getGuideAcctConfig(io)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGetAcctConfig;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguideacctconfig") != null);
    try testing.expectEqualStrings("{}", mock.body());

    // 10 PUSH_SHOW_WX_PATH_MENU: {"wxa_appid","wx_username"}
    switch (svc.pushShowWxaPathMenu(io, "APPID", "USER")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideWxaPath;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/pushshowwxapathmenu") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"wxa_appid\":\"APPID\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"wx_username\":\"USER\"") != null);

    // 11 NEW_GUIDE_GROUP: {"group_name"} → group_id (Long)
    switch (svc.newGuideGroup(io, "G1")) {
        .ok => |id| try testing.expectEqual(@as(i64, 77), id),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideNewGroup;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/newguidegroup") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"group_name\":\"G1\"") != null);

    // 12 GET_GUIDE_GROUP_LIST: body "{}",响应含 "group_list" 字段名
    switch (svc.getGuideGroupList(io)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"group_list\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGroupList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidegrouplist") != null);
    try testing.expectEqualStrings("{}", mock.body());

    // 13 GET_GROUP_GUIDE_INFO: {"group_id","page","num"}
    switch (svc.getGroupInfo(io, 5, 1, 10)) {
        .ok => |raw| gpa.free(raw),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGroupInfo;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getgroupinfo") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"group_id\":5") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"page\":1") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"num\":10") != null);

    // 14 ADD_GROUP_GUIDE: {"group_id","guide_account"}
    switch (svc.addGuide2GuideGroup(io, 5, "ACC")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideAddToGroup;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguide2guidegroup") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"group_id\":5") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);

    // 15 DEL_GROUP_GUIDE
    switch (svc.delGuide2GuideGroup(io, 5, "ACC")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDelFromGroup;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguide2guidegroup") != null);

    // 16 GET_GROUP_ON_GUIDE: {"guide_account"},响应含 "group_id_list" 字段名
    switch (svc.getGroupByGuide(io, "ACC")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"group_id_list\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGroupByGuide;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getgroupbyguide") != null);
    try testing.expectEqualStrings("{\"guide_account\":\"ACC\"}", mock.body());

    // 17 DEL_GROUP: {"group_id"}
    switch (svc.delGuideGroup(io, 5)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDelGroup;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidegroup") != null);
    try testing.expectEqualStrings("{\"group_id\":5}", mock.body());

    // 全 17 个端点确实各发了一次 POST
    try testing.expectEqual(@as(usize, 17), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}

// ---------------------------------------------------------------------------
// 契约测试:本轮新增 2 个 set*(嵌套对象)端点 URL/method/请求体字段名
// (逐字对照 WxMpApiUrl.Guide + WxMpGuideServiceImpl + WxMpAddGuideAutoReply)
// ---------------------------------------------------------------------------

test "Guide set* 契约: setGuideConfig / setGuideAcctConfig (嵌套对象)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 SET_GUIDE_CONFIG 全非空:严格断言 6 个字段名与嵌套结构
    const fast = [_][]const u8{ "R1", "R2" };
    switch (svc.setGuideConfig(io, "ACC", "OPEN", false, &fast, .{ .content = "WELCOME", .msgtype = 1 }, .{ .content = "PLUS", .msgtype = 2 })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetConfig;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/setguideconfig") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_openid\":\"OPEN\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_delete\":false") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_fast_reply_list\":[{\"content\":\"R1\"},{\"content\":\"R2\"}]") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_auto_reply\":{\"content\":\"WELCOME\",\"msgtype\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_auto_reply_plus\":{\"content\":\"PLUS\",\"msgtype\":2}") != null);

    // 2 SET_GUIDE_CONFIG 可选参数为 null / bean 的 msgtype 为 null:Gson 省略 null 字段
    switch (svc.setGuideConfig(io, "ACC", "OPEN", true, null, .{ .content = "ONLY" }, .{ .content = "ONLY2" })) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetConfigNull;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_delete\":true") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_auto_reply\":{\"content\":\"ONLY\"}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_auto_reply_plus\":{\"content\":\"ONLY2\"}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "msgtype") == null); // null 字段被省略
    try testing.expect(std.mem.indexOf(u8, mock.body(), "guide_fast_reply_list") == null); // null 值被省略

    // 3 SET_GUIDE_ACCT_CONFIG 全非空
    const kw = [_][]const u8{ "K1", "K2" };
    switch (svc.setGuideAcctConfig(io, true, &kw, "OFFLINE")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetAcctConfig;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/setguideacctconfig") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_delete\":true") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"black_keyword\":{\"values\":[\"K1\",\"K2\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_auto_reply\":{\"content\":\"OFFLINE\"}") != null);

    // 4 SET_GUIDE_ACCT_CONFIG 全空:black_keyword 空数组 / guide_auto_reply null
    //   → impl 里两个嵌套 JsonObject 均未构建,故 body 不含任何 content/values 结构。
    //   (setGuideAcctConfig 走 JsonObject.toString(),其 null 成员是否写成 "key":null
    //    是 Gson 内部细节,离线不可验证,故此处不断言 key 是否出现,只断言必含
    //    is_delete 且不含嵌套对象字段;全非空入参的结构由用例 3 固定。)
    switch (svc.setGuideAcctConfig(io, true, &.{}, null)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetAcctConfigNull;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"is_delete\":true") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "content") == null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "values") == null);

    try testing.expectEqual(@as(usize, 4), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}
