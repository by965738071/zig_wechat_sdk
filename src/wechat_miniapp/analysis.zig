//! 小程序数据分析服务 —— 对应 Java `api.WxMaAnalysisService` +
//! `api.impl.WxMaAnalysisServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Analysis`(全部 POST /datacube/...)。
//! 请求体 `{begin_date,end_date}`(Java 用 `yyyyMMdd` 字符串)。响应外层是
//! `{errcode,errmsg,list}` 或单对象;list 型取 `list` 数组长度,单对象型取
//! 顶层字段。
//!
//! 返回 `i64` 为对应 list 的条目数(对应 Java 返回 `List<...>` 的规模),
//! 单对象型(visitDistribution/visitPage 之外的 retain/portrait)取 `list` 长度或 0。
//! 注:Java 各方法返回强类型 bean;Zig 骨架只覆盖「条目规模 + 关键路径」,
//! 强类型解析由调用方按 `json_util` 自行完成(与 mp datacube 口径一致)。
const std = @import("std");
const result_mod = @import("common").result;
const json_util = @import("common").json_util;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

// --- URL(对应 WxMaApiUrlConstants.Analysis)-------------------------------------
const DAILY_SUMMARY_TREND = "https://api.weixin.qq.com/datacube/getweanalysisappiddailysummarytrend";
const DAILY_VISIT_TREND = "https://api.weixin.qq.com/datacube/getweanalysisappiddailyvisittrend";
const WEEKLY_VISIT_TREND = "https://api.weixin.qq.com/datacube/getweanalysisappidweeklyvisittrend";
const MONTHLY_VISIT_TREND = "https://api.weixin.qq.com/datacube/getweanalysisappidmonthlyvisittrend";
const VISIT_DISTRIBUTION = "https://api.weixin.qq.com/datacube/getweanalysisappidvisitdistribution";
const DAILY_RETAIN = "https://api.weixin.qq.com/datacube/getweanalysisappiddailyretaininfo";
const WEEKLY_RETAIN = "https://api.weixin.qq.com/datacube/getweanalysisappidweeklyretaininfo";
const MONTHLY_RETAIN = "https://api.weixin.qq.com/datacube/getweanalysisappidmonthlyretaininfo";
const VISIT_PAGE = "https://api.weixin.qq.com/datacube/getweanalysisappidvisitpage";
const USER_PORTRAIT = "https://api.weixin.qq.com/datacube/getweanalysisappiduserportrait";

fn dateBody(gpa: std.mem.Allocator, begin_date: []const u8, end_date: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"begin_date\":\"{s}\",\"end_date\":\"{s}\"}}", .{ begin_date, end_date });
}

/// 取响应 `list` 数组长度(Java list 型方法返回的规模)。
fn listLen(gpa: std.mem.Allocator, resp: []const u8) i64 {
    const parsed = json_util.parse(gpa, resp) catch return 0;
    defer parsed.deinit();
    return if (json_util.getArray(parsed.value, "list")) |a| @intCast(a.items.len) else 0;
}

// --- service ------------------------------------------------------------------

pub const AnalysisService = struct {
    svc: *mp_service.Service,

    fn post(self: *AnalysisService, io: std.Io, url: []const u8, begin_date: []const u8, end_date: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = dateBody(gpa, begin_date, end_date) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.svc.post(io, url, &.{}, body);
    }

    /// 对应 `getDailySummaryTrend`：返回 list 条目数。
    pub fn getDailySummaryTrend(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, DAILY_SUMMARY_TREND, b, e);
    }
    pub fn getDailyVisitTrend(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, DAILY_VISIT_TREND, b, e);
    }
    pub fn getWeeklyVisitTrend(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, WEEKLY_VISIT_TREND, b, e);
    }
    pub fn getMonthlyVisitTrend(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, MONTHLY_VISIT_TREND, b, e);
    }
    pub fn getVisitPage(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, VISIT_PAGE, b, e);
    }
    pub fn getDailyRetainInfo(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, DAILY_RETAIN, b, e);
    }
    pub fn getWeeklyRetainInfo(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, WEEKLY_RETAIN, b, e);
    }
    pub fn getMonthlyRetainInfo(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, MONTHLY_RETAIN, b, e);
    }

    /// 对应 `getVisitDistribution`/`getUserPortrait`：顶层单对象，返回 list(若有)长度。
    pub fn getVisitDistribution(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runSingle(io, VISIT_DISTRIBUTION, b, e);
    }
    pub fn getUserPortrait(self: *AnalysisService, io: std.Io, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runSingle(io, USER_PORTRAIT, b, e);
    }

    fn runList(self: *AnalysisService, io: std.Io, url: []const u8, b: []const u8, e: []const u8) WxResult(i64) {
        const resp = switch (self.post(io, url, b, e)) {
            .ok => |r| r,
            .err => |er| return .{ .err = er },
        };
        defer self.svc.gpa.free(resp);
        return .{ .ok = listLen(self.svc.gpa, resp) };
    }
    fn runSingle(self: *AnalysisService, io: std.Io, url: []const u8, b: []const u8, e: []const u8) WxResult(i64) {
        return self.runList(io, url, b, e);
    }
};

