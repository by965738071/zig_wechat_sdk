//! 第三方平台业务门面 —— 对应 Java `api.WxOpenComponentService` +
//! `impl.WxOpenComponentServiceImpl` 的核心子集:
//! - `getComponentAccessToken`(缓存/锁协议复用 common/token,刷新源在 http.zig);
//! - `createPreAuthCode` + 授权页 URL 构建(Java `createPreAuthUrl`);
//! - `getQueryAuth`(换授权信息并写入按 authorizer_appid 分桶的缓存);
//! - 授权方 token 主动刷新(`api_authorizer_token`,refresh_token 轮换);
//! - `getAuthorizerList`(刷新令牌回写,对应 Java `updateAuthorizerRefreshToken` 循环);
//! - `route`(事件分派,对应 Java `route(WxOpenXmlMessage)`)。
//!
//! 与 Java 一致:所有平台侧出站 POST 先取 component_access_token 并拼进查询参数
//! (`post(uri, postData)` → `uri + "?component_access_token=" + token`)。
//!
//! 所有权:方法返回的结构体/字符串均由 gpa 拥有,调用方负责 `deinit`/`free`;
//! `getComponentAccessToken`/`refreshAuthorizerToken` 的返回借用调用方传入的 buf
//! (对齐 common/token.acquire 的拷贝出参约定)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_http = @import("wechat_mp").http;
const open_config = @import("config.zig");
pub const message = @import("message.zig");

pub const WxResult = result_mod.WxResult;
pub const WxError = error_mod.WxError;

// URL 常量 —— 对应 `WxOpenComponentService` 接口常量(已对照 Java 源码头文件核对;
// component/authorizer token 两条通道在 http.zig,本文件不重复)。
pub const api_create_preauthcode_url = "https://api.weixin.qq.com/cgi-bin/component/api_create_preauthcode";
pub const api_query_auth_url = "https://api.weixin.qq.com/cgi-bin/component/api_query_auth";
/// 对应 Java `API_GET_AUTHORIZER_LIST`(注:微信官方即此拼写,带 get)。
pub const api_get_authorizer_list_url = "https://api.weixin.qq.com/cgi-bin/component/api_get_authorizer_list";
const component_login_page_url = "https://mp.weixin.qq.com/cgi-bin/componentloginpage";

// ---------------------------------------------------------------------------
// 结果结构体
// ---------------------------------------------------------------------------

/// 对应预授权码响应(Java 在 `createPreAuthUrl` 内联解析 `pre_auth_code`)。
pub const PreAuthCode = struct {
    gpa: std.mem.Allocator,
    pre_auth_code: []u8,
    expire_in_seconds: i64,

    pub fn deinit(self: *PreAuthCode) void {
        self.gpa.free(self.pre_auth_code);
        self.* = undefined;
    }
};

/// 对应 `bean.query_auth.WxOpenAuthorizationInfo`(func_info 展平成 id 数组,
/// 只保留 `funcscope_category.id`,对应 Java 的嵌套结构)。
pub const AuthorizationInfo = struct {
    gpa: std.mem.Allocator,
    authorizer_appid: []u8 = "",
    authorizer_access_token: []u8 = "",
    authorizer_refresh_token: []u8 = "",
    expires_in: i64 = 7200,
    /// 授权功能类目 id 列表(对应 func_info[].funcscope_category.id)。
    func_ids: []i64 = &.{},

    pub fn deinit(self: *AuthorizationInfo) void {
        const g = self.gpa;
        if (self.authorizer_appid.len > 0) g.free(self.authorizer_appid);
        if (self.authorizer_access_token.len > 0) g.free(self.authorizer_access_token);
        if (self.authorizer_refresh_token.len > 0) g.free(self.authorizer_refresh_token);
        if (self.func_ids.len > 0) g.free(self.func_ids);
        self.* = undefined;
    }
};

