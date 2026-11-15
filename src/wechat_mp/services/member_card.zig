//! 会员卡服务 —— 逐字对齐 Java `api.WxMpMemberCardService` +
//! `api.impl.WxMpMemberCardServiceImpl`,端点常量取自 `api_url.zig:MemberCard`
//! (镜像 Java `enums.WxMpApiUrl.MemberCard`,8 个常量)。
//!
//! Java 接口 9 个方法(名称逐字对齐,impl:43-262):
//!   createMemberCard(createJson)
//!                       POST card/create(轻校验 card_type==MEMBER_CARD)
//!                       → {errcode,errmsg,card_id}(WxMpCardCreateResult)
//!   activateMemberCard(activatedMessage)
//!                       POST card/membercard/activate,**请求体由调用方传原始 JSON**
//!                       (Java 传 bean 由 Gson 序列化;复杂 bean 不在 Zig 建模)
//!   getUserInfo(cardId,code)
//!                       POST card/membercard/userinfo/get {"card_id","code"}
//!                       → openid/nickname/membership_number/bonus/balance/sex/
//!                         user_card_status/has_active + user_info{common/custom}
//!   updateUserMemberCard(updateMessage)
//!                       POST card/membercard/updateuser(原始 JSON)
//!                       → {result_bonus,result_balance,openid,...}
//!   setActivateUserForm(userFormRequest)
//!                       POST card/membercard/activateuserform/set(原始 JSON)
//!   getActivatePluginUrl(cardId,outStr)
//!                       POST card/membercard/activate/geturl {"card_id","outer_str"}
//!                       → url
//!   getActivatePluginParam(cardId,outStr)
//!                       = getActivatePluginUrl 后解析 URL query
//!                         (encrypt_card_id/outer_str/biz,Java 给 biz 补 "==")
//!   updateCardInfo(memberCardUpdateRequest)
//!                       POST card/update(原始 JSON)→ {errcode,errmsg,send_check}
//!   getActivateTempInfo(activateTicket)
//!                       POST card/membercard/activatetempinfo/get {"activate_ticket"}
//!                       → info{common_field_list,custom_field_list}
//!
//! Java↔Zig 差异:
//!   - `createMemberCard` 的 15+ 项 validCheck(Java 校验 bean 各字段)→ Zig 入参是
//!     原始 JSON,只做轻校验:根对象 card.card_type=="MEMBER_CARD" 子集存在;
//!     深度校验由调用方保证(与 Java 行为的差异在 header 声明);
//!   - Java bean 字段名与真实响应**不符**处逐字保留真实字段:WxMpMemberCardUserInfoResult
//!     的 openId/errorCode(Gson 适配器实际读 openid/errcode)、ActivateTempInfo 的
//!     userInfo(适配器实际读 info);
//!   - WxMpCardCreateResult.failure(校验失败)→ Zig 用 WxError.configError 折叠
//!     (errcode=500 语义对应 config 错误);
//!   - 原始 JSON 入参的方法(activate/update/setActivateUserForm/updateCardInfo):
//!     Java 收 bean 对象,由 Gson 序列化;Zig 收已序列化的 JSON 字符串,复杂 bean
//!     (激活表单/更新请求,10+ 字段嵌套)不建模,调用方自行组包。
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

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

/// 取数值字段为 f64(bonus/balance 等 Double 字段;整数/浮点都收)。
fn getFloatOr(v: json_util.Value, key: []const u8, default: f64) f64 {
    const o = json_util.object(v) orelse return default;
    const c = o.get(key) orelse return default;
    return switch (c) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch default,
        else => default,
    };
}

/// 建卡结果 —— 对应 `WxMpCardCreateResult`{errcode,errmsg,card_id}。
pub const CardCreateResult = struct {
    gpa: std.mem.Allocator,
    errcode: i64 = 0,
    errmsg: []u8,
    card_id: []u8,

    pub fn deinit(self: *CardCreateResult) void {
        self.gpa.free(self.errmsg);
        self.gpa.free(self.card_id);
        self.* = undefined;
    }
};

/// name→value 字段对 —— 对应 `NameValues`(common/custom_field_list 元素)。
pub const NameValue = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    value: []u8,

    pub fn deinit(self: *NameValue) void {
        self.gpa.free(self.name);
        self.gpa.free(self.value);
        self.* = undefined;
    }
};

