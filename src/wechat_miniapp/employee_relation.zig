//! 用工关系服务 —— 对应 Java `api.WxMaEmployeeRelationService` +
//! `api.impl.WxMaEmployeeRelationServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Employee`:
//! - unbindEmployee:POST /wxa/business/unbinduserb2cauthinfo {openid_list};
//! - sendEmployeeMsg:POST /cgi-bin/message/wxopen/employeerelationmsg/send
//!   {template_id,page,touser,data}。
//!
//! 与 Java 的差异:Java 的 `WxMaSendEmployeeMsgRequest.data` 字段是 String,
//! Gson 会把它序列化为**字符串值**(`"data":"{\"thing1\":...}"`),与微信文档示例
//! (`data` 为对象)不符;此处 `data_json` 按原文(应为 JSON 对象文本)原样嵌入,
//! 请求体与文档一致。
const std = @import("std");
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const UNBIND_EMPLOYEE_URL = "https://api.weixin.qq.com/wxa/business/unbinduserb2cauthinfo";
const SEND_EMPLOYEE_MSG_URL = "https://api.weixin.qq.com/cgi-bin/message/wxopen/employeerelationmsg/send";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean -----------------------------------------------------------------------

/// 对应 `employee.WxMaUnbindEmployeeRequest`(openid_list)。
pub const UnbindEmployeeRequest = struct {
    /// 需要解绑的用户 openid 列表。
    openid_list: []const []const u8,

    pub fn to_json(self: UnbindEmployeeRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid_list\":[");
        for (self.openid_list, 0..) |openid, i| {
            if (i > 0) try w.writeByte(',');
            try js(w, openid);
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

/// 对应 `employee.WxMaSendEmployeeMsgRequest`(template_id/page/touser/data)。
/// `data_json` 为调用方按模板预构建的 JSON 对象文本,原样嵌入(见文件头差异说明)。
pub const SendEmployeeMsgRequest = struct {
    /// 模板 id(用工关系权限申请通过后创建的模板审核通过可取得)。
    template_id: []const u8,
    /// 用工消息通知跳转的 page 小程序链接(须是申请模板的小程序)。
    page: []const u8,
    /// 被推送用户的 openid。
    touser: []const u8,
    /// 消息内容(按模板字段预构建的 JSON 对象文本,有顺序要求)。
    data_json: []const u8,

    pub fn to_json(self: SendEmployeeMsgRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"template_id\":");
        try js(w, self.template_id);
        try w.writeAll(",\"page\":");
        try js(w, self.page);
        try w.writeAll(",\"touser\":");
        try js(w, self.touser);
        // data 原样嵌入(对象文本),不作为字符串值转义 —— 见文件头差异说明。
        try w.writeAll(",\"data\":");
        try w.writeAll(self.data_json);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

// --- service ----------------------------------------------------------------------

pub const EmployeeRelationService = struct {
    svc: *mp_service.Service,

    /// 对应 `unbindEmployee(WxMaUnbindEmployeeRequest)`:
    /// POST /wxa/business/unbinduserb2cauthinfo {openid_list}。
    pub fn unbindEmployee(self: *EmployeeRelationService, io: std.Io, req: UnbindEmployeeRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UNBIND_EMPLOYEE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `sendEmployeeMsg(WxMaSendEmployeeMsgRequest)`:
    /// POST /cgi-bin/message/wxopen/employeerelationmsg/send。
    pub fn sendEmployeeMsg(self: *EmployeeRelationService, io: std.Io, req: SendEmployeeMsgRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SEND_EMPLOYEE_MSG_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "employee relation unbind/send" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "unbinduserb2cauthinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "employeerelationmsg/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = EmployeeRelationService{ .svc = &base };

    // unbind:POST {openid_list}
    switch (s.unbindEmployee(io, .{ .openid_list = &.{ "openid-1", "openid-2" } })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "wxa/business/unbinduserb2cauthinfo") != null);
    try std.testing.expectEqualStrings("{\"openid_list\":[\"openid-1\",\"openid-2\"]}", m.last_body);

    // send:POST {template_id,page,touser,data(原样嵌入的对象)}
    switch (s.sendEmployeeMsg(io, .{
        .template_id = "tmpl-1",
        .page = "pages/labor/index",
        .touser = "openid-1",
        .data_json = "{\"thing1\":{\"value\":\"岗位调整\"}}",
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "message/wxopen/employeerelationmsg/send") != null);
    try std.testing.expectEqualStrings(
        "{\"template_id\":\"tmpl-1\",\"page\":\"pages/labor/index\",\"touser\":\"openid-1\",\"data\":{\"thing1\":{\"value\":\"岗位调整\"}}}",
        m.last_body,
    );
}
