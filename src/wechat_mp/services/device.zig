//! 设备功能服务 —— 逐字对齐 Java `api.WxMpDeviceService` +
//! `api.impl.WxMpDeviceServiceImpl`,端点常量取自 `api_url.zig:Device`
//! (镜像 Java `enums.WxMpApiUrl.Device`,9 个常量;其中 DEVICE_UNBIND/
//! DEVICE_COMPEL_UNBIND 的 path 自带尾 `?`,逐字保留)。
//!
//! Java 接口 9 个方法(名称逐字对齐,impl:29-75):
//!   transMsg(msg)                  POST device/transmsg          {"device_type","device_id","open_id","content"}
//!                                 → {ret,ret_info,errcode,errmsg}
//!   getQrCode(productId)          GET  device/getqrcode?product_id=..
//!                                 → {deviceid,qrticket,devicelicence}
//!   authorize(...)                POST device/authorize_device  {"device_num","op_type","product_id","device_list":[...]}
//!                                 → {resp:[{errcode,errmsg}]}
//!   bind/compelBind(...)          POST device/bind|compel_bind   {"ticket","device_id","openid"}
//!                                 → base_resp{errcode,errmsg}
//!   unbind/compelUnbind(...)      POST device/unbind?|compel_unbind?(同上请求体)
//!   getOpenId(deviceType,deviceId) GET device/get_openid?device_type=..&device_id=..
//!                                 → {open_id:[...],resp_msg{ret,err_msg}}
//!   getBindDevice(openId)          GET device/get_bind_device?openid=..
//!                                 → {resp_msg,openid,device_list:[{device_type,device_id}]}
//!
//! Java↔Zig 差异:
//!   - `WxDeviceMsg`/`WxDeviceBind` bean → 参数直接展开(字段同 @SerializedName);
//!   - `WxDeviceAuthorize` 的 `device_list` 用 `DeviceItem`(借用切片)组包,
//!     WxDevice 的 11 个字段只收录 id/mac/connect_protocol/auth_key/close_strategy/
//!     conn_strategy/crypt_method/auth_ver(其余 manu_mac_pos/ser_mac_pos/
//!     ble_simple_protocol 不常用,需要时以 authorizeByJson 传原始 JSON);
//!   - `BaseResp`/`resp_msg` 只解析 errcode/errmsg(ret/ret_info);
//!   - Java `authorize` 响应的 `resp` 数组 → `RespItem` 列表。
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

/// transMsg 响应 —— 对应 `TransMsgResp`(ret/ret_info/errcode/errmsg)。
pub const TransMsgResp = struct {
    gpa: std.mem.Allocator,
    ret: i64 = 0,
    ret_info: []u8,
    errcode: i64 = 0,
    errmsg: []u8,

    pub fn deinit(self: *TransMsgResp) void {
        self.gpa.free(self.ret_info);
        self.gpa.free(self.errmsg);
        self.* = undefined;
    }
};

/// 设备二维码 —— 对应 `WxDeviceQrCodeResult`(deviceid/qrticket/devicelicence)。
pub const QrCodeResult = struct {
    gpa: std.mem.Allocator,
    deviceid: []u8,
    qrticket: []u8,
    devicelicence: []u8,

    pub fn deinit(self: *QrCodeResult) void {
        self.gpa.free(self.deviceid);
        self.gpa.free(self.qrticket);
        self.gpa.free(self.devicelicence);
        self.* = undefined;
    }
};

/// base_resp{errcode,errmsg} —— 对应 `WxDeviceBindResult`/`BaseResp`。
pub const BindResult = struct {
    gpa: std.mem.Allocator,
    errcode: i64 = 0,
    errmsg: []u8,

    pub fn deinit(self: *BindResult) void {
        self.gpa.free(self.errmsg);
        self.* = undefined;
    }
};

/// authorize 响应的 resp[i] —— 对应 `WxDeviceAuthorizeResult.resp` 的 BaseResp。
pub const RespItem = struct {
    gpa: std.mem.Allocator,
    errcode: i64 = 0,
    errmsg: []u8,

    pub fn deinit(self: *RespItem) void {
        self.gpa.free(self.errmsg);
        self.* = undefined;
    }
};

