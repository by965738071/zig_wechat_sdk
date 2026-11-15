//! 设备订阅消息服务 —— 对应 Java `api.WxMaDeviceSubscribeService` +
//! `api.impl.WxMaDeviceSubscribeServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.DeviceSubscribe`:
//! - getSnTicket:POST /wxa/getsnticket {model_id,sn} → sn_ticket;
//! - sendDeviceSubscribeMsg:POST /cgi-bin/message/device/subscribe/send
//!   (请求体字段多且带模板参数,由调用方预构建);
//! - createIotGroupId:POST /wxa/business/group/createid {model_id,group_name}
//!   → group_id;
//! - getIotGroupInfo:POST /wxa/business/group/getinfo {group_id}(响应原样返回);
//! - addIotGroupDevice/removeIotGroupDevice:
//!   POST /wxa/business/group/adddevice|removedevice
//!   {group_id,device_list[]{model_id,sn},force_add}(响应原样返回,
//!   Java 解析出 device_list,此处交由调用方按需解析)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_SN_TICKET_URL = "https://api.weixin.qq.com/wxa/getsnticket";
const SEND_DEVICE_SUBSCRIBE_MSG_URL = "https://api.weixin.qq.com/cgi-bin/message/device/subscribe/send";
const CREATE_IOT_GROUP_ID_URL = "https://api.weixin.qq.com/wxa/business/group/createid";
const GET_IOT_GROUP_INFO_URL = "https://api.weixin.qq.com/wxa/business/group/getinfo";
const ADD_IOT_GROUP_DEVICE_URL = "https://api.weixin.qq.com/wxa/business/group/adddevice";
const REMOVE_IOT_GROUP_DEVICE_URL = "https://api.weixin.qq.com/wxa/business/group/removedevice";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

