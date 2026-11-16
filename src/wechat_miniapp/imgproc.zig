//! 图像处理服务 —— 对应 Java `api.impl.WxMaImgProcServiceImpl`
//! (实现 `common.service.WxImgProcService`)。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.ImgProc`:
//! - qrCode:POST /cv/img/qrcode?img_url=编码后(body 为空串);
//! - superResolution:GET /cv/img/superresolution?img_url=编码后;
//! - aiCrop:POST /cv/img/aicrop?img_url=编码后&ratios=原始(Java 不编码 ratios,
//!   此处保持一致);ratios 为空串时同样拼接(与 Java 空串行为一致)。
//! 文件上传变体(qrCode(File)/superResolution(File)/aiCrop(File,...))依赖
//! multipart,基座 http 层暂不支持,未实现(待支持后补齐)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const QRCODE_URL = "https://api.weixin.qq.com/cv/img/qrcode?img_url=";
const SUPER_RESOLUTION_URL = "https://api.weixin.qq.com/cv/img/superresolution?img_url=";
const AI_CROP_URL = "https://api.weixin.qq.com/cv/img/aicrop?img_url=";

// --- bean ---------------------------------------------------------------------

/// 对应 `common.bean.ocr.WxOcrImgSize`(w/h)。
pub const ImgSize = struct { w: i64, h: i64 };

/// 对应 `common.bean.ocr.WxOcrPos`(四角坐标)。
pub const Pos = struct {
    left_top: ?Coordinate = null,
    right_top: ?Coordinate = null,
    right_bottom: ?Coordinate = null,
    left_bottom: ?Coordinate = null,

    pub const Coordinate = struct { x: i64, y: i64 };
};

/// 对应 `common.bean.imgproc.WxImgProcQrCodeResult`(img_size/code_results)。
/// gpa 拥有,deinit 释放全部字符串。
pub const ImgProcQrCodeResult = struct {
    gpa: std.mem.Allocator,
    img_size: ?ImgSize,
    code_results: []CodeResult,

    pub const CodeResult = struct {
        type_name: ?[]const u8,
        data: ?[]const u8,
        pos: ?Pos,
    };

    pub fn deinit(self: *ImgProcQrCodeResult) void {
        const g = self.gpa;
        for (self.code_results) |*c| {
            if (c.type_name) |s| g.free(@constCast(s));
            if (c.data) |s| g.free(@constCast(s));
        }
        g.free(self.code_results);
    }

    pub fn deinitConst(self: *const ImgProcQrCodeResult) void {
        const g = self.gpa;
        for (self.code_results) |*c| {
            if (c.type_name) |s| g.free(s);
            if (c.data) |s| g.free(s);
        }
        g.free(self.code_results);
    }
};

/// 对应 `common.bean.imgproc.WxImgProcSuperResolutionResult`(media_id)。
/// gpa 拥有。
pub const SuperResolutionResult = struct {
    gpa: std.mem.Allocator,
    media_id: ?[]const u8,

    pub fn deinit(self: *SuperResolutionResult) void {
        if (self.media_id) |s| self.gpa.free(@constCast(s));
    }

    pub fn deinitConst(self: *const SuperResolutionResult) void {
        if (self.media_id) |s| self.gpa.free(s);
    }
};

/// 对应 `common.bean.imgproc.WxImgProcAiCropResult`(img_size/results)。
/// gpa 拥有。
pub const AiCropResult = struct {
    gpa: std.mem.Allocator,
    img_size: ?ImgSize,
    results: []CropResult,

    pub const CropResult = struct {
        crop_left: ?i64,
        crop_top: ?i64,
        crop_right: ?i64,
        crop_bottom: ?i64,
    };

    pub fn deinit(self: *AiCropResult) void {
        self.gpa.free(self.results);
    }

    pub fn deinitConst(self: *const AiCropResult) void {
        self.gpa.free(self.results);
    }
};

// --- service -------------------------------------------------------------------