/// authorize 响应 —— `{"resp":[...]}`。
pub const AuthorizeResult = struct {
    gpa: std.mem.Allocator,
    resp: []RespItem = &.{},

    pub fn deinit(self: *AuthorizeResult) void {
        for (self.resp) |*r| r.deinit();
        if (self.resp.len > 0) self.gpa.free(self.resp);
        self.* = undefined;
    }
};

/// 设备绑定的用户列表 —— 对应 `WxDeviceOpenIdResult`(open_id[] + resp_msg)。
pub const OpenIdResult = struct {
    gpa: std.mem.Allocator,
    open_ids: [][]u8 = &.{},
    ret: i64 = 0,
    err_msg: []u8,

    pub fn deinit(self: *OpenIdResult) void {
        for (self.open_ids) |o| self.gpa.free(o);
        if (self.open_ids.len > 0) self.gpa.free(self.open_ids);
        self.gpa.free(self.err_msg);
        self.* = undefined;
    }
};

/// 用户绑定的设备 —— `WxDeviceBindDeviceResult.device_list[i]`。
pub const DeviceItemResp = struct {
    gpa: std.mem.Allocator,
    device_type: []u8,
    device_id: []u8,

    pub fn deinit(self: *DeviceItemResp) void {
        self.gpa.free(self.device_type);
        self.gpa.free(self.device_id);
        self.* = undefined;
    }
};

/// 用户绑定的设备列表 —— `WxDeviceBindDeviceResult`(resp_msg/openid/device_list)。
pub const BindDeviceResult = struct {
    gpa: std.mem.Allocator,
    openid: []u8,
    devices: []DeviceItemResp = &.{},

    pub fn deinit(self: *BindDeviceResult) void {
        self.gpa.free(self.openid);
        for (self.devices) |*d| d.deinit();
        if (self.devices.len > 0) self.gpa.free(self.devices);
        self.* = undefined;
    }
};

/// 授权设备项 —— 对应 `WxDevice`(借用切片,核心字段)。
pub const DeviceItem = struct {
    id: []const u8,
    mac: []const u8,
    connect_protocol: []const u8,
    auth_key: []const u8,
    close_strategy: []const u8,
    conn_strategy: []const u8,
    crypt_method: []const u8,
    auth_ver: []const u8,
};

fn errOf(gpa: std.mem.Allocator, what: []const u8) WxError {
    return WxError.transport(gpa, "{s} response not json", .{what});
}

