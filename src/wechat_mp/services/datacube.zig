//! 统计分析服务 —— 对应 Java `api.WxMpDataCubeService` +
//! `api.impl.WxMpDataCubeServiceImpl`。
//!
//! 全部接口同形:POST `{"begin_date":..,"end_date":..}` → `{"list":[{..},..]}`。
//! 17 项 URL 逐字对应 Java `enums.WxMpApiUrl.DataCube` 常量(用户/图文/分享/
//! 上行消息/接口分析五族);
//! `getarticleshare/getarticledetail/getupdatetime` 在本 checkout 的 Java 枚举中
//! **不存在**(新版官方文档接口),按任务清单以常量表补齐并逐一实现。
//!
//! 行解析:每行提取 `ref_date`(字符串)/`ref_hour`(整数,分时接口才有),
//! 其余数值字段收敛为 name→i64 映射(`Row.value` 按原始字段名取值)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;

/// 接口清单常量表 —— 对应 Java `WxMpApiUrl.DataCube`(注释标注 Java 常量名)。
pub const Path = struct {
    /// `GET_USER_SUMMARY`:用户增减数据。
    pub const get_user_summary = "datacube/getusersummary";
    /// `GET_USER_CUMULATE`:累计用户数据。
    pub const get_user_cumulate = "datacube/getusercumulate";
    /// `GET_USER_READ`:图文统计数据。
    pub const get_user_read = "datacube/getuserread";
    /// `GET_USER_READ_HOUR`:图文统计分时数据。
    pub const get_user_read_hour = "datacube/getuserreadhour";
    /// `GET_USER_SHARE`:图文分享转发数据。
    pub const get_user_share = "datacube/getusershare";
    /// `GET_USER_SHARE_HOUR`:图文分享转发分时数据。
    pub const get_user_share_hour = "datacube/getusersharehour";
    /// `GET_ARTICLE_SUMMARY`:图文群发每日数据。
    pub const get_article_summary = "datacube/getarticlesummary";
    /// `GET_ARTICLE_TOTAL`:图文群发总数据。
    pub const get_article_total = "datacube/getarticletotal";
    /// 图文分享数据 —— Java 枚举无此常量(官方文档 /datacube/getarticleshare)。
    pub const get_article_share = "datacube/getarticleshare";
    /// 图文详细数据 —— Java 枚举无此常量(官方文档 /datacube/getarticledetail)。
    pub const get_article_detail = "datacube/getarticledetail";
    /// 数据时间 —— Java 枚举无此常量(官方文档 /datacube/getupdatetime)。
    pub const get_updatetime = "datacube/getupdatetime";
    /// `GET_UPSTREAM_MSG`:消息发送概况数据。
    pub const get_upstream_msg = "datacube/getupstreammsg";
    /// `GET_UPSTREAM_MSG_HOUR`:消息发送概况分时数据。
    pub const get_upstream_msg_hour = "datacube/getupstreammsghour";
    /// `GET_UPSTREAM_MSG_WEEK`:消息发送概况周数据。
    pub const get_upstream_msg_week = "datacube/getupstreammsgweek";
    /// `GET_UPSTREAM_MSG_MONTH`:消息发送概况月数据。
    pub const get_upstream_msg_month = "datacube/getupstreammsgmonth";
    /// `GET_UPSTREAM_MSG_DIST`:消息发送分布数据。
    pub const get_upstream_msg_dist = "datacube/getupstreammsgdist";
    /// `GET_UPSTREAM_MSG_DIST_WEEK`:消息发送分布周数据。
    pub const get_upstream_msg_dist_week = "datacube/getupstreammsgdistweek";
    /// `GET_UPSTREAM_MSG_DIST_MONTH`:消息发送分布月数据。
    pub const get_upstream_msg_dist_month = "datacube/getupstreammsgdistmonth";
    /// `GET_INTERFACE_SUMMARY`:接口分析数据。
    pub const get_interface_summary = "datacube/getinterfacesummary";
    /// `GET_INTERFACE_SUMMARY_HOUR`:接口分析分时数据。
    pub const get_interface_summary_hour = "datacube/getinterfacesummaryhour";
};

