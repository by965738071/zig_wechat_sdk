//! 交易投诉服务 —— 对应 Java `api.WxMaComplaintService` +
//! `api.impl.WxMaComplaintServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Complaint`:
//! - queryComplaints:POST /cgi-bin/miniapp/complaint/list
//!   (请求体字段多且带分页/筛选,由调用方预构建,响应原样返回);
//! - getComplaint:POST .../complaint/detail(同上,预构建体);
//! - queryNegotiationHistorys:POST .../complaint/negotiation/history(同上);
//! - addComplaintNotifyUrl:POST .../complaint/notify/add {url}
//!   → ComplaintNotifyUrl{url,signature};
//! - getComplaintNotifyUrl:GET .../complaint/notify/get(Java 用 get,非 post)
//!   → ComplaintNotifyUrl;
//! - updateComplaintNotifyUrl:POST .../complaint/notify/update {url}
//!   → ComplaintNotifyUrl;
//! - deleteComplaintNotifyUrl:POST .../complaint/notify/delete {};
//! - submitResponse:POST .../complaint/response(预构建体);
//! - complete:POST .../complaint/complete(预构建体);
//! - uploadResponseImage:multipart 上传,基座 http 层暂不支持,未实现
//!   (待 multipart 支持后补齐,对应 Java uploadResponseImage)。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const QUERY_COMPLAINTS_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/list";
const GET_COMPLAINT_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/detail";
const QUERY_NEGOTIATION_HISTORY_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/negotiation/history";
const ADD_COMPLAINT_NOTIFY_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/notify/add";
const GET_COMPLAINT_NOTIFY_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/notify/get";
const UPDATE_COMPLAINT_NOTIFY_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/notify/update";
const DELETE_COMPLAINT_NOTIFY_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/notify/delete";
const SUBMIT_RESPONSE_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/response";
const COMPLETE_COMPLAINT_URL = "https://api.weixin.qq.com/cgi-bin/miniapp/complaint/complete";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `complaint.WxMaComplaintNotifyUrlResult`(url/signature)。gpa 拥有。
pub const ComplaintNotifyUrl = struct {
    gpa: std.mem.Allocator,
    url: ?[]const u8,
    signature: ?[]const u8,

    pub fn deinit(self: *ComplaintNotifyUrl) void {
        const g = self.gpa;
        if (self.url) |s| g.free(@constCast(s));
        if (self.signature) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const ComplaintNotifyUrl) void {
        const g = self.gpa;
        if (self.url) |s| g.free(s);
        if (self.signature) |s| g.free(s);
    }
};