/// `getAuthorizerList` 单条(对应 Java `WxOpenAuthorizerListResult.list` 的 Map)。
pub const AuthorizerListItem = struct {
    authorizer_appid: []u8,
    refresh_token: []u8,
};

/// 对应 `bean.result.WxOpenAuthorizerListResult`。
pub const AuthorizerListResult = struct {
    gpa: std.mem.Allocator,
    total_count: i64 = 0,
    list: []AuthorizerListItem = &.{},

    pub fn deinit(self: *AuthorizerListResult) void {
        const g = self.gpa;
        for (self.list) |it| {
            g.free(it.authorizer_appid);
            g.free(it.refresh_token);
        }
        if (self.list.len > 0) g.free(self.list);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// 纯函数:URL 构建
// ---------------------------------------------------------------------------

/// JS `encodeURIComponent` / Java `URIUtil.encodeURIComponent` 等价:
/// 不转义 `A-Za-z0-9-_.!~*'()`,其余字节按 UTF-8 百分号编码(大写十六进制)。
pub fn encodeURIComponent(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => try out.append(gpa, c),
        else => {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xF]);
        },
    };
    return out.toOwnedSlice(gpa);
}

/// 纯函数:扫码授权页 URL —— 对应 `COMPONENT_LOGIN_PAGE_URL` +
/// `createPreAuthUrl` 里 `auth_type=xxx` 的替换(任务口径固定 auth_type=3,即公众号+小程序)。
/// 结果由 gpa 拥有,调用方释放。
pub fn buildPreAuthUrl(
    gpa: std.mem.Allocator,
    component_appid: []const u8,
    pre_auth_code: []const u8,
    redirect_uri: []const u8,
) ![]u8 {
    const enc = try encodeURIComponent(gpa, redirect_uri);
    defer gpa.free(enc);
    return std.fmt.allocPrint(
        gpa,
        "{s}?component_appid={s}&pre_auth_code={s}&redirect_uri={s}&auth_type=3",
        .{ component_login_page_url, component_appid, pre_auth_code, enc },
    );
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

pub const WxOpenComponentService = struct {
    gpa: std.mem.Allocator,
    cfg: open_config.OpenConfigStorage,
    exec: mp_http.RequestExecutor,

    pub fn init(gpa: std.mem.Allocator, cfg: open_config.OpenConfigStorage, exec: mp_http.RequestExecutor) WxOpenComponentService {
        return .{ .gpa = gpa, .cfg = cfg, .exec = exec };
    }

    /// 对应 `getComponentAccessToken(forceRefresh)`。
    /// 缓存/双重检查协议在 common/token;POST api_component_token
    /// {component_appid, component_appsecret, component_verify_ticket}
    /// 的刷新源是 `http.ComponentTokenSource`。结果拷贝进调用方 buf。
    pub fn getComponentAccessToken(self: *WxOpenComponentService, io: std.Io, buf: []u8, force: bool) WxResult([]const u8) {
        return self.cfg.acquireComponentAccessToken(io, buf, force);
    }

    /// 对应 `getAuthorizerAccessToken(authorizerAppid, forceRefresh)`。
    pub fn getAuthorizerAccessToken(self: *WxOpenComponentService, io: std.Io, authorizer_appid: []const u8, buf: []u8, force: bool) WxResult([]const u8) {
        return self.cfg.acquireAuthorizerAccessToken(io, authorizer_appid, buf, force);
    }

    /// 收到 component_verify_ticket 事件时写回配置(对应 `setComponentVerifyTicket`)。
    pub fn setComponentVerifyTicket(self: *WxOpenComponentService, ticket: []const u8) bool {
        return self.cfg.setComponentVerifyTicket(ticket);
    }

    // ---- 预授权 ----

    /// 对应 `createPreAuthUrl` 里的 getPreAuthCode 步骤:
    /// POST api_create_preauthcode {component_appid[, expire_time]}。
    pub fn createPreAuthCode(self: *WxOpenComponentService, io: std.Io, expire_time: ?i64) WxResult(PreAuthCode) {
        const gpa = self.gpa;
        var body = json_util.ObjectBuilder.init(gpa);
        defer body.deinit();
        body.putStr("component_appid", self.cfg.componentAppid()) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        if (expire_time) |t| body.putInt("expire_time", t) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const body_str = body.toJson() catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body_str);

        return switch (self.postComponent(io, api_create_preauthcode_url, body_str)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp);
                var parsed = json_util.parse(gpa, resp) catch
                    break :blk .{ .err = WxError.transport(gpa, "pre_auth_code 响应非 JSON", .{}) };
                defer parsed.deinit();
                if (errcodeError(gpa, parsed.value, resp)) |e| break :blk .{ .err = e };
                const code = json_util.getStr(parsed.value, "pre_auth_code") orelse
                    break :blk .{ .err = WxError.transport(gpa, "响应缺少 pre_auth_code", .{}) };
                const owned = gpa.dupe(u8, code) catch break :blk .{ .err = WxError.transport(gpa, "oom", .{}) };
                break :blk .{ .ok = .{
                    .gpa = gpa,
                    .pre_auth_code = owned,
                    .expire_in_seconds = json_util.getInt(parsed.value, "expire_in_seconds") orelse 600,
                } };
            },
        };
    }

    /// 对应 `getPreAuthUrl(redirectUri)`:取预授权码 + 拼授权页 URL。
    /// 结果字符串由 gpa 拥有,调用方释放。
    pub fn getPreAuthUrl(self: *WxOpenComponentService, io: std.Io, redirect_uri: []const u8) WxResult([]u8) {
        const gpa = self.gpa;
        var pa = switch (self.createPreAuthCode(io, null)) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        defer pa.deinit();
        const url = buildPreAuthUrl(gpa, self.cfg.componentAppid(), pa.pre_auth_code, redirect_uri) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = url };
    }

    // ---- 授权 ----

    /// 对应 `getQueryAuth(authorizationCode)`:
    /// POST api_query_auth {component_appid, authorization_code};
    /// 成功后把 authorizer token/refresh_token 写入按 appid 分桶的缓存
    /// (对应 Java `updateAuthorizerAccessToken` + `updateAuthorizerRefreshToken`)。
    pub fn queryAuth(self: *WxOpenComponentService, io: std.Io, authorization_code: []const u8) WxResult(AuthorizationInfo) {
        const gpa = self.gpa;
        var body = json_util.ObjectBuilder.init(gpa);
        defer body.deinit();
        body.putStr("component_appid", self.cfg.componentAppid()) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        body.putStr("authorization_code", authorization_code) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const body_str = body.toJson() catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body_str);

        return switch (self.postComponent(io, api_query_auth_url, body_str)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp);
                var parsed = json_util.parse(gpa, resp) catch
                    break :blk .{ .err = WxError.transport(gpa, "query_auth 响应非 JSON", .{}) };
                defer parsed.deinit();
                if (errcodeError(gpa, parsed.value, resp)) |e| break :blk .{ .err = e };
                const ai = json_util.objectOf(parsed.value, "authorization_info") orelse
                    break :blk .{ .err = WxError.transport(gpa, "响应缺少 authorization_info", .{}) };
                const info = parseAuthorizationInfo(gpa, .{ .object = ai }) catch
                    break :blk .{ .err = WxError.transport(gpa, "authorization_info 解析失败", .{}) };
                // 写入缓存：token/refresh_token 缺失时传 null（与 Java 判空后写入一致）
                const tok: ?[]const u8 = if (info.authorizer_access_token.len > 0) info.authorizer_access_token else null;
                const refreshed = self.cfg.storeAuthorizer(
                    io,
                    info.authorizer_appid,
                    tok,
                    info.expires_in,
                    if (info.authorizer_refresh_token.len > 0) info.authorizer_refresh_token else "",
                );
                if (!refreshed) {
                    // 注意：errdefer 不会在 break 非错误返回时触发，此处必须手动释放
                    var i = info;
                    i.deinit();
                    break :blk .{ .err = WxError.internal(gpa, "授权方 token 缓存写入失败", .{}) };
                }
                break :blk .{ .ok = info };
            },
        };
    }

    /// 主动刷新授权方 access_token(对应 Java `refreshAuthorizerToken` 通道):
    /// POST api_authorizer_token {component_appid, authorizer_appid, authorizer_refresh_token}
    /// (component_access_token 拼在查询参数;实现见 `http.HttpAuthorizerTokenSource`,
    /// refresh_token 轮换后的新值由存储层写回)。结果拷贝进调用方 buf。
    pub fn refreshAuthorizerToken(self: *WxOpenComponentService, io: std.Io, authorizer_appid: []const u8, buf: []u8) WxResult([]const u8) {
        // force=true 跳过缓存,走 AuthCtx fetcher → AuthorizerTokenSource
        return self.cfg.acquireAuthorizerAccessToken(io, authorizer_appid, buf, true);
    }

    /// 对应 `getAuthorizerList(begin, len)`:POST api_get_authorizer_list
    /// {component_appid, offset, count};逐条把 refresh_token 回写存储
    /// (对应 Java `updateAuthorizerRefreshToken` 循环)。
    pub fn getAuthorizerList(self: *WxOpenComponentService, io: std.Io, offset: i64, count: i64) WxResult(AuthorizerListResult) {
        const gpa = self.gpa;
        // Java: begin = max(begin,0); len = len==0 ? 10 : len
        const off = @max(offset, 0);
        const cnt: i64 = if (count == 0) 10 else count;

        var body = json_util.ObjectBuilder.init(gpa);
        defer body.deinit();
        body.putStr("component_appid", self.cfg.componentAppid()) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        body.putInt("offset", off) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        body.putInt("count", cnt) catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        const body_str = body.toJson() catch return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(body_str);

        return switch (self.postComponent(io, api_get_authorizer_list_url, body_str)) {
            .err => |e| .{ .err = e },
            .ok => |resp| blk: {
                defer gpa.free(resp);
                var parsed = json_util.parse(gpa, resp) catch
                    break :blk .{ .err = WxError.transport(gpa, "authorizer_list 响应非 JSON", .{}) };
                defer parsed.deinit();
                if (errcodeError(gpa, parsed.value, resp)) |e| break :blk .{ .err = e };
                const ret = parseAuthorizerList(gpa, parsed.value) catch
                    break :blk .{ .err = WxError.transport(gpa, "authorizer_list 解析失败", .{}) };
                // 回写 refresh_token（存储失败不影响列表返回，与 Java 尽力而为一致）
                for (ret.list) |it| _ = self.cfg.storeAuthorizer(io, it.authorizer_appid, null, 0, it.refresh_token);
                break :blk .{ .ok = ret };
            },
        };
    }

    /// 对应 `route(WxOpenXmlMessage)` 的事件分派:
    /// - component_verify_ticket → 写回配置;
    /// - authorized / update_authorized → 顺手 getQueryAuth 换授权信息(结果仅写缓存);
    /// - unauthorized / unknown → 不处理(Java 返回 "" 的分支)。
    /// 返回是否被处理。
    pub fn route(self: *WxOpenComponentService, io: std.Io, ev: *const message.AuthorizerEvent) WxResult(bool) {
        switch (ev.info_type) {
            .component_verify_ticket => {
                const t = ev.component_verify_ticket orelse return .{ .ok = false };
                return .{ .ok = self.cfg.setComponentVerifyTicket(t) };
            },
            .authorized, .update_authorized => {
                const code = ev.authorization_code orelse return .{ .ok = false };
                return switch (self.queryAuth(io, code)) {
                    .ok => |*info| {
                        var i = info.*;
                        defer i.deinit();
                        return .{ .ok = true };
                    },
                    .err => |e| .{ .err = e },
                };
            },
            .unauthorized, .unknown => return .{ .ok = false },
        }
    }

    // ---- 内部 ----

    /// 对应 Java `post(uri, postData)`:取 component_access_token(缓存)→ 拼查询参数 → POST。
    fn postComponent(self: *WxOpenComponentService, io: std.Io, url: []const u8, body: []const u8) WxResult([]u8) {
        const gpa = self.gpa;
        var tbuf: [256]u8 = undefined;
        const tok = switch (self.cfg.acquireComponentAccessToken(io, &tbuf, false)) {
            .err => |e| return .{ .err = e },
            .ok => |t| t,
        };
        const full = std.fmt.allocPrint(gpa, "{s}?component_access_token={s}", .{ url, tok }) catch
            return .{ .err = WxError.transport(gpa, "oom", .{}) };
        defer gpa.free(full);
        return self.exec.execute(gpa, io, .post, full, body);
    }
};