/// 接口清单(常量表数组形式,便于枚举/遍历)。
pub const endpoints = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "get_user_summary", .path = Path.get_user_summary },
    .{ .name = "get_user_cumulate", .path = Path.get_user_cumulate },
    .{ .name = "get_user_read", .path = Path.get_user_read },
    .{ .name = "get_user_read_hour", .path = Path.get_user_read_hour },
    .{ .name = "get_user_share", .path = Path.get_user_share },
    .{ .name = "get_user_share_hour", .path = Path.get_user_share_hour },
    .{ .name = "get_article_summary", .path = Path.get_article_summary },
    .{ .name = "get_article_total", .path = Path.get_article_total },
    .{ .name = "get_article_share", .path = Path.get_article_share },
    .{ .name = "get_article_detail", .path = Path.get_article_detail },
    .{ .name = "get_updatetime", .path = Path.get_updatetime },
    .{ .name = "get_upstream_msg", .path = Path.get_upstream_msg },
    .{ .name = "get_upstream_msg_hour", .path = Path.get_upstream_msg_hour },
    .{ .name = "get_upstream_msg_week", .path = Path.get_upstream_msg_week },
    .{ .name = "get_upstream_msg_month", .path = Path.get_upstream_msg_month },
    .{ .name = "get_upstream_msg_dist", .path = Path.get_upstream_msg_dist },
    .{ .name = "get_upstream_msg_dist_week", .path = Path.get_upstream_msg_dist_week },
    .{ .name = "get_upstream_msg_dist_month", .path = Path.get_upstream_msg_dist_month },
    .{ .name = "get_interface_summary", .path = Path.get_interface_summary },
    .{ .name = "get_interface_summary_hour", .path = Path.get_interface_summary_hour },
};

/// 校验 `YYYY-MM-DD`(长度/横线位/数字位;不做日历级校验,与任务要求一致)。
pub fn validDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

/// 统计行 —— 对应 Java `bean.analysis.WxDataCube*Result` 系列的公共形状:
/// `ref_date` + 可选 `ref_hour` + 各业务指标。这里不逐接口建模(字段数十个),
/// 而用 `values` 按原始 JSON 字段名取整数值(对应 Gson `getAsInt` 模式)。
pub const Row = struct {
    gpa: std.mem.Allocator,
    ref_date: []const u8,
    /// 分时接口的 0-23 小时;非分时接口为 null。
    ref_hour: ?i64 = null,
    /// 其余数值字段:原始字段名 → 整数值(键为 dupe,deinit 负责释放)。
    values: std.StringHashMap(i64),

    /// 按原始字段名取指标值,如 `row.value("new_user")`。
    pub fn value(self: *const Row, name: []const u8) ?i64 {
        return self.values.get(name);
    }

    pub fn deinit(self: *Row) void {
        const g = self.gpa;
        if (self.ref_date.len != 0) g.free(@constCast(self.ref_date));
        var it = self.values.iterator();
        while (it.next()) |e| g.free(@constCast(e.key_ptr.*));
        self.values.deinit();
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !Row {
        const o = json_util.object(v) orelse return error.BadRow;
        var r = Row{
            .gpa = gpa,
            .ref_date = "",
            .values = std.StringHashMap(i64).init(gpa),
        };
        errdefer r.deinit();
        r.ref_date = try gpa.dupe(u8, json_util.getStrOr(v, "ref_date", ""));
        r.ref_hour = json_util.getInt(v, "ref_hour");
        var it = o.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.eql(u8, key, "ref_date") or std.mem.eql(u8, key, "ref_hour")) continue;
            const n: i64 = switch (e.value_ptr.*) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => continue, // 字符串等非标量字段不进数值映射
            };
            const k = try gpa.dupe(u8, key);
            errdefer gpa.free(k);
            try r.values.put(k, n);
        }
        return r;
    }
};

/// 解析 `{"list":[..]}` —— 对应 Java `getList(result, "list", clazz)`。
fn parseRows(gpa: std.mem.Allocator, root: json_util.Value) ![]Row {
    const arr = json_util.getArray(root, "list") orelse return &[_]Row{};
    var list: std.ArrayList(Row) = .empty;
    errdefer {
        for (list.items) |*r| {
            var tmp = r.*;
            tmp.deinit();
        }
        list.deinit(gpa);
    }
    for (arr.items) |item| try list.append(gpa, try Row.fromJson(gpa, item));
    return list.toOwnedSlice(gpa);
}

/// 手写 JSON 转义写串(与 `user_tag.zig` 的 jw 同法)。
const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

fn dateRangeBody(gpa: std.mem.Allocator, begin_date: []const u8, end_date: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"begin_date\":");
    try jw.str(w, begin_date);
    try w.writeAll(",\"end_date\":");
    try jw.str(w, end_date);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

