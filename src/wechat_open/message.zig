//! 授权事件 XML 解析 —— 对应 Java `bean.message.WxOpenXmlMessage` 的**事件子集**。
//!
//! 第三方平台回调只有事件消息(无普通图文),骨架收录 `route` 真正消费的字段:
//! `AppId/CreateTime/InfoType/ComponentVerifyTicket/AuthorizerAppid/AuthorizationCode`,
//! 分派语义对应 `impl.WxOpenComponentServiceImpl.route`(ticket 推送 / 授权 / 取消授权 /
//! 更新授权,其余归 `.unknown`)。
//!
//! 所有权:解析结果所有字符串均由传入 allocator 拥有(`deinit` 释放);
//! `common.xml.parse` 的 key 借用输入报文,故在 `freeMap` 前只读取、不转存 key。
const std = @import("std");
const xml_mod = @import("common").xml;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;

pub const WxResult = result_mod.WxResult;
pub const WxError = error_mod.WxError;

/// `<InfoType>` 文本枚举。注意微信的「更新授权」拼写是 `updateauthorized`
/// (Java route 用 `equalsAnyIgnoreCase("authorized","updateauthorized")` 判别)。
pub const InfoType = enum {
    component_verify_ticket,
    authorized,
    unauthorized,
    update_authorized,
    unknown,

    pub fn fromInfoType(s: []const u8) InfoType {
        if (std.ascii.eqlIgnoreCase(s, "component_verify_ticket")) return .component_verify_ticket;
        if (std.ascii.eqlIgnoreCase(s, "authorized")) return .authorized;
        if (std.ascii.eqlIgnoreCase(s, "unauthorized")) return .unauthorized;
        if (std.ascii.eqlIgnoreCase(s, "updateauthorized")) return .update_authorized;
        return .unknown;
    }
};

/// 对应 `WxOpenXmlMessage`(事件字段子集)。所有 `[]u8` 字段由 gpa 拥有。
pub const AuthorizerEvent = struct {
    gpa: std.mem.Allocator,
    /// `<AppId>`(平台方 appid)
    app_id: []u8 = "",
    create_time: i64 = 0,
    info_type: InfoType = .unknown,
    /// 原始 `<InfoType>` 文本(unknown 时供业务自行分派)
    info_type_raw: []u8 = "",
    component_verify_ticket: ?[]u8 = null,
    authorizer_appid: ?[]u8 = null,
    authorization_code: ?[]u8 = null,

    pub fn deinit(self: *AuthorizerEvent) void {
        const g = self.gpa;
        if (self.app_id.len > 0) g.free(self.app_id);
        if (self.info_type_raw.len > 0) g.free(self.info_type_raw);
        if (self.component_verify_ticket) |s| g.free(s);
        if (self.authorizer_appid) |s| g.free(s);
        if (self.authorization_code) |s| g.free(s);
        self.* = undefined;
    }
};

/// 解析平台回调 XML(对应 `WxOpenXmlMessage.fromXml`)。
/// 非法 XML/DTD 报 `WxError.crypto`(对齐 common.xml 的 XXE 防护)。
pub fn parseAuthorizerEvent(gpa: std.mem.Allocator, xml_bytes: []const u8) WxResult(AuthorizerEvent) {
    var m = xml_mod.parse(gpa, xml_bytes) catch |e| return .{
        .err = WxError.cryptoError(gpa, "授权事件 XML 解析失败: {s}", .{@errorName(e)}),
    };
    defer xml_mod.freeMap(&m);
    const ev = extract(gpa, m) catch |e| return .{
        .err = WxError.transport(gpa, "授权事件字段拷贝失败: {s}", .{@errorName(e)}),
    };
    return .{ .ok = ev };
}

/// 测试辅助:`WxResult(AuthorizerEvent)` → 事件(失败则测试报错)。
fn unwrapEvent(r: WxResult(AuthorizerEvent)) !AuthorizerEvent {
    return switch (r) {
        .ok => |e| e,
        .err => |e| blk: {
            var x = e;
            defer x.deinit();
            break :blk error.Unexpected;
        },
    };
}

