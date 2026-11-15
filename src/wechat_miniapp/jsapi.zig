//! 小程序 JSAPI 服务 —— 对应 Java `api.WxMaJsapiService` +
//! `api.impl.WxMaJsapiServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Jsapi`:
//! - jsapi_ticket:`GET /cgi-bin/ticket/getticket?type=jsapi`(基座 Service 的
//!   jsapi 票槽已实现该协议,直接委托);
//! - card 票:`GET /cgi-bin/ticket/getticket?type=wx_card`,独立槽位(与 Java
//!   多票槽等价:各票独立缓存/刷新)。
//! - 签名:`createJsapiSignature` = SHA1(jsapi_ticket+noncestr+timestamp+url),
//!   委托基座 `Service.createJsapiSignature`(基座经带缓存的 acquireJsapiTicket 取票)。
//!
//! 票类型枚举与 mp `jssdk.zig` 的 TicketType 口径一致(jsapi/sdk/wx_card);
//! 小程序只用 jsapi 与 wx_card,保留三值以复用同一枚举。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
const WxError = error_mod.WxError;

/// 票类型码(与 mp jssdk 的 TicketType.code 口径一致)。
pub const TicketType = enum {
    jsapi,
    sdk,
    wx_card,

    pub fn code(self: TicketType) []const u8 {
        return switch (self) {
            .jsapi => "jsapi",
            .sdk => "2",
            .wx_card => "wx_card",
        };
    }
};

/// `getTicket` 响应解析(对应 Java 取 ticket/expires_in)。ticket 由 gpa 拥有。
pub const Ticket = struct {
    gpa: std.mem.Allocator,
    ticket: []u8,
    expires_in: i64,

    pub fn deinit(self: *Ticket) void {
        self.gpa.free(self.ticket);
    }
};

const GET_TICKET_URL = "https://api.weixin.qq.com/cgi-bin/ticket/getticket";

/// JSAPI 服务 —— 组合在服务基座上(对应 `WxMaJsapiServiceImpl` 持有
/// `WxMaService` 引用的组合方式)。
pub const JsapiService = struct {
    svc: *mp_service.Service,

    /// 对应 `getCardApiTicket()` → `getTicket(TicketType.wx_card)`:
    /// GET /cgi-bin/ticket/getticket?type=wx_card。
    pub fn get_card_api_ticket(self: *JsapiService, io: std.Io) WxResult(Ticket) {
        return self.getTicket(io, .wx_card);
    }

    /// 对应 `getJsapiTicket()` → `getTicket(TicketType.jsapi)`。
    pub fn get_jsapi_ticket(self: *JsapiService, io: std.Io) WxResult(Ticket) {
        return self.getTicket(io, .jsapi);
    }

    /// 通用取票:`GET /cgi-bin/ticket/getticket?type=<code>`。
    /// 对应 Java `service.get(GET_JSAPI_TICKET_URL + "?type=" + code, null)`。
    fn getTicket(self: *JsapiService, io: std.Io, t: TicketType) WxResult(Ticket) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_TICKET_URL, &.{
            .{ .key = "type", .value = t.code() },
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getticket 响应非 JSON", .{}) };
        defer parsed.deinit();

        const src = json_util.getStr(parsed.value, "ticket") orelse
            return .{ .err = WxError.transport(gpa, "getticket 响应缺少 ticket", .{}) };
        const ticket = gpa.dupe(u8, src) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        errdefer gpa.free(ticket);
        const expires_in = json_util.getInt(parsed.value, "expires_in") orelse 7200;
        return .{ .ok = .{ .gpa = gpa, .ticket = ticket, .expires_in = expires_in } };
    }

    /// 对应 `createJsapiSignature(String url)`:委托基座(随机 nonce+墙钟秒)。
    /// 返回值 gpa 拥有,调用方 `deinit()`。
    pub fn create_jsapi_signature(self: *JsapiService, io: std.Io, url: []const u8) WxResult(mp_service.Service.JsapiSignature) {
        return self.svc.createJsapiSignature(io, url, null);
    }

    /// 注入 nonce/timestamp 的签名(测试确定向量用)。
    pub fn create_jsapi_signature_injected(
        self: *JsapiService,
        io: std.Io,
        url: []const u8,
        nonce_str: []const u8,
        timestamp: i64,
    ) WxResult(mp_service.Service.JsapiSignature) {
        return self.svc.createJsapiSignature(io, url, .{ .noncestr = nonce_str, .timestamp = timestamp });
    }
};

// ---------------------------------------------------------------------------
// 测试(mock RequestExecutor:断言 method + uri + 解析结果)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "jsapi get_jsapi_ticket: type=jsapi + parse ticket" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ticket/getticket", .response = "{\"errcode\":0,\"ticket\":\"JT\",\"expires_in\":7200}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = JsapiService{ .svc = &base };

    switch (s.get_jsapi_ticket(io)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
            try std.testing.expectEqualStrings("JT", tk.ticket);
            try std.testing.expectEqual(@as(i64, 7200), tk.expires_in);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expectEqual(mp_service.RequestExecutor.Method.get, m.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/cgi-bin/ticket/getticket") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "type=jsapi") != null);
}

test "jsapi get_card_api_ticket: type=wx_card" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ticket/getticket", .response = "{\"errcode\":0,\"ticket\":\"CT\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = JsapiService{ .svc = &base };

    switch (s.get_card_api_ticket(io)) {
        .ok => |*t| {
            var tk = t.*;
            defer tk.deinit();
            try std.testing.expectEqualStrings("CT", tk.ticket);
            // 缺省 expires_in 取 7200(与基座口径一致)
            try std.testing.expectEqual(@as(i64, 7200), tk.expires_in);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "type=wx_card") != null);
}

test "jsapi create_jsapi_signature: known vector (injected nonce/ts)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ticket/getticket", .response = "{\"errcode\":0,\"ticket\":\"JT\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfigWithTicket(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = JsapiService{ .svc = &base };

    // ticket="JT", nonce="WafNZkqFkFbFtMtx", ts=1320628854, url="http://example.com/page1"
    // SHA1("jsapi_ticket=JT&noncestr=WafNZkqFkFbFtMtx&timestamp=1320628854&url=http://example.com/page1")
    var sig = switch (s.create_jsapi_signature_injected(
        io,
        "http://example.com/page1",
        "WafNZkqFkFbFtMtx",
        1320628854,
    )) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    defer sig.deinit();
    // 独立计算期望值:4 段 k=v 按 ASCII 字典序(jsapi_ticket < noncestr < timestamp < url)
    const sha1_mod = @import("common").crypt.sha1;
    const expected = sha1_mod.genWithAmple(gpa, &.{
        "jsapi_ticket=JT",
        "noncestr=WafNZkqFkFbFtMtx",
        "timestamp=1320628854",
        "url=http://example.com/page1",
    }) catch return error.Oom;
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, sig.signature);
}

test "jsapi getticket errcode!=0 -> WxError" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ticket/getticket", .response = "{\"errcode\":40014,\"errmsg\":\"invalid access_token\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = JsapiService{ .svc = &base };

    switch (s.get_jsapi_ticket(io)) {
        .ok => |*t| {
            var tk = t.*;
            tk.deinit();
            return error.ExpectedErr;
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 40014), err.error_code);
        },
    }
}
