//! 用户服务 —— 逐字对齐 Java `api.WxMpUserService`(8 方法)+ `api.impl.WxMpUserServiceImpl`。
//!
//! 命名:全部采用 Java 的 camelCase 方法名(rule 2)。Java 的两个重载用 Zig 惯用法映射:
//!   - `userInfo(openid)` / `userInfo(openid, lang)` → 单函数 `userInfo(io, openid, lang: ?[]const u8)`;
//!   - `userInfoList(List)` / `userInfoList(WxMpUserQuery)` → `userInfoList` / `userInfoListByQuery`;
//!   - `userList(nextOpenid)` / `userList()` → `userList(io, next_openid)` / `userListAll(io)`。
//!
//! 底座(rule 3):
//!   - 所有 URL 路径来自 `../api_url.zig:User`,经 `api()`(= `api_url.url(Host.api, path)`)拼成绝对 URL;
//!   - 手工 query 串由 `common.mp_helpers.buildUrl`(内含 urlEncode)生成,不再依赖
//!     `service.zig:ApiUrl.*` 或本地 `Path` 常量;
//!   - `userListAll` 用 `common.mp_helpers.Paginator` 复刻 Java 的 while 累加翻页循环。
//!
//! Java↔Zig 语言差异(已按 Java 逻辑取舍,逐条说明):
//!   - `userInfo`: Java `lang==null → "zh_CN"` 且**总是**发 `&lang=`;旧 Zig 在 null 时省略该参数,
//!     本轮改为镜像 Java(始终带 lang,默认 zh_CN)。
//!   - query value: Java 直接字符串拼接不做 URL 编码;本轮走 `mp_helpers.buildUrl` 做百分号编码。
//!     对 openid/lang/next_openid 这类无特殊字符的值字节等价,且更安全。
//!   - `userList(nextOpenid)` 的 null → Zig 空串 "";空串表示「不带 next_openid 参数取首页」,
//!     对齐 Java `nextOpenid==null ? null : "next_openid="+nextOpenid`。
//!   - `userList()` 的 while 累加:openids 全量拼接、count 逐页累加、total **只取首页**(Java 循环内
//!     不更新 total)、next_openid 留空;`Paginator` 的 while 守卫由 `next_cursor` 表达。
//!   - `Service.execute*` 已统一折叠 errcode→`.err` 并注入 access_token,故本文件不重复实现。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `[]u8`/`[]i64` 等裸结果:调用方 `gpa.free()`;
//!   - 暴露 `[]const u8`/切片的结构体:`User`/`Followers`/`ChangeOpenid` 用 `deinit()`;
//!     `UserInfoBatchResult`/`ChangeOpenidResult` 逐元素 `deinit()` + `free` 切片本身;
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const mp_helpers = @import("common").mp_helpers;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;
const u_token = @import("common").token;

const api_url = @import("../api_url.zig");
const u_config = @import("../config.zig");
const u_http = @import("../http.zig");
const service_mod = @import("../service.zig");

/// host+path 绝对 URL,路径全部取自 `api_url.zig`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

/// 取 JSON 字符串字段并 dupe 成 gpa 拥有(缺失返回 null)。对应 Java `GsonHelper.getString`。
fn dupeStr(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    const s = json_util.getStr(v, key) orelse return null;
    return try gpa.dupe(u8, s);
}