pub const DeviceService = struct {
    svc: *service_mod.Service,

    /// 对应 `#transMsg`(impl:29-33):POST {"device_type","device_id","open_id","content"}。
    pub fn transMsg(self: *DeviceService, io: std.Io, device_type: []const u8, device_id: []const u8, open_id: []const u8, content: []const u8) WxResult(TransMsgResp) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("device_type", device_type) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("device_id", device_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("open_id", open_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("content", content) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Device.device_transmsg, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "transmsg") };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .ret = json_util.getIntOr(parsed.value, "ret", 0),
            .ret_info = gpa.dupe(u8, json_util.getStrOr(parsed.value, "ret_info", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            .errcode = json_util.getIntOr(parsed.value, "errcode", 0),
            .errmsg = gpa.dupe(u8, json_util.getStrOr(parsed.value, "errmsg", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
        } };
    }

    /// 对应 `#getQrCode`(impl:35-40):GET product_id=.. → deviceid/qrticket/devicelicence。
    pub fn getQrCode(self: *DeviceService, io: std.Io, product_id: []const u8) WxResult(QrCodeResult) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?product_id={s}", .{ service_mod.api_host_url, api_url.Device.device_getqrcode, product_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "getqrcode") };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .deviceid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "deviceid", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            .qrticket = gpa.dupe(u8, json_util.getStrOr(parsed.value, "qrticket", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
            .devicelicence = gpa.dupe(u8, json_util.getStrOr(parsed.value, "devicelicence", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
        } };
    }

    /// 对应 `#authorize`(impl:42-47):POST {"device_num","op_type","product_id","device_list"}。
    /// 容器树(device_list 数组/每项对象)一次性组包进 arena,序列化后整体释放
    /// (照 guide.zig 的 arena 模式);字符串全部借用自入参。
    pub fn authorize(self: *DeviceService, io: std.Io, device_num: []const u8, op_type: []const u8, product_id: []const u8, device_list: []const DeviceItem) WxResult(AuthorizeResult) {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(json_util.Value) = .empty;
        for (device_list) |d| {
            var m: json_util.ObjectMap = .empty;
            m.put(a, "id", .{ .string = d.id }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "mac", .{ .string = d.mac }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "connect_protocol", .{ .string = d.connect_protocol }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "auth_key", .{ .string = d.auth_key }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "close_strategy", .{ .string = d.close_strategy }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "conn_strategy", .{ .string = d.conn_strategy }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "crypt_method", .{ .string = d.crypt_method }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            m.put(a, "auth_ver", .{ .string = d.auth_ver }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            list.append(a, .{ .object = m }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        var m: json_util.ObjectMap = .empty;
        m.put(a, "device_num", .{ .string = device_num }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "op_type", .{ .string = op_type }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "product_id", .{ .string = product_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        m.put(a, "device_list", .{ .array = list }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = json_util.stringify(gpa, json_util.Value{ .object = m }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Device.device_authorize_device, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "authorize_device") };
        defer parsed.deinit();
        var r = AuthorizeResult{ .gpa = gpa };
        errdefer r.deinit();
        var items: std.ArrayList(RespItem) = .empty;
        errdefer {
            for (items.items) |*it| it.deinit();
            items.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "resp")) |arr| {
            for (arr.items) |item| {
                var ri = RespItem{
                    .gpa = gpa,
                    .errcode = json_util.getIntOr(item, "errcode", 0),
                    .errmsg = gpa.dupe(u8, json_util.getStrOr(item, "errmsg", "")) catch
                        return .{ .err = WxError.internal(gpa, "oom", .{}) },
                };
                errdefer ri.deinit();
                items.append(gpa, ri) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        r.resp = items.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = r };
    }

    /// bind/compelBind/unbind/compelUnbind 共用 —— POST {"ticket","device_id","openid"}
    /// → base_resp{errcode,errmsg}。
    fn bindPost(self: *DeviceService, io: std.Io, path: []const u8, ticket: []const u8, device_id: []const u8, openid: []const u8) WxResult(BindResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("ticket", ticket) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("device_id", device_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("openid", openid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, path, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "bind") };
        defer parsed.deinit();
        var br = json_util.getObject(parsed.value, "base_resp") orelse parsed.value;
        _ = &br;
        return .{ .ok = .{
            .gpa = gpa,
            .errcode = json_util.getIntOr(br, "errcode", 0),
            .errmsg = gpa.dupe(u8, json_util.getStrOr(br, "errmsg", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
        } };
    }

    /// 对应 `#bind`(impl:49-53)。
    pub fn bind(self: *DeviceService, io: std.Io, ticket: []const u8, device_id: []const u8, openid: []const u8) WxResult(BindResult) {
        return self.bindPost(io, api_url.Device.device_bind, ticket, device_id, openid);
    }

    /// 对应 `#compelBind`(impl:55-59)。
    pub fn compelBind(self: *DeviceService, io: std.Io, ticket: []const u8, device_id: []const u8, openid: []const u8) WxResult(BindResult) {
        return self.bindPost(io, api_url.Device.device_compel_bind, ticket, device_id, openid);
    }

    /// 对应 `#unbind`(impl:61-65):path 自带尾 `?`。
    pub fn unbind(self: *DeviceService, io: std.Io, ticket: []const u8, device_id: []const u8, openid: []const u8) WxResult(BindResult) {
        return self.bindPost(io, api_url.Device.device_unbind, ticket, device_id, openid);
    }

    /// 对应 `#compelUnbind`(impl:67-71):path 自带尾 `?`。
    pub fn compelUnbind(self: *DeviceService, io: std.Io, ticket: []const u8, device_id: []const u8, openid: []const u8) WxResult(BindResult) {
        return self.bindPost(io, api_url.Device.device_compel_unbind, ticket, device_id, openid);
    }

    /// 对应 `#getOpenId`(impl:73-76):GET device_type=..&device_id=.. → open_id[]。
    pub fn getOpenId(self: *DeviceService, io: std.Io, device_type: []const u8, device_id: []const u8) WxResult(OpenIdResult) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?device_type={s}&device_id={s}", .{ service_mod.api_host_url, api_url.Device.device_get_openid, device_type, device_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "get_openid") };
        defer parsed.deinit();
        var r = OpenIdResult{
            .gpa = gpa,
            .err_msg = undefined,
        };
        errdefer r.deinit();
        var ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (ids.items) |s| gpa.free(s);
            ids.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "open_id")) |arr| {
            for (arr.items) |v| switch (v) {
                .string => |s| ids.append(gpa, gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) }) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) },
                else => {},
            };
        }
        r.open_ids = ids.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var rmsg = json_util.getObject(parsed.value, "resp_msg") orelse parsed.value;
        _ = &rmsg;
        r.ret = json_util.getIntOr(rmsg, "ret", 0);
        r.err_msg = gpa.dupe(u8, json_util.getStrOr(rmsg, "err_msg", "")) catch {
            for (r.open_ids) |o| gpa.free(o);
            gpa.free(r.open_ids);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        return .{ .ok = r };
    }

    /// 对应 `#getBindDevice`(impl:78-81):GET openid=.. → device_list[]。
    pub fn getBindDevice(self: *DeviceService, io: std.Io, openid: []const u8) WxResult(BindDeviceResult) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?openid={s}", .{ service_mod.api_host_url, api_url.Device.device_get_bind_device, openid }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = errOf(gpa, "get_bind_device") };
        defer parsed.deinit();
        var r = BindDeviceResult{
            .gpa = gpa,
            .openid = gpa.dupe(u8, json_util.getStrOr(parsed.value, "openid", "")) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) },
        };
        errdefer r.deinit();
        var devs: std.ArrayList(DeviceItemResp) = .empty;
        errdefer {
            for (devs.items) |*d| d.deinit();
            devs.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "device_list")) |arr| {
            for (arr.items) |item| {
                var d = DeviceItemResp{
                    .gpa = gpa,
                    .device_type = gpa.dupe(u8, json_util.getStrOr(item, "device_type", "")) catch
                        return .{ .err = WxError.internal(gpa, "oom", .{}) },
                    .device_id = gpa.dupe(u8, json_util.getStrOr(item, "device_id", "")) catch
                        return .{ .err = WxError.internal(gpa, "oom", .{}) },
                };
                errdefer d.deinit();
                devs.append(gpa, d) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        r.devices = devs.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = r };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:9 端点 URL/method/请求体 + 响应解析
// (逐字对照 WxMpApiUrl.Device + WxMpDeviceServiceImpl)
// ---------------------------------------------------------------------------

test "Device 契约: transMsg/getQrCode/bind 系列 (WxMpApiUrl.Device)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "device/transmsg", .response = "{\"ret\":0,\"ret_info\":\"ok\",\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "device/getqrcode", .response = "{\"deviceid\":\"D1\",\"qrticket\":\"T1\",\"devicelicence\":\"L1\"}" },
        .{ .match = "device/bind", .response = "{\"base_resp\":{\"errcode\":0,\"errmsg\":\"ok\"}}" },
        .{ .match = "device/compel_bind", .response = "{\"base_resp\":{\"errcode\":0}}" },
        .{ .match = "device/unbind", .response = "{\"base_resp\":{\"errcode\":0}}" },
        .{ .match = "device/compel_unbind", .response = "{\"base_resp\":{\"errcode\":0}}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = DeviceService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // transMsg
    switch (svc.transMsg(io, "公众账号原始id", "DEV1", "oX", "{\"a\":1}")) {
        .ok => |*r| {
            var m = r.*;
            defer m.deinit();
            try testing.expectEqual(@as(i64, 0), m.ret);
            try testing.expectEqualStrings("ok", m.ret_info);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeviceTransMsg;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "device/transmsg") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"device_id\":\"DEV1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"open_id\":\"oX\"") != null);

    // getQrCode: GET ?product_id=
    switch (svc.getQrCode(io, "PID1")) {
        .ok => |*r| {
            var q = r.*;
            defer q.deinit();
            try testing.expectEqualStrings("D1", q.deviceid);
            try testing.expectEqualStrings("T1", q.qrticket);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeviceGetQrCode;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "device/getqrcode?product_id=PID1") != null);

    // bind / compelBind / unbind / compelUnbind: {"ticket","device_id","openid"}
    // @field 从类型取方法声明(实例不可作为 comptime 值引用方法)。
    inline for (.{
        .{ "bind", "device/bind" },
        .{ "compelBind", "device/compel_bind" },
        .{ "unbind", "device/unbind" },
        .{ "compelUnbind", "device/compel_unbind" },
    }) |case| {
        const method = @field(DeviceService, case[0]);
        switch (method(&svc, io, "TK", "DEV1", "oX")) {
            .ok => |*r| {
                var b = r.*;
                defer b.deinit();
                try testing.expectEqual(@as(i64, 0), b.errcode);
            },
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                return error.UnexpectedDeviceBind;
            },
        }
        try testing.expect(std.mem.indexOf(u8, mock.uri(), case[1]) != null);
        try testing.expect(std.mem.indexOf(u8, mock.body(), "\"ticket\":\"TK\"") != null);
        try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":\"oX\"") != null);
    }
}