/// 会员卡用户信息 —— 对应真实响应的 user_info{common_field_list,custom_field_list}。
pub const MemberUserInfo = struct {
    gpa: std.mem.Allocator,
    common_field_list: []NameValue = &.{},
    custom_field_list: []NameValue = &.{},

    pub fn deinit(self: *MemberUserInfo) void {
        for (self.common_field_list) |*nv| nv.deinit();
        if (self.common_field_list.len > 0) self.gpa.free(self.common_field_list);
        for (self.custom_field_list) |*nv| nv.deinit();
        if (self.custom_field_list.len > 0) self.gpa.free(self.custom_field_list);
        self.* = undefined;
    }
};

/// 会员卡用户信息结果 —— 对应 `WxMpMemberCardUserInfoResult`(真实响应字段,
/// Java bean 的 openId/errorCode 驼峰与响应不符,此处按响应原词)。
pub const UserInfoResult = struct {
    gpa: std.mem.Allocator,
    openid: []u8,
    nickname: []u8,
    membership_number: []u8,
    bonus: i64 = 0,
    balance: f64 = 0,
    sex: []u8,
    user_card_status: []u8,
    has_active: bool = false,
    user_info: MemberUserInfo,

    pub fn deinit(self: *UserInfoResult) void {
        self.gpa.free(self.openid);
        self.gpa.free(self.nickname);
        self.gpa.free(self.membership_number);
        self.gpa.free(self.sex);
        self.gpa.free(self.user_card_status);
        self.user_info.deinit();
        self.* = undefined;
    }
};

/// 更新会员卡结果 —— 对应 `WxMpMemberCardUpdateResult`(真实响应字段)。
pub const UpdateUserResult = struct {
    gpa: std.mem.Allocator,
    openid: []u8,
    result_bonus: i64 = 0,
    result_balance: f64 = 0,

    pub fn deinit(self: *UpdateUserResult) void {
        self.gpa.free(self.openid);
        self.* = undefined;
    }
};

/// 更新会员卡信息结果 —— 对应 `CardUpdateResult`{errcode,errmsg,send_check}。
pub const CardUpdateResult = struct {
    gpa: std.mem.Allocator,
    errcode: i64 = 0,
    errmsg: []u8,
    send_check: bool = false,

    pub fn deinit(self: *CardUpdateResult) void {
        self.gpa.free(self.errmsg);
        self.* = undefined;
    }
};

/// 激活插件参数 —— 对应 `ActivatePluginParam`(encrypt_card_id/outer_str/biz)。
pub const ActivatePluginParam = struct {
    gpa: std.mem.Allocator,
    encrypt_card_id: []u8,
    outer_str: []u8,
    biz: []u8,

    pub fn deinit(self: *ActivatePluginParam) void {
        self.gpa.free(self.encrypt_card_id);
        self.gpa.free(self.outer_str);
        self.gpa.free(self.biz);
        self.* = undefined;
    }
};

/// 激活临时信息 —— 对应 `WxMpMemberCardActivateTempInfoResult`(适配器读 info)。
pub const ActivateTempInfoResult = struct {
    gpa: std.mem.Allocator,
    info: MemberUserInfo,

    pub fn deinit(self: *ActivateTempInfoResult) void {
        self.info.deinit();
        self.* = undefined;
    }
};

/// 解析 name→value 列表(common/custom_field_list)。
fn parseNameValues(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) WxResult([]NameValue) {
    var list: std.ArrayList(NameValue) = .empty;
    errdefer {
        for (list.items) |*it| it.deinit();
        list.deinit(gpa);
    }
    if (json_util.getArray(v, key)) |arr| {
        for (arr.items) |item| {
            var nv = NameValue{
                .gpa = gpa,
                .name = gpa.dupe(u8, json_util.getStrOr(item, "name", "")) catch
                    return .{ .err = oom(gpa) },
                .value = gpa.dupe(u8, json_util.getStrOr(item, "value", "")) catch
                    return .{ .err = oom(gpa) },
            };
            errdefer nv.deinit();
            list.append(gpa, nv) catch return .{ .err = oom(gpa) };
        }
    }
    return .{ .ok = list.toOwnedSlice(gpa) catch return .{ .err = oom(gpa) } };
}

