//! 人脸核身服务 —— 对应 Java `api.WxMaFaceService` + `api.impl.WxMaFaceServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Face`:
//! - getVerifyId:POST /cityservice/face/identify/getverifyid;
//! - queryVerifyInfo:POST /cityservice/face/identify/queryverifyinfo。
//! 序列化对齐 Gson 默认策略(null 字段省略)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GET_VERIFY_ID_URL = "https://api.weixin.qq.com/cityservice/face/identify/getverifyid";
const QUERY_VERIFY_INFO_URL = "https://api.weixin.qq.com/cityservice/face/identify/queryverifyinfo";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `face.WxMaFaceGetVerifyIdRequest.CertInfo`(证件三要素)。
pub const CertInfo = struct {
    cert_type: []const u8,
    cert_name: []const u8,
    cert_no: []const u8,

    fn writeJson(self: CertInfo, w: *std.Io.Writer) !void {
        try w.writeAll("{\"cert_type\":");
        try js(w, self.cert_type);
        try w.writeAll(",\"cert_name\":");
        try js(w, self.cert_name);
        try w.writeAll(",\"cert_no\":");
        try js(w, self.cert_no);
        try w.writeAll("}");
    }
};

/// 对应 `face.WxMaFaceGetVerifyIdRequest`(out_seq_no/cert_info/openid)。
pub const FaceVerifyIdRequest = struct {
    out_seq_no: ?[]const u8 = null,
    cert_info: CertInfo,
    openid: []const u8,

    pub fn to_json(self: FaceVerifyIdRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        if (self.out_seq_no) |s| {
            try w.writeAll("\"out_seq_no\":");
            try js(w, s);
            try w.writeAll(",");
        }
        try w.writeAll("\"cert_info\":");
        try self.cert_info.writeJson(w);
        try w.writeAll(",\"openid\":");
        try js(w, self.openid);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `face.WxMaFaceGetVerifyIdResponse`(verify_id/expires_in)。gpa 拥有。
pub const FaceVerifyId = struct {
    gpa: std.mem.Allocator,
    verify_id: ?[]const u8,
    expires_in: ?i64,

    pub fn deinit(self: *FaceVerifyId) void {
        if (self.verify_id) |s| self.gpa.free(@constCast(s));
    }

    pub fn deinitConst(self: *const FaceVerifyId) void {
        if (self.verify_id) |s| self.gpa.free(s);
    }
};

/// 对应 `face.WxMaFaceQueryVerifyInfoRequest`(verify_id/out_seq_no/cert_hash/openid)。
pub const FaceQueryVerifyInfoRequest = struct {
    verify_id: ?[]const u8 = null,
    out_seq_no: ?[]const u8 = null,
    cert_hash: ?[]const u8 = null,
    openid: []const u8,

    pub fn to_json(self: FaceQueryVerifyInfoRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        var first = true;
        try w.writeAll("{");
        if (self.verify_id) |s| {
            try w.writeAll("\"verify_id\":");
            try js(w, s);
            first = false;
        }
        if (self.out_seq_no) |s| {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"out_seq_no\":");
            try js(w, s);
            first = false;
        }
        if (self.cert_hash) |s| {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"cert_hash\":");
            try js(w, s);
            first = false;
        }
        if (!first) try w.writeAll(",");
        try w.writeAll("\"openid\":");
        try js(w, self.openid);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `face.WxMaFaceQueryVerifyInfoResponse`(verify_ret)。gpa 拥有。
pub const FaceVerifyResult = struct {
    gpa: std.mem.Allocator,
    verify_ret: ?i64,

    pub fn deinit(self: *FaceVerifyResult) void {
        _ = self;
    }

    pub fn deinitConst(self: *const FaceVerifyResult) void {
        _ = self;
    }
};

// --- service -------------------------------------------------------------------

pub const FaceService = struct {
    svc: *mp_service.Service,

    /// 对应 `getVerifyId(WxMaFaceGetVerifyIdRequest)`:
    /// POST /cityservice/face/identify/getverifyid → verify_id/expires_in。
    pub fn getVerifyId(self: *FaceService, io: std.Io, req: FaceVerifyIdRequest) WxResult(FaceVerifyId) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_VERIFY_ID_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getverifyid not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .verify_id = if (json_util.getStr(parsed.value, "verify_id")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
            .expires_in = json_util.getInt(parsed.value, "expires_in"),
        } };
    }

    /// 对应 `queryVerifyInfo(WxMaFaceQueryVerifyInfoRequest)`:
    /// POST /cityservice/face/identify/queryverifyinfo → verify_ret。
    pub fn queryVerifyInfo(self: *FaceService, io: std.Io, req: FaceQueryVerifyInfoRequest) WxResult(FaceVerifyResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, QUERY_VERIFY_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "queryverifyinfo not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .verify_ret = json_util.getInt(parsed.value, "verify_ret"),
        } };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "face getVerifyId + queryVerifyInfo" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getverifyid", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"verify_id\":\"VID1\",\"expires_in\":1800}" },
        .{ .match = "queryverifyinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"verify_ret\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = FaceService{ .svc = &base };

    // getVerifyId:cert_info 嵌套对象
    const vid = switch (s.getVerifyId(io, .{
        .out_seq_no = "SEQ1",
        .cert_info = .{ .cert_type = "IDCARD", .cert_name = "张三", .cert_no = "110101199001011234" },
        .openid = "oX",
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var v = vid;
    defer v.deinit();
    try std.testing.expectEqualStrings("VID1", v.verify_id.?);
    try std.testing.expectEqual(@as(?i64, 1800), v.expires_in);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("SEQ1", json_util.getStr(parsed.value, "out_seq_no").?);
    const ci = json_util.getObject(parsed.value, "cert_info").?;
    try std.testing.expectEqualStrings("IDCARD", json_util.getStr(ci, "cert_type").?);
    try std.testing.expectEqualStrings("张三", json_util.getStr(ci, "cert_name").?);

    // queryVerifyInfo:null 字段省略
    const ret = switch (s.queryVerifyInfo(io, .{ .verify_id = "VID1", .openid = "oX" })) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(?i64, 0), ret.verify_ret);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "queryverifyinfo") != null);
    const parsed2 = try json_util.parse(gpa, m.last_body);
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("VID1", json_util.getStr(parsed2.value, "verify_id").?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "cert_hash") == null);
}
