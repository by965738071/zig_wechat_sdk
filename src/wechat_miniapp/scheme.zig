//! scheme 码服务 —— 对应 Java `api.WxMaSchemeService` + `api.impl.WxMaSchemeServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Scheme`:
//! - generate:POST /wxa/generatescheme(请求含 jump_wxa 嵌套对象,序列化对齐
//!   Gson 默认策略:null 字段省略,env_version 默认 "release")→ openlink;
//! - generateNFC:POST /wxa/generatenfcscheme(jump_wxa + model_id + sn)→ openlink。
//! errcode≠0 已由基座折叠为 `.err`;openlink 为 gpa 拥有字符串。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const GENERATE_SCHEME_URL = "https://api.weixin.qq.com/wxa/generatescheme";
const GENERATE_NFC_SCHEME_URL = "https://api.weixin.qq.com/wxa/generatenfcscheme";

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

/// 对应 `scheme.WxMaGenerateSchemeRequest.JumpWxa`
/// (env_version 默认 "release",与 Java 字段默认值对齐)。
pub const JumpWxa = struct {
    path: []const u8,
    query: ?[]const u8 = null,
    env_version: []const u8 = "release",

    fn writeJson(self: JumpWxa, w: *std.Io.Writer) !void {
        try w.writeAll("{\"path\":");
        try js(w, self.path);
        if (self.query) |q| {
            try w.writeAll(",\"query\":");
            try js(w, q);
        }
        try w.writeAll(",\"env_version\":");
        try js(w, self.env_version);
        try w.writeAll("}");
    }
};

/// 对应 `scheme.WxMaGenerateSchemeRequest`(null 字段省略)。
pub const GenerateSchemeRequest = struct {
    jump_wxa: ?JumpWxa = null,
    is_expire: ?bool = null,
    expire_time: ?i64 = null,
    expire_type: ?i64 = null,
    expire_interval: ?i64 = null,

    pub fn to_json(self: GenerateSchemeRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var first = true;
        if (self.jump_wxa) |jw| {
            try w.writeAll("\"jump_wxa\":");
            try jw.writeJson(w);
            first = false;
        }
        if (self.is_expire) |b| {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"is_expire\":");
            try w.writeAll(if (b) "true" else "false");
            first = false;
        }
        inline for (.{ "expire_time", "expire_type", "expire_interval" }) |f| {
            if (@field(self, f)) |v| {
                if (!first) try w.writeAll(",");
                try w.writeAll("\"" ++ f ++ "\":");
                try jsInt(w, v);
                first = false;
            }
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `scheme.WxMaGenerateNfcSchemeRequest`(jump_wxa + model_id + sn)。
pub const GenerateNfcSchemeRequest = struct {
    jump_wxa: JumpWxa,
    model_id: []const u8,
    sn: []const u8,

    pub fn to_json(self: GenerateNfcSchemeRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"jump_wxa\":");
        try self.jump_wxa.writeJson(w);
        try w.writeAll(",\"model_id\":");
        try js(w, self.model_id);
        try w.writeAll(",\"sn\":");
        try js(w, self.sn);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

// --- service -------------------------------------------------------------------

pub const SchemeService = struct {
    svc: *mp_service.Service,

    /// 对应 `generate(WxMaGenerateSchemeRequest)`:POST /wxa/generatescheme
    /// → openlink(gpa 拥有,调用方 free)。
    pub fn generate(self: *SchemeService, io: std.Io, req: GenerateSchemeRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GENERATE_SCHEME_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "generatescheme not json", .{}) };
        defer parsed.deinit();
        const openlink = json_util.getStr(parsed.value, "openlink") orelse
            return .{ .err = WxError.transport(gpa, "generatescheme missing openlink", .{}) };
        return .{ .ok = gpa.dupe(u8, openlink) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `generateNFC(WxMaGenerateNfcSchemeRequest)`:POST /wxa/generatenfcscheme
    /// → openlink(gpa 拥有,调用方 free)。
    pub fn generateNFC(self: *SchemeService, io: std.Io, req: GenerateNfcSchemeRequest) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GENERATE_NFC_SCHEME_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "generatenfcscheme not json", .{}) };
        defer parsed.deinit();
        const openlink = json_util.getStr(parsed.value, "openlink") orelse
            return .{ .err = WxError.transport(gpa, "generatenfcscheme missing openlink", .{}) };
        return .{ .ok = gpa.dupe(u8, openlink) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "scheme generate: nested jump_wxa body + openlink" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "generatescheme", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openlink\":\"weixin://dl/business/?t=AAA\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SchemeService{ .svc = &base };

    const link = switch (s.generate(io, .{
        .jump_wxa = .{ .path = "pages/index/index", .query = "a=1&b=2" },
        .is_expire = true,
        .expire_type = 1,
        .expire_interval = 30,
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(link);
    try std.testing.expectEqualStrings("weixin://dl/business/?t=AAA", link);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/generatescheme") != null);
    // 嵌套 jump_wxa + null 字段省略(expire_time 未设置不出现)
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    const jw = json_util.getObject(parsed.value, "jump_wxa").?;
    try std.testing.expectEqualStrings("pages/index/index", json_util.getStr(jw, "path").?);
    try std.testing.expectEqualStrings("a=1&b=2", json_util.getStr(jw, "query").?);
    try std.testing.expectEqualStrings("release", json_util.getStr(jw, "env_version").?);
    try std.testing.expectEqual(true, json_util.getBool(parsed.value, "is_expire").?);
    try std.testing.expectEqual(@as(?i64, 1), json_util.getInt(parsed.value, "expire_type"));
    try std.testing.expectEqual(@as(?i64, 30), json_util.getInt(parsed.value, "expire_interval"));
    try std.testing.expect(json_util.getObject(parsed.value, "expire_time") == null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "expire_time") == null);
}

test "scheme generateNFC: model_id + sn body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "generatenfcscheme", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openlink\":\"weixin://dl/business/nfc/?t=BBB\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = SchemeService{ .svc = &base };

    const link = switch (s.generateNFC(io, .{
        .jump_wxa = .{ .path = "pages/nfc/index" },
        .model_id = "model-1",
        .sn = "SN-001",
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(link);
    try std.testing.expectEqualStrings("weixin://dl/business/nfc/?t=BBB", link);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("model-1", json_util.getStr(parsed.value, "model_id").?);
    try std.testing.expectEqualStrings("SN-001", json_util.getStr(parsed.value, "sn").?);
    // query 为 null 时省略(对应 Gson null 省略)
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "query") == null);
}
