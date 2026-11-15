//! 代码管理服务 —— 对应 Java `api.WxMaCodeService` + `api.impl.WxMaCodeServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Code`:
//! - commit/submitAudit:请求体由调用方预构建(对应 `WxMaCodeCommitRequest` /
//!   `WxMaCodeSubmitAuditRequest`,含 item_list/ext_config 等复杂字段,
//!   预构建 JSON 体最忠实,同 qrcode/getwxacodeunlimit 的 scene 模式);
//! - getQrCode:GET /wxa/get_qrcode?path=(自动 URL 编码),响应为二维码图片
//!   二进制(gpa 拥有,调用方负责 free);
//! - getCategory/getPage:列表字段缺失时返回 null(对应 Java 返回 null)。
//! errcode≠0 已由基座折叠为 `.err`;release/getSupportVersion/getVersionInfo
//! 的空对象体 "{}" 显式发送以保持 POST 语义(Java `post(url, "{}")`)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const COMMIT_URL = "https://api.weixin.qq.com/wxa/commit";
const GET_QRCODE_URL = "https://api.weixin.qq.com/wxa/get_qrcode";
const GET_CATEGORY_URL = "https://api.weixin.qq.com/wxa/get_category";
const GET_PAGE_URL = "https://api.weixin.qq.com/wxa/get_page";
const SUBMIT_AUDIT_URL = "https://api.weixin.qq.com/wxa/submit_audit";
const GET_AUDIT_STATUS_URL = "https://api.weixin.qq.com/wxa/get_auditstatus";
const GET_LATEST_AUDIT_STATUS_URL = "https://api.weixin.qq.com/wxa/get_latest_auditstatus";
const RELEASE_URL = "https://api.weixin.qq.com/wxa/release";
const CHANGE_VISIT_STATUS_URL = "https://api.weixin.qq.com/wxa/change_visitstatus";
const REVERT_CODE_RELEASE_URL = "https://api.weixin.qq.com/wxa/revertcoderelease";
const GET_SUPPORT_VERSION_URL = "https://api.weixin.qq.com/cgi-bin/wxopen/getweappsupportversion";
const SET_SUPPORT_VERSION_URL = "https://api.weixin.qq.com/cgi-bin/wxopen/setweappsupportversion";
const UNDO_CODE_AUDIT_URL = "https://api.weixin.qq.com/wxa/undocodeaudit";
const GET_VERSION_INFO_URL = "https://api.weixin.qq.com/wxa/getversioninfo";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `code.WxMaCodeAuditStatus`(auditId 兼容 auditid/auditId 两种键)。gpa 拥有。
pub const AuditStatus = struct {
    gpa: std.mem.Allocator,
    audit_id: ?i64,
    /// 0 审核成功,1 审核失败,2 审核中。
    status: ?i64,
    /// status=1 被拒时的拒绝原因。
    reason: ?[]const u8,
    /// 审核失败的小程序截图示例(media_id 列表,丨 分隔)。
    screen_shot: ?[]const u8,
    user_version: ?[]const u8,
    user_desc: ?[]const u8,
    submit_audit_time: ?[]const u8,

    pub fn deinit(self: *AuditStatus) void {
        const g = self.gpa;
        if (self.reason) |s| g.free(@constCast(s));
        if (self.screen_shot) |s| g.free(@constCast(s));
        if (self.user_version) |s| g.free(@constCast(s));
        if (self.user_desc) |s| g.free(@constCast(s));
        if (self.submit_audit_time) |s| g.free(@constCast(s));
    }

    /// 允许从 `const` 借用值上释放。
    pub fn deinitConst(self: *const AuditStatus) void {
        const g = self.gpa;
        if (self.reason) |s| g.free(s);
        if (self.screen_shot) |s| g.free(s);
        if (self.user_version) |s| g.free(s);
        if (self.user_desc) |s| g.free(s);
        if (self.submit_audit_time) |s| g.free(s);
    }
};

fn parseAuditStatus(gpa: std.mem.Allocator, v: json_util.Value) !AuditStatus {
    const reason = if (json_util.getStr(v, "reason")) |s| try gpa.dupe(u8, s) else null;
    const shot = if (json_util.getStr(v, "screenshot")) |s| try gpa.dupe(u8, s) else null;
    const uv = if (json_util.getStr(v, "user_version")) |s| try gpa.dupe(u8, s) else null;
    const ud = if (json_util.getStr(v, "user_desc")) |s| try gpa.dupe(u8, s) else null;
    const sat = if (json_util.getStr(v, "submit_audit_time")) |s| try gpa.dupe(u8, s) else null;
    return .{
        .gpa = gpa,
        // 对应 @SerializedName(value="auditId", alternate={"auditid"}):双键兼容。
        .audit_id = json_util.getInt(v, "auditid") orelse json_util.getInt(v, "auditId"),
        .status = json_util.getInt(v, "status"),
        .reason = reason,
        .screen_shot = shot,
        .user_version = uv,
        .user_desc = ud,
        .submit_audit_time = sat,
    };
}