pub const DataCubeService = struct {
    svc: *service_mod.Service,

    /// 通用查询 —— 对应 Java 各方法共用的
    /// `this.executeRequest(postUrl, date2Json(begin,end))` 通路:
    /// 校验日期 → POST {begin_date,end_date} → 解析 list[]。
    /// 所有权:切片逐元素 `deinit`;`len != 0` 时由调用方 `free` 切片本身。
    fn query(self: *DataCubeService, io: std.Io, path: []const u8, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        const gpa = self.svc.gpa;
        if (!validDate(begin_date) or !validDate(end_date)) return .{
            .err = result_mod.WxError.internal(gpa, "日期格式应为 YYYY-MM-DD: {s}~{s}", .{ begin_date, end_date }),
        };
        const body = dateRangeBody(gpa, begin_date, end_date) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
            return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = result_mod.WxError.transport(gpa, "datacube response not json", .{}),
        };
        defer parsed.deinit();
        const rows = parseRows(gpa, parsed.value) catch
            return .{ .err = result_mod.WxError.internal(gpa, "parse datacube list failed", .{}) };
        return .{ .ok = rows };
    }

    /// 对应 `WxMpDataCubeServiceImpl#getUserSummary`(GET_USER_SUMMARY)。
    pub fn getUserSummary(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_summary, begin_date, end_date);
    }

    /// 对应 `#getUserCumulate`(GET_USER_CUMULATE)。
    pub fn getUserCumulate(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_cumulate, begin_date, end_date);
    }

    /// 对应 `#getUserRead`(GET_USER_READ)。
    pub fn getUserRead(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_read, begin_date, end_date);
    }

    /// 对应 `#getUserReadHour`(GET_USER_READ_HOUR,行含 ref_hour)。
    pub fn getUserReadHour(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_read_hour, begin_date, end_date);
    }

    /// 对应 `#getUserShare`(GET_USER_SHARE)。
    pub fn getUserShare(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_share, begin_date, end_date);
    }

    /// 对应 `#getUserShareHour`(GET_USER_SHARE_HOUR,行含 ref_hour)。
    pub fn getUserShareHour(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_user_share_hour, begin_date, end_date);
    }

    /// 对应 `#getArticleSummary`(GET_ARTICLE_SUMMARY)。
    pub fn getArticleSummary(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_article_summary, begin_date, end_date);
    }

    /// 对应 `#getArticleTotal`(GET_ARTICLE_TOTAL;Java 的 int_list 嵌套字段
    /// 不进数值映射,仅保留顶层整数字段)。
    pub fn getArticleTotal(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_article_total, begin_date, end_date);
    }

    /// 图文分享数据 —— Java 本 checkout 无常量(官方 /datacube/getarticleshare)。
    pub fn getArticleShare(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_article_share, begin_date, end_date);
    }

    /// 图文详细数据 —— Java 本 checkout 无常量(官方 /datacube/getarticledetail)。
    pub fn getArticleDetail(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_article_detail, begin_date, end_date);
    }

    /// 数据时间 —— Java 本 checkout 无常量(官方 /datacube/getupdatetime)。
    pub fn getUpdatetime(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_updatetime, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsg`(GET_UPSTREAM_MSG,impl:78-80)。
    pub fn getUpstreamMsg(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgHour`(GET_UPSTREAM_MSG_HOUR,行含 ref_hour)。
    pub fn getUpstreamMsgHour(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_hour, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgWeek`(GET_UPSTREAM_MSG_WEEK)。
    pub fn getUpstreamMsgWeek(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_week, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgMonth`(GET_UPSTREAM_MSG_MONTH)。
    pub fn getUpstreamMsgMonth(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_month, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgDist`(GET_UPSTREAM_MSG_DIST)。
    pub fn getUpstreamMsgDist(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_dist, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgDistWeek`(GET_UPSTREAM_MSG_DIST_WEEK)。
    pub fn getUpstreamMsgDistWeek(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_dist_week, begin_date, end_date);
    }

    /// 对应 `#getUpstreamMsgDistMonth`(GET_UPSTREAM_MSG_DIST_MONTH)。
    pub fn getUpstreamMsgDistMonth(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_upstream_msg_dist_month, begin_date, end_date);
    }

    /// 对应 `#getInterfaceSummary`(GET_INTERFACE_SUMMARY)。
    pub fn getInterfaceSummary(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_interface_summary, begin_date, end_date);
    }

    /// 对应 `#getInterfaceSummaryHour`(GET_INTERFACE_SUMMARY_HOUR,行含 ref_hour)。
    pub fn getInterfaceSummaryHour(self: *DataCubeService, io: std.Io, begin_date: []const u8, end_date: []const u8) WxResult([]Row) {
        return self.query(io, Path.get_interface_summary_hour, begin_date, end_date);
    }
};

// ---------------------------------------------------------------------------
// 测试:mock RequestExecutor(照 `template_msg.zig` 的 Recorder 方式)。
// ---------------------------------------------------------------------------

