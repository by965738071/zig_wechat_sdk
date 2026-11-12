//! 顾问·群发任务服务 —— 对应 Java `api.WxMpGuideMassedJobService` +
//! `api.impl.WxMpGuideMassedJobServiceImpl`,端点常量取自 `enums/WxMpApiUrl.Guide`。
//!
//! 样板见 `services/user.zig`,复用 `sub_util.zig`(含 strArrayValue)。逐字对照
//! WxMpGuideMassedJobServiceImpl(全部 POST)。ACCOUNT="guide_account" /
//! OPENID="guide_openid"(impl:26-27)。
//!   addGuideMassedJob     ADD_GUIDE_MASSED_JOB      /cgi-bin/guide/addguidemassendjob
//!     {"guide_account","guide_openid","task_name","task_remark","push_time",
//!      "openid":[...],"material":[WxMpGuideMaterialInfo]} → 原样返回("task_result" 数组)
//!   getGuideMassedJobList GET_GUIDE_MASSED_JOB_LIST /cgi-bin/guide/getguidemassendjoblist
//!     {"guide_account","guide_openid","task_status":[...],"offset","limit"} → 原样返回("list")
//!   getGuideMassedJob     GET_GUIDE_MASSED_JOB      /cgi-bin/guide/getguidemassendjob
//!     {"task_id"} → 原样返回("job")
//!   updateGuideMassedJob  UPDATE_GUIDE_MASSED_JOB   /cgi-bin/guide/updateguidemassendjob
//!     {"task_id","task_name","task_remark","push_time","openid":[...],"material":[...]} → void
//!   cancelGuideMassedJob  CANCEL_GUIDE_MASSED_JOB   /cgi-bin/guide/cancelguidemassendjob
//!     {"task_id"} → void
//!
//! WxMpGuideMaterialInfo 的 @SerializedName("type")/"media_id"/"title"/"path"/
//! "appid"/"word" 逐字取自 bean;WxGsonBuilder.create() 未 serializeNulls,故
//! null 字段被 Gson 省略,Zig 侧用 arena + Value 只拼非 null 字段(见 materialArray)。
//! 返回 WxResult([]u8) 的端点与 Java 返回 String/bean 的方法同口径:原样返回 body,
//! Java 里 `getAsJsonArray(...)` 等字段级解析留待下一轮,不编造字段。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

/// 对应 Java `WxMpGuideMaterialInfo`。字段 `material_type` 序列化为 "type"
/// (Zig `type` 是关键字,不能直接作字段名),其余可选字段为 null 时 Gson 省略。
pub const GuideMaterialInfo = struct {
    material_type: i64,
    media_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    path: ?[]const u8 = null,
    appid: ?[]const u8 = null,
    word: ?[]const u8 = null,
};

fn oomR(gpa: std.mem.Allocator) WxResult([]u8) {
    return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
}
fn oomD(gpa: std.mem.Allocator) Done {
    return .{ .err = result_mod.WxError.internal(gpa, "oom", .{}) };
}

/// WxMpGuideMaterialInfo 数组的 Gson 序列化:{"type":..[,"media_id"/"title"/
/// "path"/"appid"/"word":..]},null 字段省略。内存在 arena 上。
fn materialArray(a: std.mem.Allocator, items: []const GuideMaterialInfo) !json_util.Value {
    var arr: std.ArrayList(json_util.Value) = .empty;
    for (items) |m| {
        var o: json_util.ObjectMap = .empty;
        try o.put(a, "type", .{ .integer = m.material_type });
        if (m.media_id) |v| try o.put(a, "media_id", .{ .string = v });
        if (m.title) |v| try o.put(a, "title", .{ .string = v });
        if (m.path) |v| try o.put(a, "path", .{ .string = v });
        if (m.appid) |v| try o.put(a, "appid", .{ .string = v });
        if (m.word) |v| try o.put(a, "word", .{ .string = v });
        try arr.append(a, .{ .object = o });
    }
    return .{ .array = arr };
}

