//! 客服管理服务 —— 对应 Java `api.WxMaKefuService` + `api.impl.WxMaKefuServiceImpl`。
//!
//! URL 对齐 impl 内私有常量:
//! - kfList:GET /cgi-bin/customservice/getkflist;
//! - kfAccountAdd/Update:POST /customservice/kfaccount/add|update;
//! - kfAccountDel:GET /customservice/kfaccount/del?kf_account=(URL 编码);
//! - kfSessionCreate/Close:POST /customservice/kfsession/create|close;
//! - kfSessionGet:GET /customservice/kfsession/getsession?openid=;
//! - kfSessionList:GET /customservice/kfsession/getsessionlist?kf_account=。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const KFLIST_GET_URL = "https://api.weixin.qq.com/cgi-bin/customservice/getkflist";
const KFACCOUNT_ADD_URL = "https://api.weixin.qq.com/customservice/kfaccount/add";
const KFACCOUNT_UPDATE_URL = "https://api.weixin.qq.com/customservice/kfaccount/update";
const KFACCOUNT_DEL_URL = "https://api.weixin.qq.com/customservice/kfaccount/del";
const KFSESSION_CREATE_URL = "https://api.weixin.qq.com/customservice/kfsession/create";
const KFSESSION_CLOSE_URL = "https://api.weixin.qq.com/customservice/kfsession/close";
const KFSESSION_GET_URL = "https://api.weixin.qq.com/customservice/kfsession/getsession";
const KFSESSION_LIST_URL = "https://api.weixin.qq.com/customservice/kfsession/getsessionlist";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `kefu.request.WxMaKfAccountRequest`(borrowed,to_json)。
pub const KfAccountRequest = struct {
    kf_account: []const u8,
    kf_nick: []const u8,
    kf_pwd: ?[]const u8 = null,

    pub fn to_json(self: KfAccountRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"kf_account\":");
        try js(w, self.kf_account);
        try w.writeAll(",\"kf_nick\":");
        try js(w, self.kf_nick);
        if (self.kf_pwd) |p| {
            try w.writeAll(",\"kf_pwd\":");
            try js(w, p);
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `kefu.request.WxMaKfSessionRequest`(borrowed,to_json)。
pub const KfSessionRequest = struct {
    openid: []const u8,
    kf_account: []const u8,

    pub fn to_json(self: KfSessionRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid\":");
        try js(w, self.openid);
        try w.writeAll(",\"kf_account\":");
        try js(w, self.kf_account);
        try w.writeAll("}");
        return out.toOwnedSlice();
    }
};

/// 对应 `kefu.WxMaKfInfo`。gpa 拥有。
pub const KfInfo = struct {
    gpa: std.mem.Allocator,
    kf_account: ?[]const u8,
    kf_nick: ?[]const u8,
    kf_id: ?[]const u8,
    kf_headimgurl: ?[]const u8,
    kf_wx: ?[]const u8,
    invite_wx: ?[]const u8,
    invite_expire_time: ?i64,
    invite_status: ?[]const u8,

    pub fn deinit(self: *KfInfo) void {
        const g = self.gpa;
        inline for (.{ "kf_account", "kf_nick", "kf_id", "kf_headimgurl", "kf_wx", "invite_wx", "invite_status" }) |f| {
            if (@field(self, f)) |s| g.free(@constCast(s));
        }
    }
};

/// 对应 `kefu.WxMaKfList`。gpa 拥有。
pub const KfList = struct {
    gpa: std.mem.Allocator,
    kf_list: []KfInfo,

    pub fn deinit(self: *KfList) void {
        for (self.kf_list) |*it| it.deinit();
        self.gpa.free(self.kf_list);
    }
};

/// 对应 `kefu.WxMaKfSession`(kf_session_getsession 响应)。gpa 拥有。
pub const KfSession = struct {
    gpa: std.mem.Allocator,
    kf_account: ?[]const u8,
    createtime: ?i64,

    pub fn deinit(self: *KfSession) void {
        if (self.kf_account) |s| self.gpa.free(@constCast(s));
    }
};

/// 对应 `kefu.WxMaKfSessionList.SessionInfo`。gpa 拥有。
pub const SessionInfo = struct {
    gpa: std.mem.Allocator,
    openid: ?[]const u8,
    createtime: ?i64,
    latest_time: ?i64,

    pub fn deinit(self: *SessionInfo) void {
        if (self.openid) |s| self.gpa.free(@constCast(s));
    }
};

/// 对应 `kefu.WxMaKfSessionList`。gpa 拥有。
pub const KfSessionList = struct {
    gpa: std.mem.Allocator,
    sessionlist: []SessionInfo,

    pub fn deinit(self: *KfSessionList) void {
        for (self.sessionlist) |*it| it.deinit();
        self.gpa.free(self.sessionlist);
    }
};

fn parseKfInfo(gpa: std.mem.Allocator, v: json_util.Value) !KfInfo {
    return .{
        .gpa = gpa,
        .kf_account = if (json_util.getStr(v, "kf_account")) |s| try gpa.dupe(u8, s) else null,
        .kf_nick = if (json_util.getStr(v, "kf_nick")) |s| try gpa.dupe(u8, s) else null,
        .kf_id = if (json_util.getStr(v, "kf_id")) |s| try gpa.dupe(u8, s) else null,
        .kf_headimgurl = if (json_util.getStr(v, "kf_headimgurl")) |s| try gpa.dupe(u8, s) else null,
        .kf_wx = if (json_util.getStr(v, "kf_wx")) |s| try gpa.dupe(u8, s) else null,
        .invite_wx = if (json_util.getStr(v, "invite_wx")) |s| try gpa.dupe(u8, s) else null,
        .invite_expire_time = json_util.getInt(v, "invite_expire_time"),
        .invite_status = if (json_util.getStr(v, "invite_status")) |s| try gpa.dupe(u8, s) else null,
    };
}

// --- service -------------------------------------------------------------------

pub const KefuService = struct {
    svc: *mp_service.Service,

    /// 对应 `kfList()`:GET /cgi-bin/customservice/getkflist。
    pub fn kfList(self: *KefuService, io: std.Io) WxResult(KfList) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, KFLIST_GET_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getkflist not json", .{}) };
        defer parsed.deinit();
        var out = std.ArrayList(KfInfo).empty;
        errdefer {
            for (out.items) |*it| it.deinit();
            out.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "kf_list")) |arr| {
            for (arr.items) |item| {
                const it = parseKfInfo(gpa, item) catch
                    return .{ .err = WxError.transport(gpa, "kf item parse failed", .{}) };
                out.append(gpa, it) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        const owned = out.toOwnedSlice(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .kf_list = owned } };
    }

    /// 对应 `kfAccountAdd(WxMaKfAccountRequest)`:POST /customservice/kfaccount/add。
    pub fn kfAccountAdd(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        return self.postKfAccount(io, KFACCOUNT_ADD_URL, req);
    }

    /// 对应 `kfAccountUpdate(WxMaKfAccountRequest)`:POST /customservice/kfaccount/update。
    pub fn kfAccountUpdate(self: *KefuService, io: std.Io, req: KfAccountRequest) Done {
        return self.postKfAccount(io, KFACCOUNT_UPDATE_URL, req);
    }

    fn postKfAccount(self: *KefuService, io: std.Io, url: []const u8, req: KfAccountRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `kfAccountDel(kfAccount)`:
    /// GET /customservice/kfaccount/del?kf_account=(URL 编码)。
    pub fn kfAccountDel(self: *KefuService, io: std.Io, kf_account: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, KFACCOUNT_DEL_URL, &.{.{ .key = "kf_account", .value = kf_account }})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `kfSessionCreate(openid, kfAccount)`:
    /// POST /customservice/kfsession/create {"openid":...,"kf_account":...}。
    pub fn kfSessionCreate(self: *KefuService, io: std.Io, openid: []const u8, kf_account: []const u8) Done {
        return self.postKfSession(io, KFSESSION_CREATE_URL, openid, kf_account);
    }

    /// 对应 `kfSessionClose(openid, kfAccount)`:
    /// POST /customservice/kfsession/close。
    pub fn kfSessionClose(self: *KefuService, io: std.Io, openid: []const u8, kf_account: []const u8) Done {
        return self.postKfSession(io, KFSESSION_CLOSE_URL, openid, kf_account);
    }

    fn postKfSession(self: *KefuService, io: std.Io, url: []const u8, openid: []const u8, kf_account: []const u8) Done {
        const gpa = self.svc.gpa;
        const req = KfSessionRequest{ .openid = openid, .kf_account = kf_account };
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `kfSessionGet(openid)`:
    /// GET /customservice/kfsession/getsession?openid= → kf_account/createtime。
    pub fn kfSessionGet(self: *KefuService, io: std.Io, openid: []const u8) WxResult(KfSession) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, KFSESSION_GET_URL, &.{.{ .key = "openid", .value = openid }})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getsession not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .kf_account = if (json_util.getStr(parsed.value, "kf_account")) |s|
                gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
            else
                null,
            .createtime = json_util.getInt(parsed.value, "createtime"),
        } };
    }

    /// 对应 `kfSessionList(kfAccount)`:
    /// GET /customservice/kfsession/getsessionlist?kf_account= → sessionlist。
    pub fn kfSessionList(self: *KefuService, io: std.Io, kf_account: []const u8) WxResult(KfSessionList) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, KFSESSION_LIST_URL, &.{.{ .key = "kf_account", .value = kf_account }})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getsessionlist not json", .{}) };
        defer parsed.deinit();
        var out = std.ArrayList(SessionInfo).empty;
        errdefer {
            for (out.items) |*it| it.deinit();
            out.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "sessionlist")) |arr| {
            for (arr.items) |item| {
                const it = SessionInfo{
                    .gpa = gpa,
                    .openid = if (json_util.getStr(item, "openid")) |s|
                        gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
                    else
                        null,
                    .createtime = json_util.getInt(item, "createtime"),
                    .latest_time = json_util.getInt(item, "latest_time"),
                };
                out.append(gpa, it) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        const owned = out.toOwnedSlice(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{ .gpa = gpa, .sessionlist = owned } };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "kefu kfList + kfAccount add/update/del" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getkflist", .response = "{\"errcode\":0,\"kf_list\":[{\"kf_account\":\"kf1@test\",\"kf_nick\":\"客服1\",\"kf_id\":\"KFID1\",\"kf_headimgurl\":\"http://h/1.png\",\"kf_wx\":\"wx1\",\"invite_wx\":\"iw1\",\"invite_expire_time\":1700000000,\"invite_status\":\"waiting\"}]}" },
        .{ .match = "kfaccount/add", .response = "{\"errcode\":0}" },
        .{ .match = "kfaccount/update", .response = "{\"errcode\":0}" },
        .{ .match = "kfaccount/del", .response = "{\"errcode\":0}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = KefuService{ .svc = &base };

    // kfList
    const r = switch (s.kfList(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var list = r;
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.kf_list.len);
    try std.testing.expectEqualStrings("kf1@test", list.kf_list[0].kf_account.?);
    try std.testing.expectEqualStrings("客服1", list.kf_list[0].kf_nick.?);
    try std.testing.expectEqual(@as(?i64, 1700000000), list.kf_list[0].invite_expire_time);

    // add(kf_pwd 省略为 null 时不出现在 body)
    try std.testing.expect(!s.kfAccountAdd(io, .{ .kf_account = "kf2@test", .kf_nick = "客服2" }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "kfaccount/add") != null);
    try std.testing.expectEqualStrings("{\"kf_account\":\"kf2@test\",\"kf_nick\":\"客服2\"}", m.last_body);

    // update(带 kf_pwd)
    try std.testing.expect(!s.kfAccountUpdate(io, .{ .kf_account = "kf2@test", .kf_nick = "客服2", .kf_pwd = "pw" }).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "kfaccount/update") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_body, "\"kf_pwd\":\"pw\"") != null);

    // del:GET + URL 编码 query
    try std.testing.expect(!s.kfAccountDel(io, "kf2@test").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "kfaccount/del?kf_account=kf2%40test") != null);
}