const testing = std.testing;
const http_mod = @import("../http.zig");
const config_mod = @import("../config.zig");
const token_mod = @import("common").token;
const error_mod = @import("common").error_util;

const Recorder = struct {
    const Entry = struct { match: []const u8, response: []const u8 };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    fn uri(self: *const Recorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const Recorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }

    fn executor(self: *Recorder) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
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
                return .{ .ok = gpa.dupe(u8, e.response) catch return .{
                    .err = error_mod.WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = error_mod.WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }

    const vtable = http_mod.RequestExecutor.VTable{ .execute = executeImpl };
};

const FakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
        _ = c;
        _ = i;
        const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = t, .expires_in = 7200 } };
    }
};

fn setup(
    gpa: std.mem.Allocator,
    mock: *Recorder,
    threaded: *std.Io.Threaded,
    cfg: *config_mod.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try config_mod.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), mock.executor());
}

/// 通用断言:校验最后一次请求的 method/uri/body 日期字段,并取回解析出的行。
fn expectQuery(
    mock: *Recorder,
    r: WxResult([]Row),
    uri_needle: []const u8,
    begin_date: []const u8,
    end_date: []const u8,
) ![]Row {
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), uri_needle) != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    var buf: [128]u8 = undefined;
    const b = mock.body();
    const b_needle = std.fmt.bufPrint(&buf, "\"begin_date\":\"{s}\"", .{begin_date}) catch return error.Unexpected;
    try testing.expect(std.mem.indexOf(u8, b, b_needle) != null);
    const e_needle = std.fmt.bufPrint(&buf, "\"end_date\":\"{s}\"", .{end_date}) catch return error.Unexpected;
    try testing.expect(std.mem.indexOf(u8, b, e_needle) != null);
    return switch (r) {
        .ok => |rows| rows,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    };
}

test "datacube: 请求体 + 行解析(ref_date/ref_hour/values) + errcode!=0" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "getusersummary", .response = "{\"list\":[{\"ref_date\":\"2026-01-01\",\"new_user\":10,\"old_user\":3,\"cancel_user\":1},{\"ref_date\":\"2026-01-02\",\"new_user\":7,\"cancel_user\":0}]}" },
        .{ .match = "getuserreadhour", .response = "{\"list\":[{\"ref_date\":\"2026-01-01\",\"ref_hour\":8,\"int_page_read_user\":42,\"int_page_read_count\":99}]}" },
        .{ .match = "getarticlesummary", .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = DataCubeService{ .svc = &base };
    const io = threaded.io();

    // getusersummary:两行 + name→value 取值
    const rows = try expectQuery(&mock, svc.getUserSummary(io, "2026-01-01", "2026-01-02"), "datacube/getusersummary", "2026-01-01", "2026-01-02");
    defer if (rows.len != 0) gpa.free(rows);
    defer for (rows) |*r| {
        var tmp = r.*;
        tmp.deinit();
    };
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("2026-01-01", rows[0].ref_date);
    try testing.expect(rows[0].ref_hour == null);
    try testing.expectEqual(@as(?i64, 10), rows[0].value("new_user"));
    try testing.expectEqual(@as(?i64, 3), rows[0].value("old_user"));
    try testing.expectEqual(@as(?i64, 0), rows[1].value("cancel_user"));
    try testing.expect(rows[1].value("old_user") == null);
    try testing.expect(rows[0].value("ref_date") == null); // ref_date 不进数值映射

    // getuserreadhour:ref_hour 解析
    const hrows = try expectQuery(&mock, svc.getUserReadHour(io, "2026-01-01", "2026-01-01"), "datacube/getuserreadhour", "2026-01-01", "2026-01-01");
    defer if (hrows.len != 0) gpa.free(hrows);
    defer for (hrows) |*r| {
        var tmp = r.*;
        tmp.deinit();
    };
    try testing.expectEqual(@as(usize, 1), hrows.len);
    try testing.expectEqual(@as(?i64, 8), hrows[0].ref_hour);
    try testing.expectEqual(@as(?i64, 42), hrows[0].value("int_page_read_user"));
    try testing.expectEqual(@as(?i64, 99), hrows[0].value("int_page_read_count"));

    // 失败路径:errcode=48001(非 token 类)
    switch (svc.getArticleSummary(io, "2026-01-01", "2026-01-02")) {
        .ok => |orows| {
            if (orows.len != 0) gpa.free(orows);
            return error.Unexpected;
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 48001), err.error_code);
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "datacube/getarticlesummary") != null);
}

