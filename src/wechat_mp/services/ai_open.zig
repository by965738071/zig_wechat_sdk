//! 微信智能开放服务 —— 逐字对齐 Java `api.WxMpAiOpenService` +
//! `api.impl.WxMpAiOpenServiceImpl`,端点常量取自 `api_url.zig:AiOpen`
//! (镜像 Java `enums.WxMpApiUrl.AiOpen`,3 个常量,均带 `%s` 模板)。
//!
//! Java 接口 4 个方法(名称逐字对齐,impl:22-59):
//!   translate(lfrom,lto,content)   POST cgi-bin/media/voice/translatecontent
//!                                  ?lfrom=%s&lto=%s(语言码填模板) 8
//!                                  **请求体是原始字符串 content(非 JSON)**
//!                                  → to_content
//!   queryRecognitionResult(voiceId,lang)
//!                                  GET cgi-bin/media/voice/queryrecoresultfortext
//!                                  ?voice_id=..&lang=.. → result
//!   uploadVoice(voiceId,lang,voiceFile)
//!                                  POST cgi-bin/media/voice/addvoicetorecofortext
//!                                  ?format=mp3&voice_id=%s&lang=%s
//!                                  multipart 字段 `media`(Apache addBinaryBody)
//!   recogniseVoice = uploadVoice + queryRecognitionResult
//!
//! Java↔Zig 差异:
//!   - `AiLangType` 枚举仅 zh_CN/en_US → `Lang` 常量 + 空串默认 zh_CN
//!     (Java 的 `if (lang == null) lang = zh_CN`);
//!   - Java `File voiceFile` → `filename + content`(内存字节,multipart 组包
//!     复用 `material.zig` 的 `buildMultipartBody`/`multipartContentType`,
//!     与 `media.zig#uploadMultipart` 逐字同构);
//!   - translate 的请求体逐字透传(Java `this.post(url, content)` 原样发字符串)。
//!
//! 内存所有权:`.ok` 字符串 gpa 拥有,调用方 `free`。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const material = @import("material.zig");
const random_mod = @import("common").random;
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;

/// 对应 Java `AiLangType`(仅两种;null → zh_CN 由 langOr 处理)。
pub const Lang = struct {
    pub const zh_CN = "zh_CN";
    pub const en_US = "en_US";
};

/// lang 空串 → 默认 zh_CN(对应 Java `if (lang == null) lang = AiLangType.zh_CN`)。
fn langOr(lang: []const u8) []const u8 {
    return if (lang.len == 0) Lang.zh_CN else lang;
}

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

/// 用 params 逐个填充 path 中的 `%s` 模板(实现提升到 `sub_util.zig:h.fillPath`,
/// 与 ocr/imgproc 共用)。
const fillPath = h.fillPath;