// ---------------------------------------------------------------------------
// 测试:参数化覆盖 10 个同形状 wrapper(断言各自 URL 接线 + body 日期字段 + errcode 折叠)
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "analysis: all 10 endpoints wired + body + list len + errcode fold" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 10 个端点各一条 mock(每条 URI 唯一;避免子串路由串味)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "summarytrend", .response = "{\"errcode\":0,\"list\":[{\"a\":1},{\"a\":2}]}" },
        .{ .match = "dailyvisittrend", .response = "{\"errcode\":0,\"list\":[{\"a\":1},{\"a\":2},{\"a\":3}]}" },
        .{ .match = "weeklyvisittrend", .response = "{\"errcode\":0,\"list\":[{}]}" },
        .{ .match = "monthlyvisittrend", .response = "{\"errcode\":0}" },
        .{ .match = "dailyretaininfo", .response = "{\"errcode\":0,\"list\":[{\"a\":1},{\"a\":2}]}" },
        .{ .match = "weeklyretaininfo", .response = "{\"errcode\":0,\"list\":[{}]}" },
        .{ .match = "monthlyretaininfo", .response = "{\"errcode\":0}" },
        .{ .match = "visitpage", .response = "{\"errcode\":0}" },
        .{ .match = "visitdistribution", .response = "{\"errcode\":0}" },
        .{ .match = "userportrait", .response = "{\"errcode\":0,\"list\":[{},{}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = AnalysisService{ .svc = &base };

    // 逐端点调用并立即断言(调用后马上读 mock 快照,避免被后续请求覆盖)
    const Ep = enum { daily_summary, daily_visit, weekly_visit, monthly_visit, visit_page, daily_retain, weekly_retain, monthly_retain, visit_distribution, user_portrait };
    const cases = [_]struct { ep: Ep, len: i64, uri_sub: []const u8 }{
        .{ .ep = .daily_summary, .len = 2, .uri_sub = "summarytrend" },
        .{ .ep = .daily_visit, .len = 3, .uri_sub = "dailyvisittrend" },
        .{ .ep = .weekly_visit, .len = 1, .uri_sub = "weeklyvisittrend" },
        .{ .ep = .monthly_visit, .len = 0, .uri_sub = "monthlyvisittrend" },
        .{ .ep = .visit_page, .len = 0, .uri_sub = "visitpage" },
        .{ .ep = .daily_retain, .len = 2, .uri_sub = "dailyretaininfo" },
        .{ .ep = .weekly_retain, .len = 1, .uri_sub = "weeklyretaininfo" },
        .{ .ep = .monthly_retain, .len = 0, .uri_sub = "monthlyretaininfo" },
        .{ .ep = .visit_distribution, .len = 0, .uri_sub = "visitdistribution" },
        .{ .ep = .user_portrait, .len = 2, .uri_sub = "userportrait" },
    };
    for (cases) |c| {
        const r = switch (c.ep) {
            .daily_summary => s.getDailySummaryTrend(io, "20240101", "20240131"),
            .daily_visit => s.getDailyVisitTrend(io, "20240101", "20240131"),
            .weekly_visit => s.getWeeklyVisitTrend(io, "20240101", "20240131"),
            .monthly_visit => s.getMonthlyVisitTrend(io, "20240101", "20240131"),
            .visit_page => s.getVisitPage(io, "20240101", "20240131"),
            .daily_retain => s.getDailyRetainInfo(io, "20240101", "20240131"),
            .weekly_retain => s.getWeeklyRetainInfo(io, "20240101", "20240131"),
            .monthly_retain => s.getMonthlyRetainInfo(io, "20240101", "20240131"),
            .visit_distribution => s.getVisitDistribution(io, "20240101", "20240131"),
            .user_portrait => s.getUserPortrait(io, "20240101", "20240131"),
        };
        const v = switch (r) {
            .ok => |v| v,
            .err => |e| {
                var err = e;
                defer err.deinit();
                return error.Unexpected;
            },
        };
        try std.testing.expectEqual(c.len, v);
        try std.testing.expect(std.mem.indexOf(u8, m.last_uri, c.uri_sub) != null);
        const parsed = try json_util.parse(gpa, m.last_body);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("20240101", json_util.getStr(parsed.value, "begin_date").?);
        try std.testing.expectEqualStrings("20240131", json_util.getStr(parsed.value, "end_date").?);
    }

    // 每服务 errcode!=0 用例:用 errcode fixture 覆盖 dailyvisittrend
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "dailyvisittrend", .response = "{\"errcode\":42001,\"errmsg\":\"content expired\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = AnalysisService{ .svc = &base2 };
    switch (s2.getDailyVisitTrend(io, "20240101", "20240131")) {
        .ok => return error.ExpectedErr,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 42001), err.error_code);
        },
    }
}