/// POST 且只关心 errcode:成功即完成(errcode!=0 已在 Service.executeInternal 折叠为 .err)。
/// 对应 Java `void`/`Boolean` 方法 —— `.ok` 即 true、`.err` 即抛出。
fn postVoid(self: *UserService, io: std.Io, comptime path: []const u8, body: []const u8) Done {
    const resp = switch (self.svc.post(io, api(path), &.{}, body)) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    self.svc.gpa.free(resp);
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// 结果结构(全部 gpa 拥有,用毕 deinit)
// ---------------------------------------------------------------------------

/// 用户详情 —— 对应 Java `bean.result.WxMpUser`(常用字段子集)。
/// 字段 JSON 名对照 `WxMpUserGsonAdapter`:subscribe/openid/nickname/language/headimgurl/
/// subscribe_time/unionid/remark/groupid/tagid_list/privilege/... 本结构收录常用标量字段。
pub const User = struct {
    gpa: std.mem.Allocator,
    openid: []const u8,
    nickname: ?[]const u8 = null,
    language: ?[]const u8 = null,
    city: ?[]const u8 = null,
    province: ?[]const u8 = null,
    country: ?[]const u8 = null,
    headimgurl: ?[]const u8 = null,
    /// 0/1 是否订阅
    subscribe: u1 = 0,
    subscribe_time: i64 = 0,
    unionid: ?[]const u8 = null,

    /// 释放本结构持有的全部 gpa 字符串。
    pub fn deinit(self: *User) void {
        const g = self.gpa;
        g.free(@constCast(self.openid));
        for ([_]?[]const u8{
            self.nickname, self.language,   self.city,    self.province,
            self.country,  self.headimgurl, self.unionid,
        }) |s| if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !User {
        return .{
            .gpa = gpa,
            // openid 恒为 gpa 拥有:缺失时 dupe 空串,保证 deinit 的 free 合法。
            .openid = (try dupeStr(gpa, v, "openid")) orelse try gpa.dupe(u8, ""),
            .nickname = try dupeStr(gpa, v, "nickname"),
            .language = try dupeStr(gpa, v, "language"),
            .city = try dupeStr(gpa, v, "city"),
            .province = try dupeStr(gpa, v, "province"),
            .country = try dupeStr(gpa, v, "country"),
            .headimgurl = try dupeStr(gpa, v, "headimgurl"),
            .subscribe = if ((json_util.getInt(v, "subscribe") orelse 0) != 0) @as(u1, 1) else @as(u1, 0),
            .subscribe_time = json_util.getInt(v, "subscribe_time") orelse 0,
            .unionid = try dupeStr(gpa, v, "unionid"),
        };
    }
};

const jw = struct {
    fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
        try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = false }, w);
    }
};

/// 关注者列表 —— GET cgi-bin/user/get 响应,对应 Java `bean.result.WxMpUserList`
/// {total,count,data:{openid:[...]},next_openid}。openid 切片与 next_openid 全部 gpa 拥有;
/// deinit 逐元素 free + free 切片本身 + free next_openid。
pub const Followers = struct {
    gpa: std.mem.Allocator,
    total: i64 = 0,
    count: i64 = 0,
    openids: [][]u8 = &.{},
    next_openid: []const u8 = "",

    pub fn deinit(self: *Followers) void {
        const g = self.gpa;
        for (self.openids) |o| g.free(o);
        if (self.openids.len > 0) g.free(self.openids);
        g.free(@constCast(self.next_openid));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !Followers {
        var r = Followers{ .gpa = gpa };
        errdefer r.deinit();
        r.total = json_util.getIntOr(v, "total", 0);
        r.count = json_util.getIntOr(v, "count", 0);
        r.next_openid = try gpa.dupe(u8, json_util.getStrOr(v, "next_openid", ""));

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |o| gpa.free(o);
            list.deinit(gpa);
        }
        if (json_util.objectOf(v, "data")) |d| {
            if (d.get("openid")) |oi| {
                if (oi == .array) for (oi.array.items) |s| {
                    if (s == .string) try list.append(gpa, try gpa.dupe(u8, s.string));
                };
            }
        }
        r.openids = try list.toOwnedSlice(gpa);
        return r;
    }
};

/// batchget 的 `user_list` 项(对应 Java `WxMpUserQuery.WxMpUserQueryParam`):
/// {openid, lang?};lang 省略时微信按 zh_CN 处理。
pub const UserListEntry = struct {
    openid: []const u8,
    lang: ?[]const u8 = null,
};

/// 批量用户信息结果 —— 复用 `User` 类型;逐元素 `User.deinit()` + free 切片本身。
pub const UserInfoBatchResult = struct {
    gpa: std.mem.Allocator,
    users: []User = &.{},

    pub fn deinit(self: *UserInfoBatchResult) void {
        for (self.users) |*u| {
            var tmp = u.*;
            tmp.deinit();
        }
        if (self.users.len != 0) self.gpa.free(self.users);
        self.* = undefined;
    }
};