/// 对应 `code.WxMaCodeVersionDistribution`(uv_info 为 Map<String,Float>,
/// 此处保留原始 JSON 字符串由调用方解析)。gpa 拥有。
pub const VersionDistribution = struct {
    gpa: std.mem.Allocator,
    now_version: ?[]const u8,
    /// uv_info 的原始 JSON(对象文本)。
    uv_info: ?[]const u8,

    pub fn deinit(self: *VersionDistribution) void {
        const g = self.gpa;
        if (self.now_version) |s| g.free(@constCast(s));
        if (self.uv_info) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const VersionDistribution) void {
        const g = self.gpa;
        if (self.now_version) |s| g.free(s);
        if (self.uv_info) |s| g.free(s);
    }
};

/// 版本阶段信息(体验版/线上版共用骨架:time/version/desc)。
pub const VersionPhase = struct {
    gpa: std.mem.Allocator,
    time: ?i64,
    version: ?[]const u8,
    desc: ?[]const u8,

    pub fn deinit(self: *VersionPhase) void {
        const g = self.gpa;
        if (self.version) |s| g.free(@constCast(s));
        if (self.desc) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const VersionPhase) void {
        const g = self.gpa;
        if (self.version) |s| g.free(s);
        if (self.desc) |s| g.free(s);
    }
};

/// 对应 `code.WxMaCodeVersionInfo`(exp_info / release_info)。gpa 拥有。
pub const VersionInfo = struct {
    gpa: std.mem.Allocator,
    exp_info: ?VersionPhase,
    release_info: ?VersionPhase,

    pub fn deinit(self: *VersionInfo) void {
        if (self.exp_info) |*p| p.deinit();
        if (self.release_info) |*p| p.deinit();
    }

    pub fn deinitConst(self: *const VersionInfo) void {
        if (self.exp_info) |*p| @constCast(p).deinit();
        if (self.release_info) |*p| @constCast(p).deinit();
    }
};

/// 对应 `code.WxMaCodeSubmitAuditItem`(getCategory 复用该 bean)。gpa 拥有。
pub const CategoryItem = struct {
    gpa: std.mem.Allocator,
    first_class: ?[]const u8,
    second_class: ?[]const u8,
    third_class: ?[]const u8,
    first_id: ?i64,
    second_id: ?i64,
    third_id: ?i64,
    address: ?[]const u8,
    tag: ?[]const u8,
    title: ?[]const u8,

    pub fn deinit(self: *CategoryItem) void {
        const g = self.gpa;
        inline for (.{ "first_class", "second_class", "third_class", "address", "tag", "title" }) |f| {
            if (@field(self, f)) |s| g.free(@constCast(s));
        }
    }

    pub fn deinitConst(self: *const CategoryItem) void {
        const g = self.gpa;
        inline for (.{ "first_class", "second_class", "third_class", "address", "tag", "title" }) |f| {
            if (@field(self, f)) |s| g.free(s);
        }
    }
};

fn parseCategoryItem(gpa: std.mem.Allocator, v: json_util.Value) !CategoryItem {
    var out = CategoryItem{
        .gpa = gpa,
        .first_class = null,
        .second_class = null,
        .third_class = null,
        .first_id = json_util.getInt(v, "first_id"),
        .second_id = json_util.getInt(v, "second_id"),
        .third_id = json_util.getInt(v, "third_id"),
        .address = null,
        .tag = null,
        .title = null,
    };
    out.first_class = if (json_util.getStr(v, "first_class")) |s| try gpa.dupe(u8, s) else null;
    out.second_class = if (json_util.getStr(v, "second_class")) |s| try gpa.dupe(u8, s) else null;
    out.third_class = if (json_util.getStr(v, "third_class")) |s| try gpa.dupe(u8, s) else null;
    out.address = if (json_util.getStr(v, "address")) |s| try gpa.dupe(u8, s) else null;
    out.tag = if (json_util.getStr(v, "tag")) |s| try gpa.dupe(u8, s) else null;
    out.title = if (json_util.getStr(v, "title")) |s| try gpa.dupe(u8, s) else null;
    return out;
}

