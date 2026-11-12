//! mp 子服务共享的 URL 拼接 / 离线契约测试脚手架（仅被 wechat_mp/services 内部 import）。
//! 形状对齐 `services/user.zig` 的 URecorder/UFakeFetch/uSetup 与
//! `services/template_msg.zig` 的 apiGet/apiPost/postVoid；不对外导出、不引入新依赖。
const std = @import("std");

const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const u_error = @import("common").error_util;
const u_token = @import("common").token;

const u_config = @import("../config.zig");
const u_http = @import("../http.zig");
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
pub const WxError = result_mod.WxError;

// ---------------------------------------------------------------------------
// 请求:拼 host → svc.get/post（token 附加 + errcode 折叠 + 重试都在 Service）
// ---------------------------------------------------------------------------

pub fn apiUri(svc: *service_mod.Service, path: []const u8) WxResult([]u8) {
    return .{ .ok = std.fmt.allocPrint(svc.gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
        return .{ .err = WxError.internal(svc.gpa, "oom", .{}) } };
}

pub fn apiGet(svc: *service_mod.Service, io: std.Io, path: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.get(io, uri, &.{});
}

pub fn apiPost(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) WxResult([]u8) {
    const uri = switch (apiUri(svc, path)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    defer svc.gpa.free(uri);
    return svc.post(io, uri, &.{}, body);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 Service.executeInternal 折叠为 .err)。
pub fn postVoid(svc: *service_mod.Service, io: std.Io, path: []const u8, body: []const u8) Done {
    const resp = switch (apiPost(svc, io, path, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    svc.gpa.free(resp);
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// 响应字段解析(对应 Java GsonParser.parse(json).get(key))
// ---------------------------------------------------------------------------

/// 取字符串字段并 dupe(调用方 free)。对应 impl 里 `.get(key).getAsString()`。
pub fn strField(gpa: std.mem.Allocator, body: []const u8, key: []const u8) WxResult([]u8) {
    const parsed = json_util.parse(gpa, body) catch
        return .{ .err = WxError.transport(gpa, "response not json", .{}) };
    defer parsed.deinit();
    const s = json_util.getStr(parsed.value, key) orelse
        return .{ .err = WxError.transport(gpa, "response missing field", .{}) };
    return .{ .ok = gpa.dupe(u8, s) catch
        return .{ .err = WxError.internal(gpa, "oom", .{}) } };
}

/// 取整数字段。对应 impl 里 `Long.valueOf(...get("total_count")...)` 等。
pub fn intField(gpa: std.mem.Allocator, body: []const u8, key: []const u8) WxResult(i64) {
    const parsed = json_util.parse(gpa, body) catch
        return .{ .err = WxError.transport(gpa, "response not json", .{}) };
    defer parsed.deinit();
    return .{ .ok = json_util.getIntOr(parsed.value, key, 0) };
}

/// {"news_item":[...]} —— 对应 WxMpDraftInfo / WxMpFreePublishInfo 的
/// @SerializedName("news_item");取数组长度与首项 title(@SerializedName("title"))。
pub const NewsInfo = struct {
    gpa: std.mem.Allocator,
    count: usize = 0,
    first_title: []u8,

    pub fn deinit(self: *NewsInfo) void {
        self.gpa.free(self.first_title);
        self.* = undefined;
    }
};

pub fn parseNewsItem(gpa: std.mem.Allocator, v: json_util.Value) !NewsInfo {
    var count: usize = 0;
    var title: []const u8 = "";
    if (json_util.getArray(v, "news_item")) |arr| {
        count = arr.items.len;
        if (arr.items.len > 0) title = json_util.getStrOr(arr.items[0], "title", "");
    }
    return .{ .gpa = gpa, .count = count, .first_title = try gpa.dupe(u8, title) };
}

/// {"total_count","item_count","item":[...]} —— 对应 WxMpDraftList /
/// WxMpFreePublishList 的 @SerializedName 字段(纯值,无需 deinit)。
pub const ListCounts = struct {
    total_count: i64 = 0,
    item_count: i64 = 0,
    item_len: usize = 0,
};

pub fn parseListCounts(v: json_util.Value) ListCounts {
    var r = ListCounts{};
    r.total_count = json_util.getIntOr(v, "total_count", 0);
    r.item_count = json_util.getIntOr(v, "item_count", 0);
    if (json_util.getArray(v, "item")) |arr| r.item_len = arr.items.len;
    return r;
}

/// {"<key>":["a","b"]} —— 对应 Java `map.put("openid_list", list)` 的 Gson 序列化。
pub fn strArrayBody(gpa: std.mem.Allocator, key: []const u8, items: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeByte('{');
    try encStr(w, key);
    try w.writeAll(":[");
    for (items, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try encStr(w, s);
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn encStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
}

/// 字符串数组 → std.json.Value(.array):对应 Java `List<String>` 经 Gson 序列化,
/// 供需要手工拼嵌套对象(Map/JsonObject)的子服务 putValue 复用(内存在 arena 上)。
pub fn strArrayValue(a: std.mem.Allocator, items: []const []const u8) !json_util.Value {
    var arr: std.ArrayList(json_util.Value) = .empty;
    for (items) |s| try arr.append(a, .{ .string = s });
    return .{ .array = arr };
}

// ---------------------------------------------------------------------------
// 离线契约测试脚手架(记录型 executor + 配置,逐字对齐 user.zig 的 URecorder)
// ---------------------------------------------------------------------------

pub const Entry = struct { match: []const u8, response: []const u8 };

pub const Recorder = struct {
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    pub fn uri(self: *const Recorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    pub fn body(self: *const Recorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
    pub fn executor(self: *Recorder) u_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: u_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = @tagName(method);
        self.last_uri_len = @min(target.len, self.last_uri.len);
        @memcpy(self.last_uri[0..self.last_uri_len], target[0..self.last_uri_len]);
        const b = payload orelse "";
        self.last_body_len = @min(b.len, self.last_body.len);
        @memcpy(self.last_body[0..self.last_body_len], b[0..self.last_body_len]);
        for (self.entries) |e| {
            if (std.mem.indexOf(u8, target, e.match) != null) {
                return .{ .ok = gpa.dupe(u8, e.response) catch
                    return .{ .err = u_error.WxError.transport(gpa, "oom", .{}) } };
            }
        }
        return .{ .err = u_error.WxError.transport(gpa, "mock miss", .{}) };
    }
    const vtable = u_http.RequestExecutor.VTable{ .execute = executeImpl };
};

pub const FakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) u_token.FetchOutcome {
        _ = c;
        _ = i;
        const t = g.dupe(u8, "TOK") catch
            return .{ .err = u_error.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = t, .expires_in = 7200 } };
    }
};

pub const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    cfg: u_config.InMemoryConfigStorage = undefined,
    svc: service_mod.Service = undefined,
};

pub fn setup(gpa: std.mem.Allocator, mock: *Recorder, fx: *Fixture) !void {
    fx.threaded = std.Io.Threaded.init(gpa, .{});
    errdefer fx.threaded.deinit();
    fx.cfg = try u_config.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer fx.cfg.deinit();
    fx.svc = service_mod.Service.init(gpa, fx.cfg.config(), mock.executor());
}

pub fn teardown(fx: *Fixture) void {
    fx.threaded.deinit();
    fx.cfg.deinit();
}