/// openid 转换结果项 —— 对应 Java `bean.result.WxMpChangeOpenid`
/// (字段 `ori_openid`/`new_openid`/`err_msg`,见 `WxMpChangeOpenidGsonAdapter`)。
pub const ChangeOpenid = struct {
    gpa: std.mem.Allocator,
    ori_openid: ?[]const u8 = null,
    new_openid: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *ChangeOpenid) void {
        const g = self.gpa;
        for ([_]?[]const u8{ self.ori_openid, self.new_openid, self.err_msg }) |s|
            if (s) |v| g.free(@constCast(v));
        self.* = undefined;
    }

    fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !ChangeOpenid {
        return .{
            .gpa = gpa,
            .ori_openid = try dupeStr(gpa, v, "ori_openid"),
            .new_openid = try dupeStr(gpa, v, "new_openid"),
            .err_msg = try dupeStr(gpa, v, "err_msg"),
        };
    }
};

/// `changeOpenid` 结果 —— `result_list` 数组,逐元素 deinit + free 切片本身。
pub const ChangeOpenidResult = struct {
    gpa: std.mem.Allocator,
    items: []ChangeOpenid = &.{},

    pub fn deinit(self: *ChangeOpenidResult) void {
        for (self.items) |*c| {
            var tmp = c.*;
            tmp.deinit();
        }
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// 请求体组包(纯逻辑,离线可测)
// ---------------------------------------------------------------------------

/// `{"user_list":[{openid,lang?},...]}` —— 对应 `WxMpUserQuery.toJsonString()`。
fn batchGetBody(gpa: std.mem.Allocator, user_list: []const UserListEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"user_list\":[");
    for (user_list, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"openid\":");
        try jw.str(w, e.openid);
        if (e.lang) |l| {
            try w.writeAll(",\"lang\":");
            try jw.str(w, l);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

/// `{"from_appid":"..","openid_list":["..",...]}` —— 对应 Java `map.put` 两键的 Gson 序列化。
fn changeOpenidBody(gpa: std.mem.Allocator, from_appid: []const u8, openid_list: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"from_appid\":");
    try jw.str(w, from_appid);
    try w.writeAll(",\"openid_list\":[");
    for (openid_list, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try jw.str(w, o);
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// userListAll 的 Paginator 夹具
// (ctx: *anyopaque + vtable;StringCursor = []const u8,空串=首页/终止)
// ---------------------------------------------------------------------------

/// 累加器:openids 逐页 dupe 进 ArrayList,count 求和,total 只取首页(Java 语义)。
const UserListAcc = struct {
    gpa: std.mem.Allocator,
    openids: std.ArrayList([]u8) = .empty,
    count: i64 = 0,
    total: i64 = 0,
    total_set: bool = false,

    fn deinit(self: *UserListAcc) void {
        for (self.openids.items) |o| self.gpa.free(o);
        self.openids.deinit(self.gpa);
        self.* = undefined;
    }
};

/// 单页借用视图:切片指向 ctx.current(一个 gpa 拥有的 Followers),由 ctx 持有/释放。
const UserListPage = struct {
    total: i64,
    count: i64,
    next_openid: []const u8,
    openids: [][]u8,
};

/// 翻页上下文:持有当前页(最近一次 fetch 的结果)、捕获的 WxError。
/// 借用纪律(重要):`next_cursor` 返回 page.next_openid(借用当前页内存)。下一次 `fetch` 会
/// 先用该 cursor 拼 URL(copy 进 URL),**之后**才释放上一页 —— 故 cursor 在使用期间始终有效;
/// `next_cursor` 忽略传入的旧 cursor(该旧值可能已悬垂,绝不解引用)。末页由 ctx.deinit 释放。
const ListAllCtx = struct {
    svc: *UserService,
    io: std.Io,
    current: ?Followers = null,
    wx_err: ?WxError = null,

    fn deinit(self: *ListAllCtx) void {
        if (self.current) |f| {
            var t = f;
            t.deinit();
            self.current = null;
        }
        if (self.wx_err) |e| {
            var t = e;
            t.deinit();
            self.wx_err = null;
        }
    }

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, cursor: mp_helpers.StringCursor) anyerror!UserListPage {
        _ = gpa;
        const self: *ListAllCtx = @ptrCast(@alignCast(ctx));
        const old = self.current;
        self.current = null;
        // cursor 可能借用 old;userList 内部把它 copy 进 URL,返回后不再引用 cursor。
        const r = self.svc.userList(self.io, cursor);
        // 此时才释放上一页,避免 use-after-free。
        if (old) |f| {
            var t = f;
            t.deinit();
        }
        switch (r) {
            .err => |e| {
                self.wx_err = e;
                return error.UserListPageFailed;
            },
            .ok => |f| self.current = f,
        }
        const p = &self.current.?;
        return .{
            .total = p.total,
            .count = p.count,
            .next_openid = p.next_openid,
            .openids = p.openids,
        };
    }

    fn merge(ctx: *anyopaque, gpa: std.mem.Allocator, acc: *UserListAcc, page: UserListPage) anyerror!void {
        _ = ctx;
        for (page.openids) |o| {
            const dup = try gpa.dupe(u8, o);
            acc.openids.append(gpa, dup) catch {
                gpa.free(dup);
                return error.OutOfMemory;
            };
        }
        acc.count += page.count;
        if (!acc.total_set) {
            acc.total = page.total;
            acc.total_set = true;
        }
    }

    fn nextCursor(ctx: *anyopaque, page: UserListPage, cursor: mp_helpers.StringCursor) ?mp_helpers.StringCursor {
        _ = ctx;
        _ = cursor; // 旧 cursor 可能悬垂,不读取(Java while 只看 next_openid)
        if (page.next_openid.len == 0) return null;
        return page.next_openid;
    }
};

const list_all_vtable = mp_helpers.Paginator(UserListAcc, UserListPage, mp_helpers.StringCursor).VTable{
    .fetch = ListAllCtx.fetch,
    .merge = ListAllCtx.merge,
    .next_cursor = ListAllCtx.nextCursor,
};

// ---------------------------------------------------------------------------
// UserService —— 对应 Java `WxMpUserService`(8 方法) + `WxMpUserServiceImpl`
// ---------------------------------------------------------------------------

pub const UserService = struct {
    svc: *service_mod.Service,

    /// `WxMpUserService.userUpdateRemark(openid, remark)` (接口 :29 / impl :31-36)。
    /// POST cgi-bin/user/info/updateremark,body `{"openid","remark"}`(Java JsonObject 两属性)。
    /// 返回 Done:成功即完成。
    pub fn userUpdateRemark(self: *UserService, io: std.Io, openid: []const u8, remark: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("openid", openid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        ob.putStr("remark", remark) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return postVoid(self, io, api_url.User.user_info_update_remark_url, body);
    }

    /// `WxMpUserService.userInfo(openid)` (:43) / `userInfo(openid, lang)` (:58) —— 合并为可选 lang。
    /// impl :44-48:`lang = lang==null ? "zh_CN" : lang`;GET cgi-bin/user/info,query
    /// `openid=..&lang=..`(Java 总是发 lang;本轮镜像该行为);解析 `WxMpUser.fromJson` → User。
    pub fn userInfo(self: *UserService, io: std.Io, openid: []const u8, lang: ?[]const u8) WxResult(User) {
        const gpa = self.svc.gpa;
        const effective_lang = lang orelse "zh_CN";
        const q = [_]mp_helpers.Query{
            .{ .key = "openid", .value = openid },
            .{ .key = "lang", .value = effective_lang },
        };
        const uri = mp_helpers.buildUrl(gpa, api(api_url.User.user_info_url), &q, null) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "user info not json", .{}),
        };
        defer parsed.deinit();
        const user = User.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.transport(gpa, "user info parse failed", .{}),
        };
        return .{ .ok = user };
    }

    /// `WxMpUserService.userInfoList(List<String> openidList)` (接口 :73 / impl :86-89)。
    /// Java `new WxMpUserQuery(openidList)` —— 每项 `lang` 默认 "zh_CN";再委托 query 重载。
    /// POST cgi-bin/user/info/batchget,body `{"user_list":[{openid,lang:"zh_CN"},...]}`。
    pub fn userInfoList(self: *UserService, io: std.Io, openid_list: []const []const u8) WxResult(UserInfoBatchResult) {
        const gpa = self.svc.gpa;
        var query: std.ArrayList(UserListEntry) = .empty;
        defer query.deinit(gpa);
        for (openid_list) |oid| {
            query.append(gpa, .{ .openid = oid, .lang = "zh_CN" }) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return self.userInfoListByQuery(io, query.items);
    }

    /// `WxMpUserService.userInfoList(WxMpUserQuery userQuery)` (接口 :88 / impl :92-95)。
    /// POST cgi-bin/user/info/batchget,body = `query.toJsonString()`(本轮以 `[]UserListEntry`
    /// 表达 query);解析 `user_info_list` → `[]User`(Java `WxMpUser.fromJsonList`)。
    /// 所有权:`UserInfoBatchResult` 逐元素 User.deinit + free 切片。
    pub fn userInfoListByQuery(self: *UserService, io: std.Io, query: []const UserListEntry) WxResult(UserInfoBatchResult) {
        const gpa = self.svc.gpa;
        const body = batchGetBody(gpa, query) catch |e| return .{
            .err = WxError.internal(gpa, "build batchget body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.User.user_info_batch_get_url), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "user/info/batchget not json", .{}),
        };
        defer parsed.deinit();

        var res = UserInfoBatchResult{ .gpa = gpa };
        errdefer res.deinit();
        var list: std.ArrayList(User) = .empty;
        errdefer {
            for (list.items) |*u| {
                var tmp = u.*;
                tmp.deinit();
            }
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "user_info_list")) |arr| {
            for (arr.items) |item| {
                const u = User.fromJson(gpa, item) catch return .{
                    .err = WxError.transport(gpa, "batchget user parse failed", .{}),
                };
                list.append(gpa, u) catch return .{
                    .err = WxError.internal(gpa, "oom", .{}),
                };
            }
        }
        res.users = list.toOwnedSlice(gpa) catch return .{
            .err = WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = res };
    }

    /// `WxMpUserService.userList(nextOpenid)` (接口 :105 / impl :51-54)。
    /// GET cgi-bin/user/get,query `next_openid=..`(空串=不带参数取首页,
    /// 对齐 Java `nextOpenid==null ? null : ...`);解析 `WxMpUserList.fromJson` → Followers。
    pub fn userList(self: *UserService, io: std.Io, next_openid: []const u8) WxResult(Followers) {
        const gpa = self.svc.gpa;
        const one = [_]mp_helpers.Query{.{ .key = "next_openid", .value = next_openid }};
        const query: []const mp_helpers.Query = if (next_openid.len == 0) &.{} else &one;
        const uri = mp_helpers.buildUrl(gpa, api(api_url.User.user_get_url), query, null) catch |e|
            return .{ .err = WxError.internal(gpa, "build url: {s}", .{@errorName(e)}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.get(io, uri, &.{})) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "user/get not json", .{}),
        };
        defer parsed.deinit();
        const r = Followers.fromJson(gpa, parsed.value) catch return .{
            .err = WxError.transport(gpa, "user/get parse failed", .{}),
        };
        return .{ .ok = r };
    }

    /// `WxMpUserService.userList()` (接口 :120 / impl :57-73) —— **无参全量翻页**。
    /// Java while 循环:取首页并入 openids/count/total;`while(nextOpenid 非空)` 逐页
    /// `userList(nextOpenid)` 追加 openids、累加 count、更新游标,直到 next_openid 为空。
    /// total 只取首页、next_openid 留空(Java 循环内不更新二者)。
    /// 本轮用 `mp_helpers.Paginator`(StringCursor 空串=首页/终止哨兵)复刻该循环。
    pub fn userListAll(self: *UserService, io: std.Io) WxResult(Followers) {
        const gpa = self.svc.gpa;
        var ctx = ListAllCtx{ .svc = self, .io = io };
        defer ctx.deinit();
        var acc = UserListAcc{ .gpa = gpa };
        defer acc.deinit();
        var p = mp_helpers.Paginator(UserListAcc, UserListPage, mp_helpers.StringCursor){
            .ctx = &ctx,
            .vtable = &list_all_vtable,
        };
        p.run(gpa, &acc, "") catch |e| {
            if (ctx.wx_err) |we| {
                const err = we;
                ctx.wx_err = null; // 转移所有权,避免 ctx.deinit 二次释放
                return .{ .err = err };
            }
            return .{ .err = WxError.internal(gpa, "userListAll: {s}", .{@errorName(e)}) };
        };

        // 累加器 → Followers:openids 转移所有权(toOwnedSlice 后 acc.openids 为空,deinit 安全)。
        const merged = acc.openids.toOwnedSlice(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        errdefer {
            for (merged) |o| gpa.free(o);
            if (merged.len > 0) gpa.free(merged);
        }
        const next_dup = gpa.dupe(u8, "") catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = .{
            .gpa = gpa,
            .total = acc.total,
            .count = acc.count,
            .openids = merged,
            .next_openid = next_dup,
        } };
    }

    /// `WxMpUserService.changeOpenid(fromAppid, openidList)` (接口 :136 / impl :76-83)。
    /// POST cgi-bin/changeopenid,body `{"from_appid","openid_list"}`(Java HashMap 两键);
    /// 解析 `result_list`(Java `WxMpChangeOpenid.fromJsonList`)→ `[]ChangeOpenid`。
    pub fn changeOpenid(self: *UserService, io: std.Io, from_appid: []const u8, openid_list: []const []const u8) WxResult(ChangeOpenidResult) {
        const gpa = self.svc.gpa;
        const body = changeOpenidBody(gpa, from_appid, openid_list) catch |e| return .{
            .err = WxError.internal(gpa, "build changeopenid body: {s}", .{@errorName(e)}),
        };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, api(api_url.User.user_change_openid_url), &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = WxError.transport(gpa, "changeopenid not json", .{}),
        };
        defer parsed.deinit();

        var res = ChangeOpenidResult{ .gpa = gpa };
        errdefer res.deinit();
        var list: std.ArrayList(ChangeOpenid) = .empty;
        errdefer {
            for (list.items) |*c| {
                var tmp = c.*;
                tmp.deinit();
            }
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "result_list")) |arr| {
            for (arr.items) |item| {
                const c = ChangeOpenid.fromJson(gpa, item) catch return .{
                    .err = WxError.transport(gpa, "changeopenid item parse failed", .{}),
                };
                list.append(gpa, c) catch return .{
                    .err = WxError.internal(gpa, "oom", .{}),
                };
            }
        }
        res.items = list.toOwnedSlice(gpa) catch return .{
            .err = WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = res };
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试(URL / method / 请求体 / 响应字段 / 所有权)
// ---------------------------------------------------------------------------

/// 记录型 executor:捕获 method/uri/body,按 uri 子串返回预置响应(取第一个命中)。
const URecorder = struct {
    const Entry = struct { match: []const u8, response: []const u8 };
    entries: []const Entry,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    last_method: []const u8 = "",
    last_uri: [1024]u8 = undefined,
    last_uri_len: usize = 0,
    last_body: [4096]u8 = undefined,
    last_body_len: usize = 0,

    fn uri(self: *const URecorder) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn body(self: *const URecorder) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
    fn executor(self: *URecorder) u_http.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
    fn executeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: u_http.RequestExecutor.Method, target: []const u8, payload: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *URecorder = @ptrCast(@alignCast(ctx));
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
                    .err = WxError.transport(gpa, "oom", .{}),
                } };
            }
        }
        return .{ .err = WxError.transport(gpa, "mock miss: {s}", .{target}) };
    }
    const vtable = u_http.RequestExecutor.VTable{ .execute = executeImpl };
};