pub const ImgProcService = struct {
    svc: *mp_service.Service,

    /// 对应 `qrCode(imgUrl)`:POST /cv/img/qrcode?img_url=编码后(body 为空串)
    /// → 解析二维码/条码识别结果。
    pub fn qrCode(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(ImgProcQrCodeResult) {
        const gpa = self.svc.gpa;
        const url = buildUrl(gpa, QRCODE_URL, img_url, null) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(url);
        const resp = switch (self.svc.post(io, url, &.{}, "")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc qrcode not json", .{}) };
        defer parsed.deinit();
        var out = ImgProcQrCodeResult{ .gpa = gpa, .img_size = null, .code_results = &[_]ImgProcQrCodeResult.CodeResult{} };
        errdefer out.deinit();
        if (json_util.getObject(parsed.value, "img_size")) |sz| {
            const w = json_util.getInt(sz, "w");
            const h = json_util.getInt(sz, "h");
            if (w != null and h != null) out.img_size = .{ .w = w.?, .h = h.? };
        }
        if (json_util.getArray(parsed.value, "code_results")) |arr| {
            const items = gpa.alloc(ImgProcQrCodeResult.CodeResult, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*c| {
                    if (c.type_name) |s| gpa.free(@constCast(s));
                    if (c.data) |s| gpa.free(@constCast(s));
                }
                gpa.free(items);
            }
            for (arr.items) |item| {
                var c = ImgProcQrCodeResult.CodeResult{ .type_name = null, .data = null, .pos = null };
                if (json_util.getStr(item, "type_name")) |s| c.type_name = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "data")) |s| c.data = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getObject(item, "pos")) |pos| c.pos = parsePos(pos);
                items[filled] = c;
                filled += 1;
            }
            out.code_results = items;
        }
        return .{ .ok = out };
    }

    /// 对应 `superResolution(imgUrl)`:GET /cv/img/superresolution?img_url=编码后
    /// → 解析 {media_id}。
    pub fn superResolution(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(SuperResolutionResult) {
        const gpa = self.svc.gpa;
        const url = buildUrl(gpa, SUPER_RESOLUTION_URL, img_url, null) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(url);
        const resp = switch (self.svc.get(io, url, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc superresolution not json", .{}) };
        defer parsed.deinit();
        var out = SuperResolutionResult{ .gpa = gpa, .media_id = null };
        errdefer out.deinit();
        if (json_util.getStr(parsed.value, "media_id")) |s| out.media_id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `aiCrop(imgUrl)`:ratios 缺省为 ""(与 Java aiCrop(imgUrl) 委托一致,
    /// URL 仍拼接空的 `&ratios=`,与 Java String.format 行为一致)。
    pub fn aiCrop(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(AiCropResult) {
        return self.aiCropWithRatios(io, img_url, "");
    }

    /// 对应 `aiCrop(imgUrl, ratios)`:POST /cv/img/aicrop?img_url=编码后&ratios=原始
    /// (ratios 不编码;空串时同样拼接 `&ratios=`,与 Java 保持一致)
    /// → 解析 {img_size,results[]}。
    pub fn aiCropWithRatios(self: *ImgProcService, io: std.Io, img_url: []const u8, ratios: []const u8) WxResult(AiCropResult) {
        const gpa = self.svc.gpa;
        const url = buildUrl(gpa, AI_CROP_URL, img_url, ratios) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(url);
        const resp = switch (self.svc.post(io, url, &.{}, "")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc aicrop not json", .{}) };
        defer parsed.deinit();
        var out = AiCropResult{ .gpa = gpa, .img_size = null, .results = &[_]AiCropResult.CropResult{} };
        errdefer out.deinit();
        if (json_util.getObject(parsed.value, "img_size")) |sz| {
            const w = json_util.getInt(sz, "w");
            const h = json_util.getInt(sz, "h");
            if (w != null and h != null) out.img_size = .{ .w = w.?, .h = h.? };
        }
        if (json_util.getArray(parsed.value, "results")) |arr| {
            const items = gpa.alloc(AiCropResult.CropResult, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer gpa.free(items);
            for (arr.items) |item| {
                items[filled] = .{
                    .crop_left = json_util.getInt(item, "crop_left"),
                    .crop_top = json_util.getInt(item, "crop_top"),
                    .crop_right = json_util.getInt(item, "crop_right"),
                    .crop_bottom = json_util.getInt(item, "crop_bottom"),
                };
                filled += 1;
            }
            out.results = items;
        }
        return .{ .ok = out };
    }

    // 文件上传变体(qrCode(File)/superResolution(File)/aiCrop(File,ratios))依赖
    // multipart,基座 http 层暂不支持,未实现。
};

// 内部:拼 URL = prefix ++ urlEncode(img_url)(qrcode/superresolution),
// 或 prefix ++ urlEncode(img_url) ++ "&ratios=" ++ ratios(aicrop,空串也拼接,
// 与 Java String.format("...&ratios=%s") 行为一致)。
fn buildUrl(gpa: std.mem.Allocator, prefix: []const u8, img_url: []const u8, ratios: ?[]const u8) ![]u8 {
    const encoded = try mp_service.urlEncode(gpa, img_url);
    defer gpa.free(encoded);
    if (ratios) |r| {
        return std.mem.concat(gpa, u8, &.{ prefix, encoded, "&ratios=", r });
    }
    return std.mem.concat(gpa, u8, &.{ prefix, encoded });
}

// 内部:解析 WxOcrPos(四角坐标,均可缺省)。
fn parsePos(pos: std.json.Value) ?Pos {
    var p = Pos{};
    var seen = false;
    if (json_util.getObject(pos, "left_top")) |c| {
        if (coord(c)) |cd| {
            p.left_top = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "right_top")) |c| {
        if (coord(c)) |cd| {
            p.right_top = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "right_bottom")) |c| {
        if (coord(c)) |cd| {
            p.right_bottom = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "left_bottom")) |c| {
        if (coord(c)) |cd| {
            p.left_bottom = cd;
            seen = true;
        }
    }
    return if (seen) p else null;
}

fn coord(c: std.json.Value) ?Pos.Coordinate {
    const x = json_util.getInt(c, "x");
    const y = json_util.getInt(c, "y");
    if (x == null or y == null) return null;
    return .{ .x = x.?, .y = y.? };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "imgproc qrCode: encoded img_url + parse code_results" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "cv/img/qrcode", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"img_size\":{\"w\":400,\"h\":300},\"code_results\":[{\"type_name\":\"QR_CODE\",\"data\":\"https://example.com?x=1\",\"pos\":{\"left_top\":{\"x\":1,\"y\":2},\"right_top\":{\"x\":3,\"y\":2},\"right_bottom\":{\"x\":3,\"y\":4},\"left_bottom\":{\"x\":1,\"y\":4}}}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ImgProcService{ .svc = &base };

    const res = switch (s.qrCode(io, "https://img.example.com/a b.png?x=1")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = res;
        r.deinit();
    }
    // img_url 编码:空格 → +(Java URLEncoder 口径),? → %3F
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cv/img/qrcode?img_url=https%3A%2F%2Fimg.example.com%2Fa+b.png%3Fx%3D1") != null);
    try std.testing.expectEqualStrings("", m.last_body);
    try std.testing.expectEqual(@as(i64, 400), res.img_size.?.w);
    try std.testing.expectEqual(@as(i64, 300), res.img_size.?.h);
    try std.testing.expectEqual(@as(usize, 1), res.code_results.len);
    const c = res.code_results[0];
    try std.testing.expectEqualStrings("QR_CODE", c.type_name.?);
    try std.testing.expectEqualStrings("https://example.com?x=1", c.data.?);
    const pos = c.pos.?;
    try std.testing.expectEqual(@as(i64, 1), pos.left_top.?.x);
    try std.testing.expectEqual(@as(i64, 4), pos.left_bottom.?.y);
}

test "imgproc superResolution + aiCrop" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "cv/img/superresolution", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"MID1\"}" },
        .{ .match = "cv/img/aicrop", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"img_size\":{\"w\":100,\"h\":80},\"results\":[{\"crop_left\":1,\"crop_top\":2,\"crop_right\":99,\"crop_bottom\":78}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ImgProcService{ .svc = &base };

    // superResolution:GET,media_id
    const sr = switch (s.superResolution(io, "https://img.example.com/a.png")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = sr;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cv/img/superresolution?img_url=https%3A%2F%2Fimg.example.com%2Fa.png") != null);
    try std.testing.expectEqualStrings("MID1", sr.media_id.?);

    // aiCrop:POST,原始 ratios 追加在 img_url 之后
    const ac = switch (s.aiCropWithRatios(io, "https://img.example.com/a.png", "1,1.5")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = ac;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cv/img/aicrop?img_url=https%3A%2F%2Fimg.example.com%2Fa.png&ratios=1,1.5") != null);
    try std.testing.expectEqualStrings("", m.last_body);
    try std.testing.expectEqual(@as(i64, 100), ac.img_size.?.w);
    try std.testing.expectEqual(@as(usize, 1), ac.results.len);
    try std.testing.expectEqual(@as(i64, 1), ac.results[0].crop_left.?);
    try std.testing.expectEqual(@as(i64, 78), ac.results[0].crop_bottom.?);

    // aiCrop 无 ratios:URL 仍带空 `&ratios=`(与 Java String.format 一致)
    const ac2 = switch (s.aiCrop(io, "https://img.example.com/a.png")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = ac2;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "cv/img/aicrop?img_url=https%3A%2F%2Fimg.example.com%2Fa.png&ratios=") != null);
}