pub const AiOpenService = struct {
    svc: *service_mod.Service,

    /// 对应 `#translate`(impl:50-59):POST ?lfrom=..&lto=..(语言码填 `%s` 模板),
    /// **请求体是原始字符串 content**(Java `this.post(url, content)` 原样发出)
    /// → 取 `to_content`。
    pub fn translate(self: *AiOpenService, io: std.Io, lfrom: []const u8, lto: []const u8, content: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const path = fillPath(gpa, api_url.AiOpen.translate_url, &.{ lfrom, lto }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(path);
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        // 请求体原样透传(非 JSON;content 是待翻译文本)
        const resp = switch (self.svc.post(io, uri, &.{}, content)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "translatecontent response not json", .{}) };
        defer parsed.deinit();
        const to = json_util.getStr(parsed.value, "to_content") orelse
            return .{ .err = WxError.transport(gpa, "translatecontent response missing to_content", .{}) };
        return .{ .ok = gpa.dupe(u8, to) catch return .{ .err = oom(gpa) } };
    }

    /// 对应 `#queryRecognitionResult`(impl:32-42):
    /// GET ?voice_id=..&lang=.. → `result`(gpa 拥有,调用方 free)。
    pub fn queryRecognitionResult(self: *AiOpenService, io: std.Io, voice_id: []const u8, lang: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}?voice_id={s}&lang={s}", .{
            service_mod.api_host_url, api_url.AiOpen.voice_query_result_url, voice_id, langOr(lang),
        }) catch return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "queryrecoresultfortext response not json", .{}) };
        defer parsed.deinit();
        const result = json_util.getStr(parsed.value, "result") orelse
            return .{ .err = WxError.transport(gpa, "queryrecoresultfortext response missing result", .{}) };
        return .{ .ok = gpa.dupe(u8, result) catch return .{ .err = oom(gpa) } };
    }

    /// 对应 `#uploadVoice`(impl:20-30):POST addvoicetorecofortext
    /// ?format=mp3&voice_id=..&lang=..,multipart 字段 `media`
    /// (Apache `addBinaryBody("media", file)`;filename 取语音文件名)。
    pub fn uploadVoice(self: *AiOpenService, io: std.Io, voice_id: []const u8, lang: []const u8, filename: []const u8, content: []const u8) Done {
        const gpa = self.svc.gpa;
        const path = fillPath(gpa, api_url.AiOpen.voice_upload_url, &.{ "mp3", voice_id, langOr(lang) }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(path);
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);

        // multipart 组包(与 media.zig#uploadMultipart 逐字同构)
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(boundary);
        const body = material.buildMultipartBody(gpa, boundary, "media", filename, content, null) catch |e|
            return .{ .err = WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);
        const ct = material.multipartContentType(gpa, boundary) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{
            .{ .name = "Content-Type", .value = ct },
        };
        const resp = switch (self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `#recogniseVoice`(impl:44-48):uploadVoice + queryRecognitionResult。
    pub fn recogniseVoice(self: *AiOpenService, io: std.Io, voice_id: []const u8, lang: []const u8, filename: []const u8, content: []const u8) WxResult([]u8) {
        switch (self.uploadVoice(io, voice_id, lang, filename, content)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
        return self.queryRecognitionResult(io, voice_id, lang);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:3 端点 URL/method/请求体(translate 原始字符串体 + multipart 字段名)
// (逐字对照 WxMpApiUrl.AiOpen + WxMpAiOpenServiceImpl)
// ---------------------------------------------------------------------------

test "AiOpen 契约: translate 原始字符串体 + URL 模板 (WxMpApiUrl.AiOpen)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "translatecontent", .response = "{\"errcode\":0,\"to_content\":\"hello\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = AiOpenService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    switch (svc.translate(io, Lang.zh_CN, Lang.en_US, "今天天气怎么样")) {
        .ok => |t| {
            defer gpa.free(t);
            try testing.expectEqualStrings("hello", t);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAiOpenTranslate;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    // URL 模板:%s 由语言码填充(lfrom=zh_CN&lto=en_US)
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/voice/translatecontent?lfrom=zh_CN&lto=en_US") != null);
    // 请求体是原始字符串(非 JSON,无引号包裹)
    try testing.expectEqualStrings("今天天气怎么样", mock.body());
}

test "AiOpen 契约: queryRecognitionResult 默认 zh_CN + recogniseVoice 链路" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "addvoicetorecofortext", .response = "{\"errcode\":0}" },
        .{ .match = "queryrecoresultfortext", .response = "{\"errcode\":0,\"result\":\"今天天气怎么样\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = AiOpenService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // uploadVoice: format=mp3 固定 + multipart 字段名 media
    switch (svc.uploadVoice(io, "VID1", "", "voice.mp3", "\x00\x01mp3bytes")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAiOpenUploadVoice;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/voice/addvoicetorecofortext?format=mp3&voice_id=VID1&lang=zh_CN") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "name=\"media\"; filename=\"voice.mp3\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "mp3bytes") != null);

    // queryRecognitionResult: lang 空串默认 zh_CN
    switch (svc.queryRecognitionResult(io, "VID1", "")) {
        .ok => |r| {
            defer gpa.free(r);
            try testing.expectEqualStrings("今天天气怎么样", r);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAiOpenQueryResult;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/media/voice/queryrecoresultfortext?voice_id=VID1&lang=zh_CN") != null);

    // recogniseVoice = upload + query
    switch (svc.recogniseVoice(io, "VID1", Lang.zh_CN, "voice.mp3", "\x00\x01mp3bytes")) {
        .ok => |r| {
            defer gpa.free(r);
            try testing.expectEqualStrings("今天天气怎么样", r);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedAiOpenRecognise;
        },
    }
    try testing.expectEqual(@as(usize, 4), mock.calls);
}