/// 解析 user_info/info 壳里的 common/custom 字段列表。
fn parseMemberUserInfo(gpa: std.mem.Allocator, v: json_util.Value) WxResult(MemberUserInfo) {
    var ui = MemberUserInfo{ .gpa = gpa };
    ui.common_field_list = switch (parseNameValues(gpa, v, "common_field_list")) {
        .ok => |l| l,
        .err => |e| return .{ .err = e },
    };
    ui.custom_field_list = switch (parseNameValues(gpa, v, "custom_field_list")) {
        .ok => |l| l,
        .err => |e| {
            for (ui.common_field_list) |*nv| nv.deinit();
            if (ui.common_field_list.len > 0) gpa.free(ui.common_field_list);
            return .{ .err = e };
        },
    };
    return .{ .ok = ui };
}

pub const MemberCardService = struct {
    svc: *service_mod.Service,

    /// 对应 `#createMemberCard(String)`(impl:43-58):轻校验
    /// (card.card_type 存在且为 MEMBER_CARD 的子集)→ POST card/create。
    /// Java 的 15+ 项 validCheck 针对 bean 字段;Zig 入参是原始 JSON,
    /// 只做 card_type 校验,深度校验由调用方保证。
    pub fn createMemberCard(self: *MemberCardService, io: std.Io, create_json: []const u8) WxResult(CardCreateResult) {
        const gpa = self.svc.gpa;
        const parsed = json_util.parse(gpa, create_json) catch
            return .{ .err = WxError.configError(gpa, "createJson 不是合法 JSON", .{}) };
        defer parsed.deinit();
        const card = json_util.getObject(parsed.value, "card") orelse
            return .{ .err = WxError.configError(gpa, "会员卡对象 card 不能为空", .{}) };
        const card_type = json_util.getStrOr(card, "card_type", "");
        if (!std.mem.eql(u8, card_type, "MEMBER_CARD"))
            return .{ .err = WxError.configError(gpa, "卡券类型必须等于MEMBER_CARD", .{}) };

        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_create, create_json)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const rp = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "card/create response not json", .{}) };
        defer rp.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .errcode = json_util.getIntOr(rp.value, "errcode", 0),
            .errmsg = gpa.dupe(u8, json_util.getStrOr(rp.value, "errmsg", "")) catch
                return .{ .err = oom(gpa) },
            .card_id = gpa.dupe(u8, json_util.getStrOr(rp.value, "card_id", "")) catch
                return .{ .err = oom(gpa) },
        } };
    }

    /// 对应 `#activateMemberCard`(impl:132-134):POST activate,**原始 JSON 入参**
    /// (Java 收 WxMpMemberCardActivatedMessage bean)。响应原样返回(gpa 拥有)。
    pub fn activateMemberCard(self: *MemberCardService, io: std.Io, activated_json: []const u8) WxResult([]u8) {
        return h.apiPost(self.svc, io, api_url.MemberCard.member_card_activate, activated_json);
    }

    /// 对应 `#getUserInfo`(impl:136-146):POST {"card_id","code"} → 真实响应字段
    /// (Java bean 的 openId/errorCode 驼峰与响应不符,适配器实际读 openid/errcode,
    ///  此处按响应原词解析)。
    pub fn getUserInfo(self: *MemberCardService, io: std.Io, card_id: []const u8, code: []const u8) WxResult(UserInfoResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("card_id", card_id) catch return .{ .err = oom(gpa) };
        ob.putStr("code", code) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_user_info_get, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "userinfo/get response not json", .{}) };
        defer parsed.deinit();
        var r = UserInfoResult{
            .gpa = gpa,
            .openid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "openid", "")) catch
                return .{ .err = oom(gpa) },
            .nickname = gpa.dupe(u8, json_util.getStrOr(parsed.value, "nickname", "")) catch
                return .{ .err = oom(gpa) },
            .membership_number = gpa.dupe(u8, json_util.getStrOr(parsed.value, "membership_number", "")) catch
                return .{ .err = oom(gpa) },
            .bonus = json_util.getIntOr(parsed.value, "bonus", 0),
            .balance = getFloatOr(parsed.value, "balance", 0),
            .sex = gpa.dupe(u8, json_util.getStrOr(parsed.value, "sex", "")) catch
                return .{ .err = oom(gpa) },
            .user_card_status = gpa.dupe(u8, json_util.getStrOr(parsed.value, "user_card_status", "")) catch
                return .{ .err = oom(gpa) },
            .has_active = json_util.getBool(parsed.value, "has_active") orelse false,
            .user_info = .{ .gpa = gpa },
        };
        errdefer r.deinit();
        if (json_util.getObject(parsed.value, "user_info")) |uiv| {
            r.user_info = switch (parseMemberUserInfo(gpa, uiv)) {
                .ok => |ui| ui,
                .err => |e| return .{ .err = e },
            };
        }
        return .{ .ok = r };
    }

    /// 对应 `#updateUserMemberCard`(impl:148-157):POST updateuser(原始 JSON)
    /// → result_bonus/result_balance/openid(真实响应字段)。
    pub fn updateUserMemberCard(self: *MemberCardService, io: std.Io, update_json: []const u8) WxResult(UpdateUserResult) {
        const gpa = self.svc.gpa;
        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_update_user, update_json)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "updateuser response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .openid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "openid", "")) catch
                return .{ .err = oom(gpa) },
            .result_bonus = json_util.getIntOr(parsed.value, "result_bonus", 0),
            .result_balance = getFloatOr(parsed.value, "result_balance", 0),
        } };
    }

    /// 对应 `#setActivateUserForm`(impl:159-162):POST activateuserform/set
    /// (原始 JSON;Java 收 MemberCardActivateUserFormRequest bean)。
    pub fn setActivateUserForm(self: *MemberCardService, io: std.Io, user_form_json: []const u8) WxResult([]u8) {
        return h.apiPost(self.svc, io, api_url.MemberCard.member_card_activate_user_form, user_form_json);
    }

    /// 对应 `#getActivatePluginUrl`(impl:177-190):
    /// POST {"card_id","outer_str"} → url。
    pub fn getActivatePluginUrl(self: *MemberCardService, io: std.Io, card_id: []const u8, outer_str: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("card_id", card_id) catch return .{ .err = oom(gpa) };
        ob.putStr("outer_str", outer_str) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_activate_url, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "activate/geturl response not json", .{}) };
        defer parsed.deinit();
        const url = json_util.getStr(parsed.value, "url") orelse
            return .{ .err = WxError.transport(gpa, "activate/geturl response missing url", .{}) };
        return .{ .ok = gpa.dupe(u8, url) catch return .{ .err = oom(gpa) } };
    }

    /// 对应 `#getActivatePluginParam`(impl:168-175):取激活插件 URL 后解析
    /// query(encrypt_card_id/outer_str/biz;Java 给 biz 追加 "==")。
    pub fn getActivatePluginParam(self: *MemberCardService, io: std.Io, card_id: []const u8, outer_str: []const u8) WxResult(ActivatePluginParam) {
        const gpa = self.svc.gpa;
        const url = switch (self.getActivatePluginUrl(io, card_id, outer_str)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(url);
        // 解析 URL query:取 '?' 后按 '&' 分段、'=' 切 k=v(对应 Java parseRequestUrl)
        const q = if (std.mem.indexOfScalar(u8, url, '?')) |i| url[i + 1 ..] else "";
        var enc: []u8 = &.{};
        var out: []u8 = &.{};
        var biz: []u8 = &.{};
        var it = std.mem.splitScalar(u8, q, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "encrypt_card_id")) {
                enc = gpa.dupe(u8, v) catch return .{ .err = oom(gpa) };
            } else if (std.mem.eql(u8, k, "outer_str")) {
                out = gpa.dupe(u8, v) catch return .{ .err = oom(gpa) };
            } else if (std.mem.eql(u8, k, "biz")) {
                // Java:biz = resultMap.get("biz") + "=="
                const with_eq = std.fmt.allocPrint(gpa, "{s}==", .{v}) catch
                    return .{ .err = oom(gpa) };
                biz = with_eq;
            }
        }
        if (enc.len == 0 and out.len == 0 and biz.len == 0)
            return .{ .err = WxError.transport(gpa, "activate url missing params", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .encrypt_card_id = enc,
            .outer_str = out,
            .biz = biz,
        } };
    }

    /// 对应 `#updateCardInfo`(impl:192-195):POST card/update(原始 JSON)
    /// → {errcode,errmsg,send_check}。
    pub fn updateCardInfo(self: *MemberCardService, io: std.Io, update_json: []const u8) WxResult(CardUpdateResult) {
        const gpa = self.svc.gpa;
        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_update, update_json)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "card/update response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .errcode = json_util.getIntOr(parsed.value, "errcode", 0),
            .errmsg = gpa.dupe(u8, json_util.getStrOr(parsed.value, "errmsg", "")) catch
                return .{ .err = oom(gpa) },
            .send_check = json_util.getBool(parsed.value, "send_check") orelse false,
        } };
    }

    /// 对应 `#getActivateTempInfo`(impl:197-202):POST {"activate_ticket"}
    /// → info{common_field_list,custom_field_list}(适配器读 info,非 user_info)。
    pub fn getActivateTempInfo(self: *MemberCardService, io: std.Io, activate_ticket: []const u8) WxResult(ActivateTempInfoResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("activate_ticket", activate_ticket) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.MemberCard.member_card_activate_temp_info, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "activatetempinfo/get response not json", .{}) };
        defer parsed.deinit();
        const info = json_util.getObject(parsed.value, "info") orelse
            return .{ .err = WxError.transport(gpa, "activatetempinfo/get response missing info", .{}) };
        const ui = switch (parseMemberUserInfo(gpa, info)) {
            .ok => |u| u,
            .err => |e| return .{ .err = e },
        };
        return .{ .ok = .{ .gpa = gpa, .info = ui } };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:8 端点 URL/method/请求体 + card_type 校验 + query 参数解析