/// 释放 `getCategory` 的返回(每元素 + 切片本身)。
pub fn free_category_list(gpa: std.mem.Allocator, items: []CategoryItem) void {
    for (items) |*it| it.deinit();
    gpa.free(items);
}

/// 释放 `getPage` 的返回(每元素字符串 + 切片本身)。
pub fn free_page_list(gpa: std.mem.Allocator, pages: [][]const u8) void {
    for (pages) |p| gpa.free(@constCast(p));
    gpa.free(pages);
}

// --- service -------------------------------------------------------------------

pub const CodeService = struct {
    svc: *mp_service.Service,

    /// 对应 `commit(WxMaCodeCommitRequest)`:POST /wxa/commit。
    /// 请求体预构建(template_id/user_version/user_desc/ext_json 等)。
    pub fn commit(self: *CodeService, io: std.Io, body: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, COMMIT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getQrCode(path)`:GET /wxa/get_qrcode?path=(URL 编码),
    /// 响应为二维码图片二进制(gpa 拥有,调用方 free)。
    /// path 为 null/空时不带参数(对应 Java isNotBlank 判断)。
    pub fn getQrCode(self: *CodeService, io: std.Io, path: ?[]const u8) WxResult([]u8) {
        var qbuf: [1]mp_service.Query = undefined;
        var query: []const mp_service.Query = &.{};
        if (path) |p| {
            if (p.len > 0) {
                qbuf[0] = .{ .key = "path", .value = p };
                query = qbuf[0..];
            }
        }
        return self.svc.get(io, GET_QRCODE_URL, query);
    }

    /// 对应 `getCategory()`:GET /wxa/get_category → category_list;
    /// 字段缺失时返回 null(对应 Java 返回 null)。
    pub fn getCategory(self: *CodeService, io: std.Io) WxResult(?[]CategoryItem) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_CATEGORY_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_category not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "category_list") orelse return .{ .ok = null };
        var out = std.ArrayList(CategoryItem).empty;
        errdefer {
            for (out.items) |*it| it.deinit();
            out.deinit(gpa);
        }
        for (arr.items) |item| {
            const it = parseCategoryItem(gpa, item) catch
                return .{ .err = WxError.transport(gpa, "get_category bad item", .{}) };
            out.append(gpa, it) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        const owned = out.toOwnedSlice(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = owned };
    }

    /// 对应 `getPage()`:GET /wxa/get_page → page_list;缺失时返回 null。
    pub fn getPage(self: *CodeService, io: std.Io) WxResult(?[][]const u8) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_PAGE_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_page not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "page_list") orelse return .{ .ok = null };
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |s| gpa.free(@constCast(s));
            out.deinit(gpa);
        }
        for (arr.items) |item| {
            const s: []const u8 = switch (item) {
                .string => |str| str,
                else => "",
            };
            const d = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            errdefer gpa.free(@constCast(d));
            out.append(gpa, d) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        const owned = out.toOwnedSlice(gpa) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = owned };
    }

    /// 对应 `submitAudit(WxMaCodeSubmitAuditRequest)`:POST /wxa/submit_audit
    /// (请求体预构建,含 item_list),响应取 auditid。
    pub fn submitAudit(self: *CodeService, io: std.Io, body: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, SUBMIT_AUDIT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "submit_audit not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = json_util.getIntOr(parsed.value, "auditid", 0) };
    }

    /// 对应 `getAuditStatus(auditId)`:POST /wxa/get_auditstatus {"auditid":N}。
    pub fn getAuditStatus(self: *CodeService, io: std.Io, audit_id: i64) WxResult(AuditStatus) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"auditid\":{d}}}", .{audit_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_AUDIT_STATUS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_auditstatus not json", .{}) };
        defer parsed.deinit();
        const out = parseAuditStatus(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "get_auditstatus parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getLatestAuditStatus()`:GET /wxa/get_latest_auditstatus。
    pub fn getLatestAuditStatus(self: *CodeService, io: std.Io) WxResult(AuditStatus) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, GET_LATEST_AUDIT_STATUS_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "get_latest_auditstatus not json", .{}) };
        defer parsed.deinit();
        const out = parseAuditStatus(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "get_latest_auditstatus parse failed", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `release()`:POST /wxa/release(空对象体)。
    pub fn release(self: *CodeService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, RELEASE_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `changeVisitStatus(action)`:POST /wxa/change_visitstatus {"action":...}。
    pub fn changeVisitStatus(self: *CodeService, io: std.Io, action: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"action\":\"{s}\"}}", .{action}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, CHANGE_VISIT_STATUS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `revertCodeRelease()`:GET /wxa/revertcoderelease。
    pub fn revertCodeRelease(self: *CodeService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, REVERT_CODE_RELEASE_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getSupportVersion()`:POST /cgi-bin/wxopen/getweappsupportversion(空对象体)。
    pub fn getSupportVersion(self: *CodeService, io: std.Io) WxResult(VersionDistribution) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_SUPPORT_VERSION_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getweappsupportversion not json", .{}) };
        defer parsed.deinit();
        const nv = if (json_util.getStr(parsed.value, "now_version")) |s|
            gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }
        else
            null;
        var uv: ?[]const u8 = null;
        if (json_util.getObject(parsed.value, "uv_info")) |v| {
            uv = json_util.stringify(gpa, v) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = .{ .gpa = gpa, .now_version = nv, .uv_info = uv } };
    }

    /// 对应 `setSupportVersion(version)`:
    /// POST /cgi-bin/wxopen/setweappsupportversion {"version":...}。
    pub fn setSupportVersion(self: *CodeService, io: std.Io, version: []const u8) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\"}}", .{version}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SET_SUPPORT_VERSION_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `undoCodeAudit()`:GET /wxa/undocodeaudit。
    pub fn undoCodeAudit(self: *CodeService, io: std.Io) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.get(io, UNDO_CODE_AUDIT_URL, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getVersionInfo()`:POST /wxa/getversioninfo(空对象体)。
    pub fn getVersionInfo(self: *CodeService, io: std.Io) WxResult(VersionInfo) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_VERSION_INFO_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getversioninfo not json", .{}) };
        defer parsed.deinit();
        var out = VersionInfo{ .gpa = gpa, .exp_info = null, .release_info = null };
        if (json_util.getObject(parsed.value, "exp_info")) |v| {
            out.exp_info = .{
                .gpa = gpa,
                .time = json_util.getInt(v, "exp_time"),
                .version = if (json_util.getStr(v, "exp_version")) |s| gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) } else null,
                .desc = if (json_util.getStr(v, "exp_desc")) |s| gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) } else null,
            };
        }
        if (json_util.getObject(parsed.value, "release_info")) |v| {
            out.release_info = .{
                .gpa = gpa,
                .time = json_util.getInt(v, "release_time"),
                .version = if (json_util.getStr(v, "release_version")) |s| gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) } else null,
                .desc = if (json_util.getStr(v, "release_desc")) |s| gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) } else null,
            };
        }
        return .{ .ok = out };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "code commit + submitAudit: prebuilt body + auditid" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "/wxa/commit", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "submit_audit", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"auditid\":12345}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CodeService{ .svc = &base };

    // commit:预构建体原样发出
    const r1 = s.commit(io, "{\"template_id\":1,\"user_version\":\"v0.1.0\",\"user_desc\":\"d\"}");
    try std.testing.expect(!r1.failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/wxa/commit") != null);
    try std.testing.expectEqualStrings("{\"template_id\":1,\"user_version\":\"v0.1.0\",\"user_desc\":\"d\"}", m.last_body);

    // submitAudit:响应取 auditid
    const r2 = switch (s.submitAudit(io, "{\"item_list\":[{\"address\":\"index\",\"tag\":\"t\",\"title\":\"T\"}]}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 12345), r2);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "submit_audit") != null);
    const parsed = try json_util.parse(gpa, m.last_body);
    defer parsed.deinit();
    try std.testing.expect(json_util.getArray(parsed.value, "item_list") != null);
}

test "code getQrCode: binary bytes + path url-encoded query" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_qrcode", .response = "\x89PNG fake code" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CodeService{ .svc = &base };

    // 带 path:path 参与 URL 编码(与 Java URLEncoder 对齐)
    const img = switch (s.getQrCode(io, "pages/index/index")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(img);
    try std.testing.expectEqualStrings("\x89PNG fake code", img);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "get_qrcode?path=pages%2Findex%2Findex") != null);

    // 空 path:不带 path 参数(与 Java isNotBlank 对齐;token 仍由基座附加)
    const img2 = switch (s.getQrCode(io, "")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(img2);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "path=") == null);
}