const UFakeFetch = struct {
    fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) u_token.FetchOutcome {
        _ = c;
        _ = i;
        const tok = g.dupe(u8, "TOK") catch return .{ .err = WxError.transport(g, "oom", .{}) };
        return .{ .ok = .{ .token = tok, .expires_in = 7200 } };
    }
};

/// 通用装配:注入任意 RequestExecutor,token 固定 "TOK"。
fn setupExec(
    gpa: std.mem.Allocator,
    exec: u_http.RequestExecutor,
    threaded: *std.Io.Threaded,
    cfg: *u_config.InMemoryConfigStorage,
    svc: *service_mod.Service,
) !void {
    threaded.* = std.Io.Threaded.init(gpa, .{});
    errdefer threaded.deinit();
    cfg.* = try u_config.InMemoryConfigStorage.init(
        gpa,
        .{ .ptr = undefined, .vtable = &.{ .fetch = UFakeFetch.f } },
        .{ .appid = "A", .secret = "S" },
    );
    errdefer cfg.deinit();
    svc.* = service_mod.Service.init(gpa, cfg.config(), exec);
}

test "userInfo: 默认 lang=zh_CN 常发 + GET 解析 User + 所有权" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/info", .response = "{\"openid\":\"oABC\",\"nickname\":\"nick\",\"subscribe\":1,\"subscribe_time\":1700000000}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };
    const io = threaded.io();

    switch (svc.userInfo(io, "oABC", null)) {
        .ok => |*u| {
            var user = u.*;
            defer user.deinit();
            try testing.expectEqualStrings("oABC", user.openid);
            try testing.expectEqualStrings("nick", user.nickname.?);
            try testing.expectEqual(@as(u1, 1), user.subscribe);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/info") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "openid=oABC") != null);
    // Java 镜像点:lang 缺省(null)时仍发 &lang=zh_CN
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "lang=zh_CN") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

    // 显式 lang 覆盖默认值
    switch (svc.userInfo(io, "oABC", "en")) {
        .ok => |*u| {
            var user = u.*;
            defer user.deinit();
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "lang=en") != null);
}

test "userList: 单页 GET/URL/所有权 + errcode 折叠为 .err" {
    const gpa = testing.allocator;
    {
        var mock = URecorder{ .gpa = gpa, .entries = &.{
            .{ .match = "cgi-bin/user/get", .response = "{\"total\":3,\"count\":2,\"data\":{\"openid\":[\"o1\",\"o2\"]},\"next_openid\":\"o2\"}" },
        } };
        var threaded: std.Io.Threaded = undefined;
        var cfg: u_config.InMemoryConfigStorage = undefined;
        var base: service_mod.Service = undefined;
        try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
        defer threaded.deinit();
        defer cfg.deinit();
        var svc = UserService{ .svc = &base };
        const io = threaded.io();

        switch (svc.userList(io, "NEXT1")) {
            .ok => |*r| {
                var f = r.*;
                defer f.deinit();
                try testing.expectEqual(@as(i64, 3), f.total);
                try testing.expectEqual(@as(i64, 2), f.count);
                try testing.expectEqual(@as(usize, 2), f.openids.len);
                try testing.expectEqualStrings("o1", f.openids[0]);
                try testing.expectEqualStrings("o2", f.openids[1]);
                try testing.expectEqualStrings("o2", f.next_openid);
            },
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try testing.expectEqualStrings("get", mock.last_method);
        try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/get") != null);
        try testing.expect(std.mem.indexOf(u8, mock.uri(), "next_openid=NEXT1") != null);
        try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);

        // 空 next_openid 取首页:URL 不带 next_openid 参数(对齐 Java null)
        switch (svc.userList(io, "")) {
            .ok => |*r| {
                var f = r.*;
                defer f.deinit();
                try testing.expectEqual(@as(usize, 2), f.openids.len);
            },
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                return error.Unexpected;
            },
        }
        try testing.expect(std.mem.indexOf(u8, mock.uri(), "next_openid=") == null);
    }
    {
        var mock = URecorder{ .gpa = gpa, .entries = &.{
            .{ .match = "cgi-bin/user/get", .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" },
        } };
        var threaded: std.Io.Threaded = undefined;
        var cfg: u_config.InMemoryConfigStorage = undefined;
        var base: service_mod.Service = undefined;
        try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
        defer threaded.deinit();
        defer cfg.deinit();
        var svc = UserService{ .svc = &base };
        switch (svc.userList(threaded.io(), "")) {
            .ok => return error.Unexpected,
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                try testing.expectEqual(@as(i64, 40003), err.error_code);
            },
        }
    }
}