fn jsInt(w: *std.Io.Writer, v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try w.writeAll(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `device.WxMaDeviceTicketRequest`(model_id/sn;设备票据与查询共用)。
pub const DeviceTicket = struct {
    model_id: []const u8,
    sn: []const u8,

    fn writeJson(self: DeviceTicket, w: *std.Io.Writer) !void {
        try w.writeAll("{\"model_id\":");
        try js(w, self.model_id);
        try w.writeAll(",\"sn\":");
        try js(w, self.sn);
        try w.writeAll("}");
    }
};

/// 对应 `device.WxMaCreateIotGroupIdRequest`(model_id/group_name)。
pub const CreateIotGroupRequest = struct {
    model_id: []const u8,
    group_name: []const u8,

    pub fn to_json(self: CreateIotGroupRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"model_id\":");
        try js(w, self.model_id);
        try w.writeAll(",\"group_name\":");
        try js(w, self.group_name);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `device.WxMaGetIotGroupInfoRequest`(group_id)。
pub const GetIotGroupInfoRequest = struct {
    group_id: []const u8,

    pub fn to_json(self: GetIotGroupInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{{\"group_id\":\"{s}\"}}", .{self.group_id});
    }
};

/// 对应 `device.WxMaIotGroupDeviceRequest`(group_id/device_list/force_add)。
pub const IotGroupDeviceRequest = struct {
    group_id: []const u8,
    device_list: []const DeviceTicket,
    force_add: ?bool = null,

    pub fn to_json(self: IotGroupDeviceRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"group_id\":");
        try js(w, self.group_id);
        try w.writeAll(",\"device_list\":[");
        for (self.device_list, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try d.writeJson(w);
        }
        try w.writeAll("]");
        if (self.force_add) |b| {
            try w.writeAll(",\"force_add\":");
            try w.writeAll(if (b) "true" else "false");
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

// --- service -------------------------------------------------------------------

pub const DeviceService = struct {
    svc: *mp_service.Service,

    /// 对应 `getSnTicket(WxMaDeviceTicketRequest)`:
    /// POST /wxa/getsnticket → sn_ticket(gpa 拥有,调用方 free)。
    pub fn getSnTicket(self: *DeviceService, io: std.Io, req: DeviceTicket) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        req.writeJson(w) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_SN_TICKET_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getsnticket not json", .{}) };
        defer parsed.deinit();
        const sn = json_util.getStr(parsed.value, "sn_ticket") orelse
            return .{ .err = WxError.transport(gpa, "getsnticket missing sn_ticket", .{}) };
        return .{ .ok = gpa.dupe(u8, sn) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `sendDeviceSubscribeMsg(WxMaDeviceSubscribeMessageRequest)`:
    /// POST /cgi-bin/message/device/subscribe/send。
    /// 请求体由调用方预构建(touser/template_id/模型签名等字段多且含模板参数)。
    pub fn sendDeviceSubscribeMsg(self: *DeviceService, io: std.Io, body: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, SEND_DEVICE_SUBSCRIBE_MSG_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `createIotGroupId(WxMaCreateIotGroupIdRequest)`:
    /// POST /wxa/business/group/createid → group_id(gpa 拥有,调用方 free)。
    pub fn createIotGroupId(self: *DeviceService, io: std.Io, req: CreateIotGroupRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, CREATE_IOT_GROUP_ID_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "group/createid not json", .{}) };
        defer parsed.deinit();
        const gid = json_util.getStr(parsed.value, "group_id") orelse
            return .{ .err = WxError.transport(gpa, "group/createid missing group_id", .{}) };
        return .{ .ok = gpa.dupe(u8, gid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `getIotGroupInfo(WxMaGetIotGroupInfoRequest)`:
    /// POST /wxa/business/group/getinfo,响应原样返回(gpa 拥有,调用方 free;
    /// Java 解析 WxMaIotGroupDeviceInfoResponse,字段多且版本不稳,交由调用方)。
    pub fn getIotGroupInfo(self: *DeviceService, io: std.Io, req: GetIotGroupInfoRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, GET_IOT_GROUP_INFO_URL, &.{}, body);
    }

    /// 对应 `addIotGroupDevice(WxMaIotGroupDeviceRequest)`:
    /// POST /wxa/business/group/adddevice,响应原样返回(Java 解析 device_list,
    /// 此处交由调用方)。
    pub fn addIotGroupDevice(self: *DeviceService, io: std.Io, req: IotGroupDeviceRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, ADD_IOT_GROUP_DEVICE_URL, &.{}, body);
    }

    /// 对应 `removeIotGroupDevice(WxMaIotGroupDeviceRequest)`:
    /// POST /wxa/business/group/removedevice,响应原样返回。
    pub fn removeIotGroupDevice(self: *DeviceService, io: std.Io, req: IotGroupDeviceRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, REMOVE_IOT_GROUP_DEVICE_URL, &.{}, body);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "device getSnTicket + sendDeviceSubscribeMsg" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getsnticket", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"sn_ticket\":\"TICKET1\"}" },
        .{ .match = "device/subscribe/send", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = DeviceService{ .svc = &base };

    // getSnTicket
    const ticket = switch (s.getSnTicket(io, .{ .model_id = "model-1", .sn = "SN-001" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(ticket);
    try std.testing.expectEqualStrings("TICKET1", ticket);
    try std.testing.expectEqualStrings("{\"model_id\":\"model-1\",\"sn\":\"SN-001\"}", m.last_body);

    // sendDeviceSubscribeMsg:预构建体原样发出
    try std.testing.expect(!s.sendDeviceSubscribeMsg(io, "{\"touser\":\"oX\",\"template_id\":\"T\",\"page\":\"p\",\"sn\":\"SN-001\",\"sn_ticket\":\"TICKET1\"}").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "device/subscribe/send") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"template_id\":\"T\"") != null);
}

test "device iot group: create + getinfo + add/remove device" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "group/createid", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"group_id\":\"G1\"}" },
        .{ .match = "group/getinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"group_id\":\"G1\",\"group_name\":\"g\",\"device_list\":[{\"model_id\":\"model-1\",\"sn\":\"SN-001\"}]}" },
        .{ .match = "group/adddevice", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"device_list\":[{\"sn\":\"SN-001\",\"sn_ticket\":\"T1\"}]}" },
        .{ .match = "group/removedevice", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"device_list\":[]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = DeviceService{ .svc = &base };

    // create
    const gid = switch (s.createIotGroupId(io, .{ .model_id = "model-1", .group_name = "我的设备组" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(gid);
    try std.testing.expectEqualStrings("G1", gid);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"group_name\":\"我的设备组\"") != null);

    // getinfo:响应原样返回
    const info = switch (s.getIotGroupInfo(io, .{ .group_id = "G1" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "device_list") != null);
    try std.testing.expectEqualStrings("{\"group_id\":\"G1\"}", m.last_body);

    // adddevice:device_list 数组 + force_add
    const add = switch (s.addIotGroupDevice(io, .{
        .group_id = "G1",
        .device_list = &.{.{ .model_id = "model-1", .sn = "SN-001" }},
        .force_add = true,
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(add);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "group/adddevice") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"device_list\":[{\"model_id\":\"model-1\",\"sn\":\"SN-001\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"force_add\":true") != null);

    // removedevice:force_add 省略
    const rm = switch (s.removeIotGroupDevice(io, .{
        .group_id = "G1",
        .device_list = &.{.{ .model_id = "model-1", .sn = "SN-001" }},
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(rm);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "group/removedevice") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "force_add") == null);
}