test "kefu sessions: create/close/get/list" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        // 注意顺序:getsessionlist 必须在 getsession 之前(后者是前者的前缀子串)
        .{ .match = "kfsession/create", .response = "{\"errcode\":0}" },
        .{ .match = "kfsession/close", .response = "{\"errcode\":0}" },
        .{ .match = "getsessionlist", .response = "{\"errcode\":0,\"sessionlist\":[{\"openid\":\"o1\",\"createtime\":100,\"latest_time\":200}]}" },
        .{ .match = "getsession?openid", .response = "{\"errcode\":0,\"kf_account\":\"kf1@test\",\"createtime\":100}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = KefuService{ .svc = &base };

    // create
    try std.testing.expect(!s.kfSessionCreate(io, "o1", "kf1@test").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "kfsession/create") != null);
    try std.testing.expectEqualStrings("{\"openid\":\"o1\",\"kf_account\":\"kf1@test\"}", m.last_body);

    // close
    try std.testing.expect(!s.kfSessionClose(io, "o1", "kf1@test").failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "kfsession/close") != null);

    // get:?openid= query
    const sess = switch (s.kfSessionGet(io, "o1")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var sv = sess;
    defer sv.deinit();
    try std.testing.expectEqualStrings("kf1@test", sv.kf_account.?);
    try std.testing.expectEqual(@as(?i64, 100), sv.createtime);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getsession?openid=o1") != null);

    // list:?kf_account= query
    const lst = switch (s.kfSessionList(io, "kf1@test")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var lv = lst;
    defer lv.deinit();
    try std.testing.expectEqual(@as(usize, 1), lv.sessionlist.len);
    try std.testing.expectEqualStrings("o1", lv.sessionlist[0].openid.?);
    try std.testing.expectEqual(@as(?i64, 200), lv.sessionlist[0].latest_time);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getsessionlist?kf_account=kf1%40test") != null);
}