test "code getCategory + getPage: parse lists, null when missing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "get_category", .response = "{\"errcode\":0,\"category_list\":[{\"first_class\":\"餐饮\",\"first_id\":1,\"second_class\":\"快餐\",\"second_id\":2,\"third_id\":null,\"address\":\"index\",\"tag\":\"t\",\"title\":\"T\"}]}" },
        .{ .match = "get_page", .response = "{\"errcode\":0,\"page_list\":[\"pages/index/index\",\"pages/logs/logs\"]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CodeService{ .svc = &base };

    const cats = switch (s.getCategory(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    const list = cats orelse return error.ExpectedList;
    defer free_category_list(gpa, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("餐饮", list[0].first_class.?);
    try std.testing.expectEqual(@as(?i64, 1), list[0].first_id);
    try std.testing.expectEqualStrings("T", list[0].title.?);

    const pages = switch (s.getPage(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    const plist = pages orelse return error.ExpectedList;
    defer free_page_list(gpa, plist);
    try std.testing.expectEqual(@as(usize, 2), plist.len);
    try std.testing.expectEqualStrings("pages/logs/logs", plist[1]);
}

test "code audit status both ways" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        // 注意顺序:/wxa/get_auditstatus 不是 get_latest_auditstatus 的子串,二者可共存
        .{ .match = "get_auditstatus", .response = "{\"errcode\":0,\"auditid\":42,\"status\":0}" },
        .{ .match = "get_latest_auditstatus", .response = "{\"errcode\":0,\"auditid\":43,\"status\":1,\"reason\":\"bad\",\"user_version\":\"v1.0\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CodeService{ .svc = &base };

    // getAuditStatus:POST {"auditid":N}
    const st1 = switch (s.getAuditStatus(io, 42)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var st1v = st1;
    defer st1v.deinit();
    try std.testing.expectEqual(@as(?i64, 42), st1v.audit_id);
    try std.testing.expectEqual(@as(?i64, 0), st1v.status);
    try std.testing.expectEqualStrings("{\"auditid\":42}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "get_auditstatus") != null);

    // getLatestAuditStatus:GET
    const st2 = switch (s.getLatestAuditStatus(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var st2v = st2;
    defer st2v.deinit();
    try std.testing.expectEqual(@as(?i64, 43), st2v.audit_id);
    try std.testing.expectEqualStrings("bad", st2v.reason.?);
    try std.testing.expectEqualStrings("v1.0", st2v.user_version.?);
}

test "code support/version/release lifecycle" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getweappsupportversion", .response = "{\"errcode\":0,\"now_version\":\"1.0.0\",\"uv_info\":{\"7.0.0\":90,\"6.7.3\":10}}" },
        .{ .match = "setweappsupportversion", .response = "{\"errcode\":0}" },
        .{ .match = "/wxa/release", .response = "{\"errcode\":0}" },
        .{ .match = "revertcoderelease", .response = "{\"errcode\":0}" },
        .{ .match = "undocodeaudit", .response = "{\"errcode\":0}" },
        .{ .match = "change_visitstatus", .response = "{\"errcode\":0}" },
        .{ .match = "getversioninfo", .response = "{\"errcode\":0,\"exp_info\":{\"exp_time\":1000,\"exp_version\":\"v0.2.0\",\"exp_desc\":\"dev\"},\"release_info\":{\"release_time\":2000,\"release_version\":\"v1.0.0\",\"release_desc\":\"online\"}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CodeService{ .svc = &base };

    // getSupportVersion:POST {} → now_version + uv_info 原始 JSON
    const dist = switch (s.getSupportVersion(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var distv = dist;
    defer distv.deinit();
    try std.testing.expectEqualStrings("1.0.0", distv.now_version.?);
    try std.testing.expect(std.mem.indexOf(u8, distv.uv_info.?, "7.0.0") != null);
    try std.testing.expectEqualStrings("{}", m.last_body);

    // setSupportVersion
    const r1 = s.setSupportVersion(io, "1.0.0");
    try std.testing.expect(!r1.failed());
    try std.testing.expectEqualStrings("{\"version\":\"1.0.0\"}", m.last_body);

    // release/revert/undo/change_visitstatus
    try std.testing.expect(!s.release(io).failed());
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expect(!s.revertCodeRelease(io).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "revertcoderelease") != null);
    try std.testing.expect(!s.undoCodeAudit(io).failed());
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "undocodeaudit") != null);
    try std.testing.expect(!s.changeVisitStatus(io, "open").failed());
    try std.testing.expectEqualStrings("{\"action\":\"open\"}", m.last_body);

    // getVersionInfo
    const vi = switch (s.getVersionInfo(io)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var viv = vi;
    defer viv.deinit();
    try std.testing.expectEqual(@as(?i64, 1000), viv.exp_info.?.time);
    try std.testing.expectEqualStrings("v0.2.0", viv.exp_info.?.version.?);
    try std.testing.expectEqualStrings("v1.0.0", viv.release_info.?.version.?);
}