/// 从已解析的 map 提取字段(全部 dupe 给事件对象拥有)。
fn extract(gpa: std.mem.Allocator, m: xml_mod.Map) !AuthorizerEvent {
    var ev = AuthorizerEvent{ .gpa = gpa };
    errdefer ev.deinit();
    if (m.get("AppId")) |s| ev.app_id = try gpa.dupe(u8, s);
    if (m.get("CreateTime")) |s| ev.create_time = std.fmt.parseInt(i64, s, 10) catch 0; // Java Long,宽松取 0
    if (m.get("InfoType")) |s| {
        ev.info_type_raw = try gpa.dupe(u8, s);
        ev.info_type = InfoType.fromInfoType(s);
    }
    if (m.get("ComponentVerifyTicket")) |s| ev.component_verify_ticket = try gpa.dupe(u8, s);
    if (m.get("AuthorizerAppid")) |s| ev.authorizer_appid = try gpa.dupe(u8, s);
    if (m.get("AuthorizationCode")) |s| ev.authorization_code = try gpa.dupe(u8, s);
    return ev;
}

// ---------------------------------------------------------------------------

test "parse component_verify_ticket event" {
    const gpa = std.testing.allocator;
    const xml =
        \\<xml><AppId><![CDATA[wxComponentAppid]]></AppId>
        \\<CreateTime>1700000000</CreateTime>
        \\<InfoType><![CDATA[component_verify_ticket]]></InfoType>
        \\<ComponentVerifyTicket><![CDATA[ticket@@@abcdefghij]]></ComponentVerifyTicket></xml>
    ;
    const r = parseAuthorizerEvent(gpa, xml);
    var ev = switch (r) {
        .ok => |e| e,
        .err => |e| {
            var x = e;
            defer x.deinit();
            return error.Unexpected;
        },
    };
    defer ev.deinit();
    try std.testing.expectEqualStrings("wxComponentAppid", ev.app_id);
    try std.testing.expectEqual(@as(i64, 1700000000), ev.create_time);
    try std.testing.expectEqual(InfoType.component_verify_ticket, ev.info_type);
    try std.testing.expectEqualStrings("ticket@@@abcdefghij", ev.component_verify_ticket.?);
    try std.testing.expect(ev.authorizer_appid == null);
}

test "parse authorized event + unknown infotype" {
    const gpa = std.testing.allocator;
    const xml =
        \\<xml><AppId>wxComponentAppid</AppId>
        \\<CreateTime>1700000001</CreateTime>
        \\<InfoType><![CDATA[authorized]]></InfoType>
        \\<AuthorizerAppid><![CDATA[wxAuthorizerAppid]]></AuthorizerAppid>
        \\<AuthorizationCode><![CDATA[queryauthcode@@@XYZ]]></AuthorizationCode>
        \\<AuthorizationCodeExpiredTime>1700003601</AuthorizationCodeExpiredTime>
        \\<PreAuthCode><![CDATA[preauthcode@@@ABC]]></PreAuthCode></xml>
    ;
    const r = parseAuthorizerEvent(gpa, xml);
    var ev = switch (r) {
        .ok => |e| e,
        .err => |e| {
            var x = e;
            defer x.deinit();
            return error.Unexpected;
        },
    };
    defer ev.deinit();
    try std.testing.expectEqual(InfoType.authorized, ev.info_type);
    try std.testing.expectEqualStrings("wxAuthorizerAppid", ev.authorizer_appid.?);
    try std.testing.expectEqualStrings("queryauthcode@@@XYZ", ev.authorization_code.?);

    // updateauthorized → .update_authorized;未知 → .unknown(原文保留)
    const upd =
        \\<xml><AppId>wxC</AppId><InfoType>updateauthorized</InfoType><AuthorizerAppid>wxA</AuthorizerAppid><AuthorizationCode>c2</AuthorizationCode></xml>
    ;
    var e2 = try unwrapEvent(parseAuthorizerEvent(gpa, upd));
    defer e2.deinit();
    try std.testing.expectEqual(InfoType.update_authorized, e2.info_type);

    const unk = "<xml><AppId>wxC</AppId><InfoType>notify_third_fasteregister</InfoType></xml>";
    var e3 = try unwrapEvent(parseAuthorizerEvent(gpa, unk));
    defer e3.deinit();
    try std.testing.expectEqual(InfoType.unknown, e3.info_type);
    try std.testing.expectEqualStrings("notify_third_fasteregister", e3.info_type_raw);
}

test "parse rejects malformed xml and doctype" {
    const gpa = std.testing.allocator;
    const r1 = parseAuthorizerEvent(gpa, "<xml><AppId>");
    try std.testing.expect(r1.failed());
    var e1 = r1.err;
    defer e1.deinit();

    const r2 = parseAuthorizerEvent(gpa, "<!DOCTYPE foo><xml></xml>");
    try std.testing.expect(r2.failed());
    var e2 = r2.err;
    defer e2.deinit();
    try std.testing.expectEqual(WxError.Source.crypto, e2.source);
}