test "userInfoListByQuery: user_list 请求体 + 复用 User 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/info/batchget", .response = "{\"user_info_list\":[{\"openid\":\"o1\",\"nickname\":\"甲\",\"subscribe\":1,\"subscribe_time\":1700000000},{\"openid\":\"o2\",\"nickname\":\"乙\",\"subscribe\":0}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };
    const io = threaded.io();

    switch (svc.userInfoListByQuery(io, &.{
        .{ .openid = "o1", .lang = "zh_CN" },
        .{ .openid = "o2" },
    })) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit(); // 逐元素 User.deinit + free 切片(testing.allocator 校验无泄漏)
            try testing.expectEqual(@as(usize, 2), res.users.len);
            try testing.expectEqualStrings("o1", res.users[0].openid);
            try testing.expectEqualStrings("甲", res.users[0].nickname.?);
            try testing.expectEqual(@as(u1, 1), res.users[0].subscribe);
            try testing.expectEqualStrings("o2", res.users[1].openid);
            try testing.expectEqual(@as(u1, 0), res.users[1].subscribe);
            try testing.expect(res.users[1].subscribe_time == 0);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/info/batchget") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"user_list\":[") != null);
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o1\",\"lang\":\"zh_CN\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o2\"}") != null);
}

test "userInfoList(List): 每项 lang 默认 zh_CN(Java WxMpUserQuery(openidList))" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/info/batchget", .response = "{\"user_info_list\":[{\"openid\":\"o1\"},{\"openid\":\"o2\"}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };

    const ids = [_][]const u8{ "o1", "o2" };
    switch (svc.userInfoList(threaded.io(), &ids)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit();
            try testing.expectEqual(@as(usize, 2), res.users.len);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    const b = mock.body();
    // Java: WxMpUserQuery(List) 每个 param 的 lang 默认 "zh_CN"
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o1\",\"lang\":\"zh_CN\"}") != null);
    try testing.expect(std.mem.indexOf(u8, b, "{\"openid\":\"o2\",\"lang\":\"zh_CN\"}") != null);
}