test "datacube: 日期校验 + 接口清单常量表" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{} };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = DataCubeService{ .svc = &base };

    // 合法日期判定
    try testing.expect(validDate("2026-01-08"));
    // 非法:长度 / 横线位 / 数字位
    try testing.expect(!validDate("2026-1-8"));
    try testing.expect(!validDate("2026/01/08"));
    try testing.expect(!validDate("20260108xx"));
    try testing.expect(!validDate("202a-01-08"));
    try testing.expect(!validDate("2026-01-8 "));

    // 非法日期 → 本地拦截(.err,不发起任何请求)
    switch (svc.getUserCumulate(threaded.io(), "2026/01/01", "2026-01-02")) {
        .ok => |rows| {
            if (rows.len != 0) gpa.free(rows);
            return error.Unexpected;
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, -99), err.error_code);
            try testing.expect(std.mem.indexOf(u8, err.error_msg, "YYYY-MM-DD") != null);
        },
    }
    try testing.expectEqual(@as(usize, 0), mock.calls);

    // 接口清单:20 项、路径齐备(其中 17 项与 Java DataCube 枚举一致,
    // getarticleshare/getarticledetail/getupdatetime 为官方文档接口)
    try testing.expectEqual(@as(usize, 20), endpoints.len);
    for (endpoints) |ep| {
        try testing.expect(std.mem.startsWith(u8, ep.path, "datacube/"));
    }
    try testing.expectEqualStrings("datacube/getusersummary", Path.get_user_summary);
    try testing.expectEqualStrings("datacube/getusercumulate", Path.get_user_cumulate);
    try testing.expectEqualStrings("datacube/getarticlesummary", Path.get_article_summary);
    try testing.expectEqualStrings("datacube/getarticletotal", Path.get_article_total);
    try testing.expectEqualStrings("datacube/getupstreammsg", Path.get_upstream_msg);
    try testing.expectEqualStrings("datacube/getupstreammsgdistmonth", Path.get_upstream_msg_dist_month);
    try testing.expectEqualStrings("datacube/getinterfacesummary", Path.get_interface_summary);
    try testing.expectEqualStrings("datacube/getinterfacesummaryhour", Path.get_interface_summary_hour);
}

// 其余 16 个同构包装方法(getUserSummary/getUserReadHour/getArticleSummary/
// getUserCumulate 已在上方测试):逐个调用断言 method→Path 接线与请求体日期。
test "datacube: 其余 16 个端点方法→Path 接线" {
    const gpa = testing.allocator;
    var mock = Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "datacube/", .response = "{\"list\":[{\"ref_date\":\"2026-01-01\",\"ref_hour\":0,\"int_page_read_user\":1}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: config_mod.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setup(gpa, &mock, &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = DataCubeService{ .svc = &base };
    const io = threaded.io();

    // @field 从类型取方法声明(同 device.zig 的做法);元组 = {方法名, 期望路径}
    inline for (.{
        .{ "getUserRead", "datacube/getuserread" },
        .{ "getUserShare", "datacube/getusershare" },
        .{ "getUserShareHour", "datacube/getusersharehour" },
        .{ "getArticleTotal", "datacube/getarticletotal" },
        .{ "getArticleShare", "datacube/getarticleshare" },
        .{ "getArticleDetail", "datacube/getarticledetail" },
        .{ "getUpdatetime", "datacube/getupdatetime" },
        .{ "getUpstreamMsg", "datacube/getupstreammsg" },
        .{ "getUpstreamMsgHour", "datacube/getupstreammsghour" },
        .{ "getUpstreamMsgWeek", "datacube/getupstreammsgweek" },
        .{ "getUpstreamMsgMonth", "datacube/getupstreammsgmonth" },
        .{ "getUpstreamMsgDist", "datacube/getupstreammsgdist" },
        .{ "getUpstreamMsgDistWeek", "datacube/getupstreammsgdistweek" },
        .{ "getUpstreamMsgDistMonth", "datacube/getupstreammsgdistmonth" },
        .{ "getInterfaceSummary", "datacube/getinterfacesummary" },
        .{ "getInterfaceSummaryHour", "datacube/getinterfacesummaryhour" },
    }) |case| {
        const method = @field(DataCubeService, case[0]);
        const rows = try expectQuery(&mock, method(&svc, io, "2026-01-01", "2026-01-01"), case[1], "2026-01-01", "2026-01-01");
        defer if (rows.len != 0) gpa.free(rows);
        defer for (rows) |*r| {
            var tmp = r.*;
            tmp.deinit();
        };
        try testing.expectEqual(@as(usize, 1), rows.len);
    }
    try testing.expectEqual(@as(usize, 16), mock.calls);
}