// (逐字对照 WxMpApiUrl.MemberCard + WxMpMemberCardServiceImpl)
// ---------------------------------------------------------------------------

test "MemberCard 契约: create 校验 + activate/getUserInfo/updateUser (WxMpApiUrl.MemberCard)" {
    const gpa = testing.allocator;
    const create_json = "{\"card\":{\"card_type\":\"MEMBER_CARD\",\"member_card\":{\"prerogative\":\"特权\"}}}";
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"card_id\":\"p1QsrV0000\"}" },
        .{ .match = "card/membercard/activate", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "card/membercard/userinfo/get", .response = "{\"errcode\":0,\"openid\":\"oX\",\"nickname\":\"小明\",\"membership_number\":\"NO1\",\"bonus\":100,\"balance\":50,\"sex\":\"MALE\",\"user_card_status\":\"NORMAL\",\"has_active\":true,\"user_info\":{\"common_field_list\":[{\"name\":\"LEVEL\",\"value\":\"钻石\"}],\"custom_field_list\":[]}}" },
        .{ .match = "card/membercard/updateuser", .response = "{\"errcode\":0,\"openid\":\"oX\",\"result_bonus\":200,\"result_balance\":150}" },
        .{ .match = "card/membercard/activateuserform/set", .response = "{\"errcode\":0}" },
        .{ .match = "card/membercard/activate/geturl", .response = "{\"errcode\":0,\"url\":\"https://mp.weixin.qq.com/bizmall/activatemembercard?encrypt_card_id=ENC1&outer_str=bill&biz=BMQ\"}" },
        .{ .match = "card/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"send_check\":true}" },
        .{ .match = "card/membercard/activatetempinfo/get", .response = "{\"errcode\":0,\"info\":{\"common_field_list\":[{\"name\":\"LEVEL\",\"value\":\"钻石\"}],\"custom_field_list\":[{\"name\":\"PHONE\",\"value\":\"13800000000\"}]}}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = MemberCardService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // createMemberCard: 轻校验 + {"card_id"}
    switch (svc.createMemberCard(io, create_json)) {
        .ok => |*r| {
            var c = r.*;
            defer c.deinit();
            try testing.expectEqual(@as(i64, 0), c.errcode);
            try testing.expectEqualStrings("p1QsrV0000", c.card_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardCreate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/create") != null);
    // createMemberCard: card_type 非 MEMBER_CARD → 本地 configError(不发请求)
    const calls_before = mock.calls;
    switch (svc.createMemberCard(io, "{\"card\":{\"card_type\":\"GENERAL Coupon\"}}")) {
        .ok => return error.MemberCardCreateShouldFail,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expect(std.mem.indexOf(u8, err.error_msg, "MEMBER_CARD") != null);
        },
    }
    try testing.expectEqual(calls_before, mock.calls);

    // activateMemberCard: 原始 JSON 透传
    switch (svc.activateMemberCard(io, "{\"membership_number\":\"NO1\",\"code\":\"CODE1\"}")) {
        .ok => |b| {
            defer gpa.free(b);
            try testing.expect(std.mem.indexOf(u8, b, "ok") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardActivate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/activate") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"membership_number\":\"NO1\"") != null);

    // getUserInfo: {"card_id","code"} → 真实响应字段
    switch (svc.getUserInfo(io, "p1QsrV0000", "CODE1")) {
        .ok => |*r| {
            var u = r.*;
            defer u.deinit();
            try testing.expectEqualStrings("oX", u.openid);
            try testing.expectEqualStrings("小明", u.nickname);
            try testing.expectEqualStrings("NO1", u.membership_number);
            try testing.expectEqual(@as(i64, 100), u.bonus);
            try testing.expect(u.has_active);
            try testing.expectEqual(@as(usize, 1), u.user_info.common_field_list.len);
            try testing.expectEqualStrings("钻石", u.user_info.common_field_list[0].value);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardGetUserInfo;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/userinfo/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"card_id\":\"p1QsrV0000\"") != null);

    // updateUserMemberCard: 原始 JSON → result_bonus/result_balance
    switch (svc.updateUserMemberCard(io, "{\"code\":\"CODE1\",\"card_id\":\"p1QsrV0000\",\"record_bonus\":100}")) {
        .ok => |*r| {
            var u = r.*;
            defer u.deinit();
            try testing.expectEqualStrings("oX", u.openid);
            try testing.expectEqual(@as(i64, 200), u.result_bonus);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardUpdateUser;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/updateuser") != null);
}

test "MemberCard 契约: plugin url/param + updateCardInfo + activateTempInfo" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/membercard/activate/geturl", .response = "{\"errcode\":0,\"url\":\"https://mp.weixin.qq.com/bizmall/activatemembercard?encrypt_card_id=ENC1&outer_str=bill&biz=BMQ\"}" },
        .{ .match = "card/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"send_check\":true}" },
        .{ .match = "card/membercard/activatetempinfo/get", .response = "{\"errcode\":0,\"info\":{\"common_field_list\":[{\"name\":\"LEVEL\",\"value\":\"钻石\"}],\"custom_field_list\":[{\"name\":\"PHONE\",\"value\":\"13800000000\"}]}}" },
        .{ .match = "card/membercard/activateuserform/set", .response = "{\"errcode\":0}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = MemberCardService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // getActivatePluginUrl: {"card_id","outer_str"} → url
    switch (svc.getActivatePluginUrl(io, "p1QsrV0000", "bill")) {
        .ok => |u| {
            defer gpa.free(u);
            try testing.expect(std.mem.indexOf(u8, u, "encrypt_card_id=ENC1") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardPluginUrl;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/activate/geturl") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"outer_str\":\"bill\"") != null);

    // getActivatePluginParam: 解析 query(biz 补 "==")
    switch (svc.getActivatePluginParam(io, "p1QsrV0000", "bill")) {
        .ok => |*r| {
            var p = r.*;
            defer p.deinit();
            try testing.expectEqualStrings("ENC1", p.encrypt_card_id);
            try testing.expectEqualStrings("bill", p.outer_str);
            try testing.expectEqualStrings("BMQ==", p.biz);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardPluginParam;
        },
    }

    // updateCardInfo: 原始 JSON → send_check
    switch (svc.updateCardInfo(io, "{\"card_id\":\"p1QsrV0000\",\"member_card\":{\"base_info\":{}}}")) {
        .ok => |*r| {
            var u = r.*;
            defer u.deinit();
            try testing.expectEqual(@as(i64, 0), u.errcode);
            try testing.expect(u.send_check);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardUpdateCard;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/update") != null);

    // getActivateTempInfo: {"activate_ticket"} → info 壳
    switch (svc.getActivateTempInfo(io, "TICKET1")) {
        .ok => |*r| {
            var t = r.*;
            defer t.deinit();
            try testing.expectEqual(@as(usize, 1), t.info.common_field_list.len);
            try testing.expectEqualStrings("LEVEL", t.info.common_field_list[0].name);
            try testing.expectEqual(@as(usize, 1), t.info.custom_field_list.len);
            try testing.expectEqualStrings("13800000000", t.info.custom_field_list[0].value);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardTempInfo;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/activatetempinfo/get") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"activate_ticket\":\"TICKET1\"") != null);

    // setActivateUserForm: 原始 JSON 透传 → POST activateuserform/set
    switch (svc.setActivateUserForm(io, "{\"card_id\":\"p1QsrV0000\",\"user_form\":{}}")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"errcode\":0") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedMemberCardUserForm;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/membercard/activateuserform/set") != null);
    try testing.expectEqualStrings("{\"card_id\":\"p1QsrV0000\",\"user_form\":{}}", mock.body());
}