/// 对应 `complaint.WxMaComplaintNotifyUrlRequest`(url)。
pub const ComplaintNotifyUrlRequest = struct {
    url: []const u8,

    pub fn to_json(self: ComplaintNotifyUrlRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"url\":");
        try js(w, self.url);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

// --- service -------------------------------------------------------------------

pub const ComplaintService = struct {
    svc: *mp_service.Service,

    /// 对应 `queryComplaints(WxMaComplaintRequest)`:POST .../complaint/list。
    /// 请求体由调用方预构建(分页/筛选字段多),响应原样返回(gpa 拥有,调用方 free;
    /// Java 解析 WxMaComplaintResult,字段多且版本不稳,交由调用方按需解析)。
    pub fn queryComplaints(self: *ComplaintService, io: std.Io, body: []const u8) WxResult([]u8) {
        return self.svc.post(io, QUERY_COMPLAINTS_URL, &.{}, body);
    }

    /// 对应 `getComplaint(WxMaComplaintDetailRequest)`:POST .../complaint/detail。
    /// 请求体由调用方预构建(complaint_id),响应原样返回(同上)。
    pub fn getComplaint(self: *ComplaintService, io: std.Io, body: []const u8) WxResult([]u8) {
        return self.svc.post(io, GET_COMPLAINT_URL, &.{}, body);
    }

    /// 对应 `queryNegotiationHistorys(WxMaNegotiationHistoryRequest)`:
    /// POST .../complaint/negotiation/history。请求体由调用方预构建
    /// (complaint_id/分页),响应原样返回(Java 解析 WxMaNegotiationHistoryResult)。
    pub fn queryNegotiationHistorys(self: *ComplaintService, io: std.Io, body: []const u8) WxResult([]u8) {
        return self.svc.post(io, QUERY_NEGOTIATION_HISTORY_URL, &.{}, body);
    }

    /// 对应 `addComplaintNotifyUrl(WxMaComplaintNotifyUrlRequest)`:
    /// POST .../complaint/notify/add {url} → ComplaintNotifyUrl。
    pub fn addComplaintNotifyUrl(self: *ComplaintService, io: std.Io, req: ComplaintNotifyUrlRequest) WxResult(ComplaintNotifyUrl) {
        return self.notifyUrlPost(io, ADD_COMPLAINT_NOTIFY_URL, req);
    }

    /// 对应 `getComplaintNotifyUrl()`:GET .../complaint/notify/get
    /// (Java 实现用 `service.get`,非 post) → ComplaintNotifyUrl。
    pub fn getComplaintNotifyUrl(self: *ComplaintService, io: std.Io) WxResult(ComplaintNotifyUrl) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_COMPLAINT_NOTIFY_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return self.parseNotifyUrl(gpa, resp);
    }

    /// 对应 `updateComplaintNotifyUrl(WxMaComplaintNotifyUrlRequest)`:
    /// POST .../complaint/notify/update {url} → ComplaintNotifyUrl。
    pub fn updateComplaintNotifyUrl(self: *ComplaintService, io: std.Io, req: ComplaintNotifyUrlRequest) WxResult(ComplaintNotifyUrl) {
        return self.notifyUrlPost(io, UPDATE_COMPLAINT_NOTIFY_URL, req);
    }

    /// 对应 `deleteComplaintNotifyUrl()`:POST .../complaint/notify/delete {}。
    pub fn deleteComplaintNotifyUrl(self: *ComplaintService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, DELETE_COMPLAINT_NOTIFY_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `submitResponse(WxMaResponseRequest)`:POST .../complaint/response。
    /// 请求体由调用方预构建(complaint_id/response_content/response_images)。
    pub fn submitResponse(self: *ComplaintService, io: std.Io, body: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, SUBMIT_RESPONSE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `complete(WxMaCompleteRequest)`:POST .../complaint/complete。
    /// 请求体由调用方预构建(complaint_id)。
    pub fn complete(self: *ComplaintService, io: std.Io, body: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, COMPLETE_COMPLAINT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    // 内部:notify/add|update 共用(POST {url} → 解析 ComplaintNotifyUrl)。
    fn notifyUrlPost(self: *ComplaintService, io: std.Io, url: []const u8, req: ComplaintNotifyUrlRequest) WxResult(ComplaintNotifyUrl) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return self.parseNotifyUrl(gpa, resp);
    }

    // 内部:解析 ComplaintNotifyUrl(url/signature 均可缺省)。
    fn parseNotifyUrl(_: *ComplaintService, gpa: std.mem.Allocator, resp: []const u8) WxResult(ComplaintNotifyUrl) {
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "complaint notify url not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .url = if (json_util.getStr(parsed.value, "url")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
            .signature = if (json_util.getStr(parsed.value, "signature")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
        } };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "complaint notify url: add + get + update + delete" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "complaint/notify/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://cb.example.com/wx\",\"signature\":\"SIG1\"}" },
        .{ .match = "complaint/notify/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://cb.example.com/wx\",\"signature\":\"SIG1\"}" },
        .{ .match = "complaint/notify/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://cb2.example.com/wx\",\"signature\":\"SIG2\"}" },
        .{ .match = "complaint/notify/delete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ComplaintService{ .svc = &base };

    // add:POST {url} → 解析 url/signature
    const added = switch (s.addComplaintNotifyUrl(io, .{ .url = "https://cb.example.com/wx" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var a = added;
    defer a.deinit();
    try std.testing.expectEqualStrings("https://cb.example.com/wx", a.url.?);
    try std.testing.expectEqualStrings("SIG1", a.signature.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/notify/add") != null);
    try std.testing.expectEqualStrings("{\"url\":\"https://cb.example.com/wx\"}", m.last_body);

    // get:GET 请求
    const got = switch (s.getComplaintNotifyUrl(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var g = got;
    defer g.deinit();
    try std.testing.expectEqualStrings("https://cb.example.com/wx", g.url.?);
    try std.testing.expectEqualStrings("SIG1", g.signature.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/notify/get") != null);

    // update:POST {url} → 新 url/signature
    const upd = switch (s.updateComplaintNotifyUrl(io, .{ .url = "https://cb2.example.com/wx" })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var u = upd;
    defer u.deinit();
    try std.testing.expectEqualStrings("https://cb2.example.com/wx", u.url.?);
    try std.testing.expectEqualStrings("SIG2", u.signature.?);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/notify/update") != null);

    // delete:POST {}
    try std.testing.expect(!s.deleteComplaintNotifyUrl(io).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/notify/delete") != null);
    try std.testing.expectEqualStrings("{}", m.last_body);
}

test "complaint query/detail/negotiation/response/complete" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "complaint/list", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"complaint_list\":[{\"complaint_id\":\"C1\"}],\"total_count\":1}" },
        .{ .match = "complaint/detail", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"complaint_id\":\"C1\",\"status\":1}" },
        .{ .match = "complaint/negotiation", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"negotiation_history\":[{\"content\":\"用户已回复\"}]}" },
        .{ .match = "complaint/response", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "complaint/complete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ComplaintService{ .svc = &base };

    // queryComplaints:预构建体原样发出,响应原样返回
    const list = switch (s.queryComplaints(io, "{\"begin_time\":1700000000,\"end_time\":1700086400,\"page\":1,\"page_size\":10}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/list") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"complaint_id\":\"C1\"") != null);

    // getComplaint
    const detail = switch (s.getComplaint(io, "{\"complaint_id\":\"C1\"}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "\"status\":1") != null);

    // queryNegotiationHistorys
    const hist = switch (s.queryNegotiationHistorys(io, "{\"complaint_id\":\"C1\",\"page\":1,\"page_size\":10}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(hist);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/negotiation/history") != null);
    try std.testing.expect(std.mem.indexOf(u8, hist, "negotiation_history") != null);

    // submitResponse:预构建体原样发出
    try std.testing.expect(!s.submitResponse(io, "{\"complaint_id\":\"C1\",\"response_content\":\"已处理\",\"response_images\":[]}").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/response") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"response_content\":\"已处理\"") != null);

    // complete
    try std.testing.expect(!s.complete(io, "{\"complaint_id\":\"C1\"}").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "complaint/complete") != null);
}