pub const GuideMassedJobService = struct {
    svc: *service_mod.Service,

    /// 匿名 struct → JSON body → POST,原样返回响应 body(调用方 free)。
    fn post(self: *GuideMassedJobService, io: std.Io, which: service_mod.ApiUrl, v: anytype) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch return oomR(gpa);
        defer gpa.free(body);
        return h.apiPost(self.svc, io, which.asUri(), body);
    }

    /// 匿名 struct → JSON body → POST,errcode==0 即完成。
    fn postDone(self: *GuideMassedJobService, io: std.Io, which: service_mod.ApiUrl, v: anytype) Done {
        const gpa = self.svc.gpa;
        const body = json_util.stringify(gpa, v) catch return oomD(gpa);
        defer gpa.free(body);
        return h.postVoid(self.svc, io, which.asUri(), body);
    }

    /// 对应 `WxMpGuideMassedJobServiceImpl#addGuideMassedJob`(impl:30-42):
    /// 7 字段(body 为 LinkedHashMap,material 是 WxMpGuideMaterialInfo 数组)→ 原样返回("task_result")。
    pub fn addGuideMassedJob(self: *GuideMassedJobService, io: std.Io, account: []const u8, openid: []const u8, task_name: []const u8, task_remark: []const u8, push_time: i64, user_openids: []const []const u8, materials: []const GuideMaterialInfo) WxResult([]u8) {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("guide_account", account) catch return oomR(gpa);
        ob.putStr("guide_openid", openid) catch return oomR(gpa);
        ob.putStr("task_name", task_name) catch return oomR(gpa);
        ob.putStr("task_remark", task_remark) catch return oomR(gpa);
        ob.putInt("push_time", push_time) catch return oomR(gpa);
        const openid_v = h.strArrayValue(a, user_openids) catch return oomR(gpa);
        ob.putValue("openid", openid_v) catch return oomR(gpa);
        const material_v = materialArray(a, materials) catch return oomR(gpa);
        ob.putValue("material", material_v) catch return oomR(gpa);
        const body = ob.toJson() catch return oomR(gpa);
        defer gpa.free(body);
        return h.apiPost(self.svc, io, service_mod.ApiUrl.guide_add_massed_job.asUri(), body);
    }

    /// 对应 `WxMpGuideMassedJobServiceImpl#getGuideMassedJobList`(impl:44-56):
    /// {"guide_account","guide_openid","task_status":[...],"offset","limit"} → 原样返回("list")。
    pub fn getGuideMassedJobList(self: *GuideMassedJobService, io: std.Io, account: []const u8, openid: []const u8, task_status: []const i64, offset: i64, limit: i64) WxResult([]u8) {
        return self.post(io, .guide_get_massed_job_list, .{
            .guide_account = account,
            .guide_openid = openid,
            .task_status = task_status,
            .offset = offset,
            .limit = limit,
        });
    }

    /// 对应 `WxMpGuideMassedJobServiceImpl#getGuideMassedJob`(impl:58-62):
    /// {"task_id"} → 原样返回("job")。
    pub fn getGuideMassedJob(self: *GuideMassedJobService, io: std.Io, task_id: []const u8) WxResult([]u8) {
        return self.post(io, .guide_get_massed_job, .{ .task_id = task_id });
    }

    /// 对应 `WxMpGuideMassedJobServiceImpl#updateGuideMassedJob`(impl:64-74):
    /// 6 字段(首字段 task_id)→ void。
    pub fn updateGuideMassedJob(self: *GuideMassedJobService, io: std.Io, task_id: []const u8, task_name: []const u8, task_remark: []const u8, push_time: i64, user_openids: []const []const u8, materials: []const GuideMaterialInfo) Done {
        const gpa = self.svc.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("task_id", task_id) catch return oomD(gpa);
        ob.putStr("task_name", task_name) catch return oomD(gpa);
        ob.putStr("task_remark", task_remark) catch return oomD(gpa);
        ob.putInt("push_time", push_time) catch return oomD(gpa);
        const openid_v = h.strArrayValue(a, user_openids) catch return oomD(gpa);
        ob.putValue("openid", openid_v) catch return oomD(gpa);
        const material_v = materialArray(a, materials) catch return oomD(gpa);
        ob.putValue("material", material_v) catch return oomD(gpa);
        const body = ob.toJson() catch return oomD(gpa);
        defer gpa.free(body);
        return h.postVoid(self.svc, io, service_mod.ApiUrl.guide_update_massed_job.asUri(), body);
    }

    /// 对应 `WxMpGuideMassedJobServiceImpl#cancelGuideMassedJob`(impl:76-79):
    /// {"task_id"} → void。
    pub fn cancelGuideMassedJob(self: *GuideMassedJobService, io: std.Io, task_id: []const u8) Done {
        return self.postDone(io, .guide_cancel_massed_job, .{ .task_id = task_id });
    }
};

