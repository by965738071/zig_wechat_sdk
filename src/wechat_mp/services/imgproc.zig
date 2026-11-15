//! 公众号图像处理 —— 逐字对齐 Java `api.WxImgProcService` +
//! `api.impl.WxMpImgProcServiceImpl`,端点常量取自 `api_url.zig:ImgProc`
//! (镜像 Java `enums.WxMpApiUrl.ImgProc`,6 个常量,URL 变体带 `%s` 模板)。
//!
//! Java 接口 3 组方法(名称逐字对齐,impl:22-84;每组有 String img_url 与
//! File imgFile 两个重载):
//!   qrCode(imgUrl)          GET  cv/img/qrcode?img_url=%s
//!                           (**GET**,wxMpService.get(url, null))→ QrCodeResult
//!   superResolution(imgUrl) GET  cv/img/superresolution?img_url=%s
//!                           (**GET**)→ SuperResolutionResult
//!   aiCrop(imgUrl[,ratios]) POST cv/img/aicrop?img_url=%s&ratios=%s
//!                           (1 参重载委托 ratios="";**ratios 不做 URL 编码**;
//!                           POST **空字符串**请求体)→ AiCropResult
//!   文件变体:XFile(filename, content) —— OcrDiscernRequestExecutor:
//!     POST multipart/form-data 字段名 **file**(RFC6532),URL 为纯路径
//!     (FILE_QRCODE/FILE_SUPER_RESOLUTION);aiCrop(File[,ratios]) 的 URL 是
//!     `cv/img/aicrop?ratios=%s`(ratios 填模板,不编码)。组包复用
//!     `material.zig#buildMultipartBody`(field_name="file")。
//!
//! Java↔Zig 差异:
//!   - Java `get(url, null)` 语义 = 无请求体的 GET → Zig `svc.get(io, uri, &.{})`;
//!   - Java `post(url, "")` 语义 = POST 空串请求体 → Zig `svc.post(io, uri, &.{}, "")`;
//!   - bean 类名去 WxImgProc 前缀(QrCodeResult/SuperResolutionResult/AiCropResult);
//!   - Java `URLEncoder.encode` 空格编码为 `+`,`service.zig:urlEncode` 同口径。
//!
//! 内存所有权:各 Result struct 持 gpa,`deinit` 释放全部字符串/条目。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const random_mod = @import("common").random;
const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const material = @import("material.zig");
const ocr = @import("ocr.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
const WxError = result_mod.WxError;

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

// ---------------------------------------------------------------------------
// 结果 bean(common/bean/imgproc/*,字段名逐字对齐 @SerializedName)
// ---------------------------------------------------------------------------

/// 二维码识别条目(Java `WxImgProcQrCodeResult.CodeResult`:type_name/data/pos)。
pub const CodeResult = struct {
    gpa: std.mem.Allocator,
    type_name: []u8,
    data: []u8,
    pos: ocr.Pos,

    pub fn deinit(self: *CodeResult) void {
        self.gpa.free(self.type_name);
        self.gpa.free(self.data);
        self.* = undefined;
    }
};

/// Java `WxImgProcQrCodeResult`(img_size + code_results[])。
pub const QrCodeResult = struct {
    gpa: std.mem.Allocator,
    img_size: ocr.ImgSize,
    code_results: []CodeResult = &.{},

    pub fn deinit(self: *QrCodeResult) void {
        for (self.code_results) |*c| c.deinit();
        if (self.code_results.len != 0) self.gpa.free(self.code_results);
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !QrCodeResult {
        const size = json_util.getObject(v, "img_size");
        var results: std.ArrayList(CodeResult) = .empty;
        if (json_util.getArray(v, "code_results")) |arr| {
            for (arr.items) |el| {
                const o = json_util.object(el) orelse continue;
                const ov = json_util.Value{ .object = o };
                try results.append(gpa, .{
                    .gpa = gpa,
                    .type_name = gpa.dupe(u8, json_util.getStrOr(ov, "type_name", "")) catch return error.OutOfMemory,
                    .data = gpa.dupe(u8, json_util.getStrOr(ov, "data", "")) catch return error.OutOfMemory,
                    .pos = ocr.posOfField(ov, "pos"),
                });
            }
        }
        return .{
            .gpa = gpa,
            .img_size = if (size) |s| .{
                .w = json_util.getIntOr(s, "w", 0),
                .h = json_util.getIntOr(s, "h", 0),
            } else .{},
            .code_results = try results.toOwnedSlice(gpa),
        };
    }
};

/// Java `WxImgProcSuperResolutionResult`(media_id)。
pub const SuperResolutionResult = struct {
    gpa: std.mem.Allocator,
    media_id: []u8,

    pub fn deinit(self: *SuperResolutionResult) void {
        self.gpa.free(self.media_id);
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !SuperResolutionResult {
        return .{ .gpa = gpa, .media_id = gpa.dupe(u8, json_util.getStrOr(v, "media_id", "")) catch return error.OutOfMemory };
    }
};

/// 裁剪条目(Java `WxImgProcAiCropResult.CropResult`:crop_left/top/right/bottom)。
pub const CropResult = struct {
    crop_left: i64 = 0,
    crop_top: i64 = 0,
    crop_right: i64 = 0,
    crop_bottom: i64 = 0,
};

/// Java `WxImgProcAiCropResult`(img_size + results[])。
pub const AiCropResult = struct {
    gpa: std.mem.Allocator,
    img_size: ocr.ImgSize,
    results: []CropResult = &.{},

    pub fn deinit(self: *AiCropResult) void {
        if (self.results.len != 0) self.gpa.free(self.results);
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !AiCropResult {
        const size = json_util.getObject(v, "img_size");
        var results: std.ArrayList(CropResult) = .empty;
        if (json_util.getArray(v, "results")) |arr| {
            for (arr.items) |el| {
                try results.append(gpa, .{
                    .crop_left = json_util.getIntOr(el, "crop_left", 0),
                    .crop_top = json_util.getIntOr(el, "crop_top", 0),
                    .crop_right = json_util.getIntOr(el, "crop_right", 0),
                    .crop_bottom = json_util.getIntOr(el, "crop_bottom", 0),
                });
            }
        }
        return .{
            .gpa = gpa,
            .img_size = if (size) |s| .{
                .w = json_util.getIntOr(s, "w", 0),
                .h = json_util.getIntOr(s, "h", 0),
            } else .{},
            .results = try results.toOwnedSlice(gpa),
        };
    }
};

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

pub const ImgProcService = struct {
    svc: *service_mod.Service,

    /// 对应 `#qrCode(String)`(impl:24-32):GET cv/img/qrcode?img_url=%s → QrCodeResult。
    pub fn qrCode(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(QrCodeResult) {
        const gpa = self.svc.gpa;
        const parsed = switch (getDiscern(self, io, api_url.ImgProc.qrcode, img_url)) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer parsed.deinit();
        return .{ .ok = QrCodeResult.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "imgproc response parse failed", .{}) } };
    }

    /// 对应 `#superResolution(String)`(impl:46-54):
    /// GET cv/img/superresolution?img_url=%s → SuperResolutionResult。
    pub fn superResolution(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(SuperResolutionResult) {
        const gpa = self.svc.gpa;
        const parsed = switch (getDiscern(self, io, api_url.ImgProc.super_resolution, img_url)) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer parsed.deinit();
        return .{ .ok = SuperResolutionResult.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "imgproc response parse failed", .{}) } };
    }

    /// 对应 `#aiCrop(String)`(impl:66-68):1 参重载,ratios=""。
    pub fn aiCrop(self: *ImgProcService, io: std.Io, img_url: []const u8) WxResult(AiCropResult) {
        return self.aiCropWithRatios(io, img_url, "");
    }

    /// 对应 `#aiCrop(String,String)`(impl:70-84):
    /// POST cv/img/aicrop?img_url=%s&ratios=%s(空请求体;ratios 不编码)→ AiCropResult。
    pub fn aiCropWithRatios(self: *ImgProcService, io: std.Io, img_url: []const u8, ratios: []const u8) WxResult(AiCropResult) {
        const gpa = self.svc.gpa;
        const enc = service_mod.urlEncode(gpa, img_url) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(enc);
        // ratios 逐字透传(Java 未对其 encode)
        const filled = h.fillPath(gpa, api_url.ImgProc.ai_crop, &.{ enc, ratios }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(filled);
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, filled }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.post(io, uri, &.{}, "")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = AiCropResult.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "imgproc response parse failed", .{}) } };
    }

    // ------------------ 文件变体(impl 各 File 重载) ------------------

    /// 对应 `#qrCode(File)`(impl:34-39):POST multipart 字段 file → QrCodeResult。
    pub fn qrCodeFile(self: *ImgProcService, io: std.Io, filename: []const u8, content: []const u8) WxResult(QrCodeResult) {
        return discernFileThen(self, io, api_url.ImgProc.file_qrcode, filename, content, QrCodeResult);
    }

    /// 对应 `#superResolution(File)`(impl:56-61):multipart → SuperResolutionResult。
    pub fn superResolutionFile(self: *ImgProcService, io: std.Io, filename: []const u8, content: []const u8) WxResult(SuperResolutionResult) {
        return discernFileThen(self, io, api_url.ImgProc.file_super_resolution, filename, content, SuperResolutionResult);
    }

    /// 对应 `#aiCrop(File)`(impl:95-98):1 参重载,ratios=""。
    pub fn aiCropFile(self: *ImgProcService, io: std.Io, filename: []const u8, content: []const u8) WxResult(AiCropResult) {
        return self.aiCropFileWithRatios(io, filename, content, "");
    }

    /// 对应 `#aiCrop(File,String)`(impl:100-107):
    /// POST multipart 字段 file → cv/img/aicrop?ratios=%s(ratios 填模板,不编码)。
    pub fn aiCropFileWithRatios(self: *ImgProcService, io: std.Io, filename: []const u8, content: []const u8, ratios: []const u8) WxResult(AiCropResult) {
        const filled = h.fillPath(self.svc.gpa, api_url.ImgProc.file_ai_crop, &.{ratios}) catch
            return .{ .err = oom(self.svc.gpa) };
        defer self.svc.gpa.free(filled);
        return discernFileThen(self, io, filled, filename, content, AiCropResult);
    }

    /// GET 变体共用通路:`URLEncoder.encode(imgUrl)` → `String.format(path)`
    /// → `get(url, null)`(无请求体 GET)→ bean.fromJson(result)。
    fn getDiscern(self: *ImgProcService, io: std.Io, comptime path: []const u8, img_url: []const u8) WxResult(std.json.Parsed(json_util.Value)) {
        const gpa = self.svc.gpa;
        const enc = service_mod.urlEncode(gpa, img_url) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(enc);
        const filled = h.fillPath(gpa, path, &.{enc}) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(filled);
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, filled }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc response not json", .{}) };
        return .{ .ok = parsed };
    }

    /// 文件变体共用通路(对应 OcrDiscernRequestExecutor):
    /// POST multipart/form-data(字段名 file,RFC6532)→ T.fromJson。
    /// path 允许带 query(aiCrop 文件变体的 `?ratios=` 模板已填好)。
    fn discernFileThen(self: *ImgProcService, io: std.Io, path: []const u8, filename: []const u8, content: []const u8, comptime T: type) WxResult(T) {
        const gpa = self.svc.gpa;
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(boundary);
        const body = material.buildMultipartBody(gpa, boundary, "file", filename, content, null) catch |e|
            return .{ .err = WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);
        const ct = material.multipartContentType(gpa, boundary) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{
            .{ .name = "Content-Type", .value = ct },
        };
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "imgproc response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = T.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "imgproc response parse failed", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:3 端点 URL/method/请求体 + 各 bean 字段
// (逐字对照 WxMpApiUrl.ImgProc + WxMpImgProcServiceImpl)
// ---------------------------------------------------------------------------

test "ImgProc 契约: 3 端点 URL/method/请求体 + bean 字段 (WxMpApiUrl.ImgProc)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cv/img/qrcode", .response = "{\"errcode\":0,\"img_size\":{\"w\":200,\"h\":200},\"code_results\":[{\"type_name\":\"QR_CODE\",\"data\":\"https://weixin.qq.com/x\"}]}" },
        .{ .match = "cv/img/superresolution", .response = "{\"errcode\":0,\"media_id\":\"MEDIA_ID_1\"}" },
        .{ .match = "cv/img/aicrop", .response = "{\"errcode\":0,\"img_size\":{\"w\":1000,\"h\":800},\"results\":[{\"crop_left\":10,\"crop_top\":20,\"crop_right\":300,\"crop_bottom\":400},{\"crop_left\":1,\"crop_top\":2,\"crop_right\":3,\"crop_bottom\":4}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = ImgProcService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    const img = "https://example.com/a b.jpg";

    var qr = switch (svc.qrCode(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer qr.deinit();
    try std.testing.expectEqual(@as(i64, 200), qr.img_size.w);
    try std.testing.expectEqual(@as(usize, 1), qr.code_results.len);
    try std.testing.expectEqualStrings("QR_CODE", qr.code_results[0].type_name);
    try std.testing.expectEqualStrings("https://weixin.qq.com/x", qr.code_results[0].data);

    var sr = switch (svc.superResolution(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer sr.deinit();
    try std.testing.expectEqualStrings("MEDIA_ID_1", sr.media_id);

    var crop = switch (svc.aiCrop(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer crop.deinit();
    try std.testing.expectEqual(@as(usize, 2), crop.results.len);
    try std.testing.expectEqual(@as(i64, 10), crop.results[0].crop_left);
    try std.testing.expectEqual(@as(i64, 400), crop.results[0].crop_bottom);

    // 3 次;前两次 GET,aiCrop POST 空请求体。
    // URL:img_url 编码(空格 → '+'),ratios 逐字透传(逗号不编码)。
    var crop2 = switch (svc.aiCropWithRatios(io, img, "1,2")) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer crop2.deinit();
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "cv/img/aicrop?img_url=https%3A%2F%2Fexample.com%2Fa+b.jpg&ratios=1%2C2") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "cv/img/aicrop?img_url=https%3A%2F%2Fexample.com%2Fa+b.jpg&ratios=1,2") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    try std.testing.expectEqualStrings("post", mock.last_method);
    try std.testing.expectEqualStrings("", mock.body());
}

test "ImgProc 文件变体: 3 端点 multipart(字段名 file)+ bean 字段 (WxMpApiUrl.ImgProc.File*)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cv/img/qrcode", .response = "{\"errcode\":0,\"code_results\":[{\"type_name\":\"QR_CODE\",\"data\":\"D1\"}]}" },
        .{ .match = "cv/img/superresolution", .response = "{\"errcode\":0,\"media_id\":\"M2\"}" },
        .{ .match = "cv/img/aicrop", .response = "{\"errcode\":0,\"results\":[{\"crop_left\":7}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = ImgProcService{ .svc = &fx.svc };
    const io = fx.threaded.io();
    const fname = "qr.jpg";
    const bytes = "JPEG_FAKE";

    var qr = switch (svc.qrCodeFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer qr.deinit();
    try std.testing.expectEqualStrings("D1", qr.code_results[0].data);

    var sr = switch (svc.superResolutionFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer sr.deinit();
    try std.testing.expectEqualStrings("M2", sr.media_id);

    // aiCrop(File):URL 带 ?ratios=(空串);1 参重载委托
    var crop = switch (svc.aiCropFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer crop.deinit();
    try std.testing.expectEqual(@as(i64, 7), crop.results[0].crop_left);

    // aiCrop(File, ratios):ratios 逐字填模板(不编码)
    var crop2 = switch (svc.aiCropFileWithRatios(io, fname, bytes, "1,1.5")) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer crop2.deinit();

    try std.testing.expectEqual(@as(usize, 4), mock.calls);
    try std.testing.expectEqualStrings("post", mock.last_method);
    // 最后一次是 aiCropFileWithRatios:URI 含 cv/img/aicrop?ratios=1,1.5(无编码)
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "cv/img/aicrop?ratios=1,1.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const body = mock.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"file\"; filename=\"qr.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "JPEG_FAKE") != null);
}