/// 响应里 errcode != 0 → WxError(对应 Java 在 execute 里抛 WxErrorException)。
fn errcodeError(gpa: std.mem.Allocator, v: json_util.Value, raw: []const u8) ?WxError {
    const code = json_util.getInt(v, "errcode") orelse return null;
    if (code == 0) return null;
    return WxError.fromJson(gpa, raw, .open) catch WxError.internal(gpa, "errcode {d}", .{code});
}

/// 解析 authorization_info(含 func_info[].funcscope_category.id 展平)。
fn parseAuthorizationInfo(gpa: std.mem.Allocator, v: json_util.Value) !AuthorizationInfo {
    var info = AuthorizationInfo{ .gpa = gpa };
    errdefer info.deinit();
    if (json_util.getStr(v, "authorizer_appid")) |s| info.authorizer_appid = try gpa.dupe(u8, s);
    if (json_util.getStr(v, "authorizer_access_token")) |s| info.authorizer_access_token = try gpa.dupe(u8, s);
    if (json_util.getStr(v, "authorizer_refresh_token")) |s| info.authorizer_refresh_token = try gpa.dupe(u8, s);
    info.expires_in = json_util.getInt(v, "expires_in") orelse 7200;

    var ids: std.ArrayList(i64) = .empty;
    errdefer {
        ids.deinit(gpa);
    }
    if (json_util.getArray(v, "func_info")) |arr| {
        for (arr.items) |item| {
            const cat = json_util.objectOf(item, "funcscope_category") orelse continue;
            if (cat.get("id")) |idv| {
                const id: i64 = switch (idv) {
                    .integer => |x| x,
                    .float => |x| @intFromFloat(x),
                    else => continue,
                };
                try ids.append(gpa, id);
            }
        }
    }
    info.func_ids = try ids.toOwnedSlice(gpa);
    return info;
}

/// 解析 api_get_authorizer_list 响应(list 的 Map 子集:authorizer_appid+refresh_token)。
fn parseAuthorizerList(gpa: std.mem.Allocator, v: json_util.Value) !AuthorizerListResult {
    var ret = AuthorizerListResult{ .gpa = gpa };
    errdefer ret.deinit();
    ret.total_count = json_util.getInt(v, "total_count") orelse 0;
    var items: std.ArrayList(AuthorizerListItem) = .empty;
    errdefer {
        for (items.items) |it| {
            gpa.free(it.authorizer_appid);
            gpa.free(it.refresh_token);
        }
        items.deinit(gpa);
    }
    if (json_util.getArray(v, "list")) |arr| {
        for (arr.items) |item| {
            const appid = json_util.getStr(item, "authorizer_appid") orelse continue;
            const refresh = json_util.getStr(item, "refresh_token") orelse "";
            try items.append(gpa, .{
                .authorizer_appid = try gpa.dupe(u8, appid),
                .refresh_token = try gpa.dupe(u8, refresh),
            });
        }
    }
    ret.list = try items.toOwnedSlice(gpa);
    return ret;
}
