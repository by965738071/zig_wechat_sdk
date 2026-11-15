//! 电子发票报销方服务 —— 对应 Java `api.WxMpReimburseInvoiceService` +
//! `api.impl.WxMpReimburseInvoiceServiceImpl`(impl:26-45)。
//!
//! 4 个端点常量取自 `enums/WxMpApiUrl.Invoice` 的 reimburse 段;请求 bean
//! (InvoiceInfoRequest/InvoiceBatchRequest/UpdateInvoiceStatusRequest/
//! UpdateStatusBatchRequest)字段已逐字核实(@SerializedName),Zig 侧完整建模,
//! Gson 的 null 字段省略语义对齐(null → 字段不出现)。
//! 响应 bean(InvoiceInfoResponse)不建模,原样返回 body(调用方 free)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 报销发票条目 —— 对应 `bean.invoice.reimburse.InvoiceInfoRequest`
/// (`{"card_id":..,"encrypt_code":..}`,@SerializedName 逐字)。
pub const InvoiceItem = struct {
    card_id: []const u8,
    encrypt_code: []const u8,
};

/// 手写 JSON 转义写串(与 mass.zig 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

pub const ReimburseService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *ReimburseService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 对应 `getInvoiceInfo(InvoiceInfoRequest)`(impl:26-29):
    /// POST reimburse/getinvoiceinfo `{"card_id":..,"encrypt_code":..}`
    /// → InvoiceInfoResponse(原样返回)。
    pub fn getInvoiceInfo(self: *ReimburseService, io: std.Io, card_id: []const u8, encrypt_code: []const u8) WxResult([]u8) {
        return self.post(io, .invoice_reimburse_get_info, .{ .card_id = card_id, .encrypt_code = encrypt_code });
    }

    /// 对应 `getInvoiceBatch(InvoiceBatchRequest)`(impl:31-34):
    /// POST reimburse/getinvoicebatch `{"item_list":[{card_id,encrypt_code}...]}`
    /// → InvoiceInfoResponse 列表(原样返回)。
    /// 注:Java 端 item_list 为 null 时 Gson 省略字段;Zig 恒发(空 → [])。
    pub fn getInvoiceBatch(self: *ReimburseService, io: std.Io, items: []const InvoiceItem) WxResult([]u8) {
        return self.post(io, .invoice_reimburse_get_batch, .{ .item_list = items });
    }

    /// 对应 `updateInvoiceStatus(UpdateInvoiceStatusRequest)`(impl:40-43):
    /// POST reimburse/updateinvoicestatus
    /// `{"card_id":..,"encrypt_code":..,"reimburse_status":..}`。
    pub fn updateInvoiceStatus(self: *ReimburseService, io: std.Io, card_id: []const u8, encrypt_code: []const u8, reimburse_status: []const u8) Done {
        return self.postVoid(io, .invoice_reimburse_update_status, .{
            .card_id = card_id,
            .encrypt_code = encrypt_code,
            .reimburse_status = reimburse_status,
        });
    }

    /// 对应 `updateStatusBatch(UpdateStatusBatchRequest)`(impl:45-48):
    /// POST reimburse/updatestatusbatch
    /// `{"openid":..,"reimburse_status":..,"invoice_list":[...]}`。
    /// openid/reimburse_status 为 null 时省略(同 Gson);invoice_list 恒发。
    pub fn updateStatusBatch(self: *ReimburseService, io: std.Io, openid: ?[]const u8, reimburse_status: ?[]const u8, items: []const InvoiceItem) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        const build = build: {
            w.writeByte('{') catch break :build false;
            var first = true;
            if (openid) |v| {
                w.writeAll("\"openid\":") catch break :build false;
                jw.str(w, v) catch break :build false;
                first = false;
            }
            if (reimburse_status) |v| {
                if (!first) w.writeByte(',') catch break :build false;
                w.writeAll("\"reimburse_status\":") catch break :build false;
                jw.str(w, v) catch break :build false;
                first = false;
            }
            if (!first) w.writeByte(',') catch break :build false;
            w.writeAll("\"invoice_list\":[") catch break :build false;
            for (items, 0..) |it, i| {
                if (i != 0) w.writeByte(',') catch break :build false;
                w.writeAll("{\"card_id\":") catch break :build false;
                jw.str(w, it.card_id) catch break :build false;
                w.writeAll(",\"encrypt_code\":") catch break :build false;
                jw.str(w, it.encrypt_code) catch break :build false;
                w.writeByte('}') catch break :build false;
            }
            w.writeAll("]}") catch break :build false;
            break :build true;
        };
        if (!build) return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.invoice_reimburse_update_status_batch.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,只关心 errcode。
    fn postVoid(self: *ReimburseService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:4 端点 URL(含 reimburse 路径段)/method/请求体
// (逐字对照 WxMpApiUrl.Invoice + WxMpReimburseInvoiceServiceImpl)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Reimburse 契约: 4 端点 URL/method/请求体 (WxMpReimburseInvoiceServiceImpl)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "card/invoice/reimburse/", .response = "{\"errcode\":0,\"item_list\":[]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = ReimburseService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 1 GET_INVOICE_INFO:{"card_id","encrypt_code"}
    switch (svc.getInvoiceInfo(io, "CARD1", "ENC1")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"errcode\":0") != null);
        },
        .err => return error.Unexpected,
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/reimburse/getinvoiceinfo") != null);
    try testing.expectEqualStrings("{\"card_id\":\"CARD1\",\"encrypt_code\":\"ENC1\"}", mock.body());

    // 2 GET_INVOICE_BATCH:{"item_list":[...]}
    switch (svc.getInvoiceBatch(io, &.{
        .{ .card_id = "C1", .encrypt_code = "E1" },
        .{ .card_id = "C2", .encrypt_code = "E2" },
    })) {
        .ok => |raw| gpa.free(raw),
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/reimburse/getinvoicebatch") != null);
    try testing.expectEqualStrings("{\"item_list\":[{\"card_id\":\"C1\",\"encrypt_code\":\"E1\"},{\"card_id\":\"C2\",\"encrypt_code\":\"E2\"}]}", mock.body());

    // 3 UPDATE_INVOICE_STATUS:{"card_id","encrypt_code","reimburse_status"}
    switch (svc.updateInvoiceStatus(io, "C1", "E1", "INVOICE_REIMBURSE_INIT")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/reimburse/updateinvoicestatus") != null);
    try testing.expectEqualStrings("{\"card_id\":\"C1\",\"encrypt_code\":\"E1\",\"reimburse_status\":\"INVOICE_REIMBURSE_INIT\"}", mock.body());

    // 4 UPDATE_STATUS_BATCH:openid/reimburse_status 可选(null 省略)
    switch (svc.updateStatusBatch(io, null, null, &.{
        .{ .card_id = "C1", .encrypt_code = "E1" },
    })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "card/invoice/reimburse/updatestatusbatch") != null);
    try testing.expectEqualStrings("{\"invoice_list\":[{\"card_id\":\"C1\",\"encrypt_code\":\"E1\"}]}", mock.body());

    switch (svc.updateStatusBatch(io, "oX", "INVOICE_REIMBURSE_DONE", &.{})) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try testing.expectEqualStrings("{\"openid\":\"oX\",\"reimburse_status\":\"INVOICE_REIMBURSE_DONE\",\"invoice_list\":[]}", mock.body());

    try testing.expectEqual(@as(usize, 5), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}