test "Device 契约: authorize/getOpenId/getBindDevice (WxMpApiUrl.Device)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "device/authorize_device", .response = "{\"resp\":[{\"errcode\":0,\"errmsg\":\"ok\"},{\"errcode\":0}]}" },
        .{ .match = "device/get_openid", .response = "{\"errcode\":0,\"open_id\":[\"oA\",\"oB\"],\"resp_msg\":{\"ret\":0,\"err_msg\":\"\"}}" },
        .{ .match = "device/get_bind_device", .response = "{\"resp_msg\":{\"ret\":0},\"openid\":\"oX\",\"device_list\":[{\"device_type\":\"公众账号原始id\",\"device_id\":\"DEV1\"}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = DeviceService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // authorize: {"device_num","op_type","product_id","device_list":[...]}
    switch (svc.authorize(io, "1", "0", "PID1", &.{.{
        .id = "DEV1",
        .mac = "001122334455",
        .connect_protocol = "1",
        .auth_key = "auth",
        .close_strategy = "1",
        .conn_strategy = "1",
        .crypt_method = "0",
        .auth_ver = "0",
    }})) {
        .ok => |*r| {
            var a = r.*;
            defer a.deinit();
            try testing.expectEqual(@as(usize, 2), a.resp.len);
            try testing.expectEqual(@as(i64, 0), a.resp[0].errcode);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeviceAuthorize;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "device/authorize_device") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"device_num\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"device_list\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"connect_protocol\":\"1\"") != null);

    // getOpenId: GET ?device_type=&device_id= → open_id[]
    switch (svc.getOpenId(io, "公众账号原始id", "DEV1")) {
        .ok => |*r| {
            var o = r.*;
            defer o.deinit();
            try testing.expectEqual(@as(usize, 2), o.open_ids.len);
            try testing.expectEqualStrings("oA", o.open_ids[0]);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeviceGetOpenId;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "device/get_openid?device_type=") != null);

    // getBindDevice: GET ?openid= → device_list[]
    switch (svc.getBindDevice(io, "oX")) {
        .ok => |*r| {
            var b = r.*;
            defer b.deinit();
            try testing.expectEqualStrings("oX", b.openid);
            try testing.expectEqual(@as(usize, 1), b.devices.len);
            try testing.expectEqualStrings("DEV1", b.devices[0].device_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedDeviceGetBindDevice;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "device/get_bind_device?openid=oX") != null);
}