test "userUpdateRemark: POST updateremark + {\"openid\",\"remark\"} 请求体" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/user/info/updateremark", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };

    switch (svc.userUpdateRemark(threaded.io(), "oX", "备注")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/user/info/updateremark") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"openid\":\"oX\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"remark\":\"备注\"") != null);
}

test "changeOpenid: POST {\"from_appid\",\"openid_list\"} + result_list 解析 + 所有权" {
    const gpa = testing.allocator;
    var mock = URecorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/changeopenid", .response = "{\"errcode\":0,\"result_list\":[{\"ori_openid\":\"oOLD\",\"new_openid\":\"oNEW\",\"err_msg\":\"ok\"},{\"ori_openid\":\"oBAD\",\"err_msg\":\"not follow\"}]}" },
    } };
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, mock.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };

    const ids = [_][]const u8{ "oOLD", "oBAD" };
    switch (svc.changeOpenid(threaded.io(), "wxFROM", &ids)) {
        .ok => |*r| {
            var res = r.*;
            defer res.deinit(); // 逐元素 ChangeOpenid.deinit + free 切片(无泄漏)
            try testing.expectEqual(@as(usize, 2), res.items.len);
            try testing.expectEqualStrings("oOLD", res.items[0].ori_openid.?);
            try testing.expectEqualStrings("oNEW", res.items[0].new_openid.?);
            try testing.expectEqualStrings("ok", res.items[0].err_msg.?);
            try testing.expectEqualStrings("oBAD", res.items[1].ori_openid.?);
            try testing.expect(res.items[1].new_openid == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/changeopenid") != null);
    const b = mock.body();
    try testing.expect(std.mem.indexOf(u8, b, "\"from_appid\":\"wxFROM\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"openid_list\":[\"oOLD\",\"oBAD\"]") != null);
}

test "userListAll: Paginator 跨 ≥2 页累加(openids/count/total),StubExecutor 顺序路由" {
    const gpa = testing.allocator;
    // 首个命中优先:带 next_openid=NEXT 的第 2 次请求必须排在泛型 cgi-bin/user/get 之前。
    var stub = u_http.StubExecutor.init(gpa, &.{
        .{ .match = "next_openid=NEXT", .response = "{\"total\":3,\"count\":1,\"data\":{\"openid\":[\"o3\"]},\"next_openid\":\"\"}" },
        .{ .match = "cgi-bin/user/get", .response = "{\"total\":3,\"count\":2,\"data\":{\"openid\":[\"o1\",\"o2\"]},\"next_openid\":\"NEXT\"}" },
    });
    var threaded: std.Io.Threaded = undefined;
    var cfg: u_config.InMemoryConfigStorage = undefined;
    var base: service_mod.Service = undefined;
    try setupExec(gpa, stub.executor(), &threaded, &cfg, &base);
    defer threaded.deinit();
    defer cfg.deinit();
    var svc = UserService{ .svc = &base };

    switch (svc.userListAll(threaded.io())) {
        .ok => |*r| {
            var f = r.*;
            defer f.deinit();
            try testing.expectEqual(@as(usize, 3), f.openids.len);
            try testing.expectEqualStrings("o1", f.openids[0]);
            try testing.expectEqualStrings("o2", f.openids[1]);
            try testing.expectEqualStrings("o3", f.openids[2]);
            try testing.expectEqual(@as(i64, 3), f.count); // 2 + 1 累加
            try testing.expectEqual(@as(i64, 3), f.total); // 仅取首页(Java 语义)
            try testing.expectEqualStrings("", f.next_openid); // Java 不在 merge 上设置
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqual(@as(usize, 2), stub.calls); // 恰好两页,无第 3 次 fetch
}