// ---------------------------------------------------------------------------
// 契约测试:5 端点 URL/method/请求体字段名(逐字对照 WxMpApiUrl.Guide +
// WxMpGuideMassedJobServiceImpl + WxMpGuideMaterialInfo 的 @SerializedName)
// ---------------------------------------------------------------------------

test "Guide MassedJob 契约: 5 端点 URL/method/请求体 (WxMpGuideMassedJobServiceImpl)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/", .response = "{\"errcode\":0,\"task_result\":[{\"task_id\":9}],\"list\":[],\"job\":{\"task_id\":9}}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideMassedJobService{ .svc = &fx.svc };
    const io = fx.threaded.io();
    const openids = [_][]const u8{ "U1", "U2" };
    const materials = [_]GuideMaterialInfo{
        .{ .material_type = 1, .word = "HELLO" },
        .{ .material_type = 49, .title = "TITLE", .appid = "APPID", .path = "PAGES/I", .media_id = "MID" },
    };

    // 1 ADD_GUIDE_MASSED_JOB:7 字段,material 为 bean 数组(null 字段省略),响应 "task_result"
    switch (svc.addGuideMassedJob(io, "ACC", "GOPEN", "TASK", "REMARK", 1700000000, &openids, &materials)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"task_result\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideMassedAdd;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/addguidemassendjob") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_account\":\"ACC\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"guide_openid\":\"GOPEN\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"task_name\":\"TASK\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"task_remark\":\"REMARK\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"push_time\":1700000000") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":[\"U1\",\"U2\"]") != null);
    // 第一项:type + word(其余 null 字段省略);第二项:6 字段齐全
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"type\":1,\"word\":\"HELLO\"}") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"title\":\"TITLE\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"appid\":\"APPID\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"path\":\"PAGES/I\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"MID\"") != null);
    // 第一项中不应出现未设置的 null 字段
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":1,\"media_id\"") == null);

    // 2 GET_GUIDE_MASSED_JOB_LIST:task_status 数组 + offset/limit,响应 "list"
    const status = [_]i64{ 0, 1 };
    switch (svc.getGuideMassedJobList(io, "ACC", "GOPEN", &status, 0, 10)) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"list\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideMassedList;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidemassendjoblist") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"task_status\":[0,1]") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"offset\":0") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"limit\":10") != null);

    // 3 GET_GUIDE_MASSED_JOB:{"task_id"},响应 "job"
    switch (svc.getGuideMassedJob(io, "T9")) {
        .ok => |raw| {
            defer gpa.free(raw);
            try testing.expect(std.mem.indexOf(u8, raw, "\"job\"") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideMassedGet;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidemassendjob?") != null);
    try testing.expectEqualStrings("{\"task_id\":\"T9\"}", mock.body());

    // 4 UPDATE_GUIDE_MASSED_JOB:task_id 开头 6 字段 → void
    switch (svc.updateGuideMassedJob(io, "T9", "TASK2", "REMARK2", 1700000001, &openids, &materials)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideMassedUpdate;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/updateguidemassendjob") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"task_id\":\"T9\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"task_name\":\"TASK2\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"push_time\":1700000001") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"openid\":[\"U1\",\"U2\"]") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "{\"type\":1,\"word\":\"HELLO\"}") != null);

    // 5 CANCEL_GUIDE_MASSED_JOB:{"task_id"} → void
    switch (svc.cancelGuideMassedJob(io, "T9")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideMassedCancel;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/cancelguidemassendjob") != null);
    try testing.expectEqualStrings("{\"task_id\":\"T9\"}", mock.body());

    try testing.expectEqual(@as(usize, 5), mock.calls);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
}
