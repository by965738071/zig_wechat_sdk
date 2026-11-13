//! 公众号(mp)通用组包/翻页底座 —— 对应 Java `weixin-java-common` + `weixin-java-mp`
//! 中被多个 service 复用的机制,按「公共方法必须抽取到 common/」的要求从
//! `wechat_mp/service.zig`、`wechat_mp/services/{material,media}.zig` 提取并泛化。
//!
//! 依赖方向:本文件只依赖 `std`,不 `@import` 任何 `wechat_mp` 类型
//! (common ← wechat_mp,见 build.zig:4)。可被 mp / open / miniapp 等复用。
//!
//! 内存约定:所有返回 `[]u8` 的函数返回值由传入的 `gpa` 拥有,调用方 `gpa.free()`。
//! 分配失败一律经 `!` 错误并回传,不 panic、不 `catch unreachable`。
//!
//! Java 对照:
//!   - buildUrl / rejectAccessTokenInUri : `BaseWxMpServiceImpl#executeInternal`
//!     (465-473) 的 `?access_token=` 注入与防御;`WxMpApiUrl#getUrl` 的 host+path
//!     拼接由并行 worker 的 `api_url.zig` 负责,本文件只管 query + token 追加。
//!   - multipart* : `MaterialUploadRequestExecutor` / `MaterialUploadApacheHttp...`
//!     的 `media` 字段组包(见 material.zig:322-388 注释)。
//!   - Paginator : `WxMpUserServiceImpl#userList()`(57-73)、
//!     `WxMpKefuServiceImpl#kfMsgList()`(140-156)、
//!     `WxMpStoreServiceImpl#listAll()`(82-100) 的 while 累加翻页循环。
const std = @import("std");
const testing = std.testing;

// ===========================================================================
// (A) URL / QUERY BUILDER
// 镜像 `BaseWxMpServiceImpl#executeInternal()`(465-473):
//   uriWithAccessToken = uri + (uri.contains("?") ? "&" : "?") + "access_token=" + token
// 而 query 参数逐项追加、value 百分号编码,key 原样;首个参数以 `?`/`&` 领起,
// 其余以 `&` 领起。原 `service.zig` 的 `buildUrl` 为私有且已修复 sep bug,
// 这里提取为 pub 并保留其**修正后**语义。
// ===========================================================================

pub const Query = struct { key: []const u8, value: []const u8 };

/// URL 百分号编码(URLEncoder 语义):安全字符集外一律 %XX(大写十六进制),
/// 空格 -> '+',其余(含非 ASCII 的每个字节)-> %XX。
/// 例如 "中"(UTF-8 E4 B8 AD) -> "%E4%B8%AD";'&' -> "%26"。
/// 返回 gpa 拥有的切片,调用方 free。
pub fn urlEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(gpa, c),
            ' ' => try out.append(gpa, '+'),
            else => {
                var esc: [3]u8 = undefined;
                const part = try std.fmt.bufPrint(&esc, "%{X:0>2}", .{c});
                try out.appendSlice(gpa, part);
            },
        }
    }
    return try out.toOwnedSlice(gpa);
}

/// 拼 `base?k1=v1&k2=v2[&access_token=...]`。
///  - 首个参数:base 已含 '?' 则以 '&' 领起,否则以 '?' 领起;
///  - 后续参数与 access_token 一律以 '&' 领起;
///  - 每个 query.value 经 urlEncode;query.key 与 access_token 原样;
///  - access_token 非 null 时**最后**追加(对齐 Java 把 token 追加到 uri 末尾)。
/// 返回 gpa 拥有的切片,调用方 free。
///
/// 注:sep 修正点 —— `sep` 初值根据 base 决定,循环内仅当 `sep == '?'` 才置 '&',
/// 保证「base 已含 ? 时始终用 &」「base 无 ? 时首参 ?、其余 &」,与
/// `service.zig:301-310` 当前(已修复)版本逐字一致。
pub fn buildUrl(gpa: std.mem.Allocator, base: []const u8, query: []const Query, access_token: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    var sep: u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) '&' else '?';
    for (query) |q| {
        const v = try urlEncode(gpa, q.value);
        defer gpa.free(v);
        const part = try std.fmt.allocPrint(gpa, "{c}{s}={s}", .{ sep, q.key, v });
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
        if (sep == '?') {
            sep = '&';
        }
    }
    if (access_token) |t| {
        const part = try std.fmt.allocPrint(gpa, "{c}access_token={s}", .{ sep, t });
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    return try out.toOwnedSlice(gpa);
}

/// `executeInternal` 的防御错误:uri 不允许自带 access_token。
pub const UriError = error{UriContainsAccessToken};

/// 镜像 `BaseWxMpServiceImpl#executeInternal()`(468-470):
///   if (uri.contains("access_token=")) throw new IllegalArgumentException(...)
/// 防止 token 注入 / 泄漏。命中返回 `error.UriContainsAccessToken`,调用方按
/// `service.zig:497-499` 映射为 `WxError.internal`。
///
/// 注:OAuth 类 URL 常把 `access_token=%s` 作为**路径占位符**(如
/// `WxMpApiUrl.OAuth2.USERINFO_URL`),它们由 `api_url.zig` 直接产出、不走
/// `executeInternal`,故本守卫只在 `executeInternal` 入口调用,不并入 buildUrl。
pub fn rejectAccessTokenInUri(uri: []const u8) UriError!void {
    if (std.mem.indexOf(u8, uri, "access_token=") != null) {
        return error.UriContainsAccessToken;
    }
}

// ===========================================================================
// (B) MULTIPART BUILDER
// 逐字提取自 `wechat_mp/services/material.zig:328/348`(并被 media.zig:285/289
// 复用)。纯字节组包:不依赖任何 wechat_mp 类型,输出与旧版字节级兼容,
// 把 material/media 的调用点改指向本文件即可通过既有单测。
// 对应 Java `MaterialUploadRequestExecutor` / `MaterialUploadApache...` 的
// `media` 字段名、`application/octet-stream`、可选 `description` 文本部分。
// ===========================================================================

/// multipart 请求头 Content-Type 值(header-capable 执行器使用)。纯函数。
/// 返回 gpa 拥有的切片,调用方 free。
pub fn multipartContentType(gpa: std.mem.Allocator, boundary: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "multipart/form-data; boundary={s}", .{boundary});
}

/// 禁止 CRLF / 引号,防止头注入(boundary 与 filename 都进头行)。
fn hasHeaderInjection(s: []const u8) bool {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == '"') return true;
    }
    return false;
}

/// 拼 multipart/form-data body(纯逻辑、可离线单测)。字段/格式:
///  - `media` 部分:name="media"; filename="<filename>",
///    Content-Type: application/octet-stream,后接文件二进制(按字节透传);
///  - `description` 部分(视频,可选):name="description",
///    Content-Type: text/plain; charset=UTF-8,内容 = 表单 JSON;
///  - 各部分以 `--<boundary>\r\n` 分隔,末行 `--<boundary>--\r\n`。
/// boundary / filename 含 CRLF 或 '"' 时拒绝(不生成非法头)。
/// 返回 gpa 拥有的切片,调用方 free。
pub fn buildMultipartBody(gpa: std.mem.Allocator, boundary: []const u8, filename: []const u8, content: []const u8, description: ?[]const u8) ![]u8 {
    if (boundary.len == 0 or hasHeaderInjection(boundary)) return error.InvalidBoundary;
    if (hasHeaderInjection(filename)) return error.InvalidFilename;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    // -- media 部分 --
    try out.appendSlice(gpa, "--");
    try out.appendSlice(gpa, boundary);
    try out.appendSlice(gpa, "\r\n");
    try out.appendSlice(gpa, "Content-Disposition: form-data; name=\"media\"; filename=\"");
    try out.appendSlice(gpa, filename);
    try out.appendSlice(gpa, "\"\r\n");
    try out.appendSlice(gpa, "Content-Type: application/octet-stream\r\n\r\n");
    try out.appendSlice(gpa, content);
    try out.appendSlice(gpa, "\r\n");

    // -- description 部分(视频表单,可选)--
    if (description) |d| {
        try out.appendSlice(gpa, "--");
        try out.appendSlice(gpa, boundary);
        try out.appendSlice(gpa, "\r\n");
        try out.appendSlice(gpa, "Content-Disposition: form-data; name=\"description\"\r\n");
        try out.appendSlice(gpa, "Content-Type: text/plain; charset=UTF-8\r\n\r\n");
        try out.appendSlice(gpa, d);
        try out.appendSlice(gpa, "\r\n");
    }

    // -- 结束边界 --
    try out.appendSlice(gpa, "--");
    try out.appendSlice(gpa, boundary);
    try out.appendSlice(gpa, "--\r\n");
    return out.toOwnedSlice(gpa);
}

// ===========================================================================
// (C) PAGINATION HELPER —— Java 三处 `while` 累加循环的泛型抽取
// ---------------------------------------------------------------------------
// Java 逻辑(逐字归纳):
//   WxMpUserServiceImpl#userList() 57-73 : 取首页并入 mergeList;
//       while (StringUtils.isNotEmpty(nextOpenid)) { 取下一页; addAll openids;
//       count += 下一页.count; }  —— 「字符串游标,空串/ null 终止」。
//   WxMpKefuServiceImpl#kfMsgList() 140-156 : 首页满页才进入;
//       while (followingResult != null && !records.isEmpty()) { addAll records;
//       number += ; msgId = ; 取下一页 }  —— 「数值/id 游标,空页终止」。
//   WxMpStoreServiceImpl#listAll() 82-100 : begin=0 取首页;
//       while (!businessList.isEmpty()) { addAll; begin += limit;
//       if (begin >= totalCount) break; 取下一页 }  —— 「offset/limit/total」。
//
// 三者共享同一个骨架:fetch(cursor) -> merge(acc, page) -> 由 page 推导
// next_cursor 或终止 -> 继续。Zig 无带捕获闭包,故仿 `wechat_mp/http.zig:33-51`
// 的 `RequestExecutor` 用 `ctx: *anyopaque` + 函数指针 vtable;终止统一表达为
// 「next_cursor 返回 null」,各 service 的精确 while 守卫(空串/空页/total 上界)
// 全部由 next_cursor 回调决定,helper 不硬编码任何 service 类型。
//
// 所有权契约:Page 是「借用视图」,其内存由 ctx 持有(如静态表或 ctx 内的复用
// 缓冲),循环不持有也不释放 Page;merge 把需要的数据拷进 gpa 拥有的 acc。
// Acc 由调用方创建/释放。这样纯组包 helper 无隐藏分配、无泄漏。
// ===========================================================================

/// 游标形状 #1:`next_openid` 字符串游标(Java WxMpUserServiceImpl#userList)。
/// 空串 "" = 首页 / 无游标哨兵(对齐 Java `StringUtils.isEmpty(nextOpenid)`)。
/// 也可用作 kefu 的 msgId 字符串化游标。
pub const StringCursor = []const u8;

/// 游标形状 #2:`offset/count` 数值游标(Java WxMpStoreServiceImpl#listAll)。
/// begin=Java `begin`(store)/`msgid`(kefu);limit=`limit`/`number`;
/// total=Java `total_count`(到达即停),kefu 无此上界时置 null。
pub const OffsetCursor = struct {
    begin: usize,
    limit: usize,
    total: ?usize = null,
};

/// 泛型翻页器:`Acc`=累加器类型,`Page`=单页类型,`Cursor`=游标类型。
/// 用法:.{ .ctx = &state, .vtable = &vtable }.run(gpa, &acc, initial_cursor)。
pub fn Paginator(comptime Acc: type, comptime Page: type, comptime Cursor: type) type {
    return struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            /// 取一页(Java:userList(next_openid)/kfMsgList(msgid,number)/list(begin,limit))。
            /// 返回借用视图 Page;失败(HTTP/OOM)经 error 并回传。
            fetch: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, cursor: Cursor) anyerror!Page,
            /// 把一页并入累加器(Java:addAll(openids/records);count+=;number+=)。
            merge: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, acc: *Acc, page: Page) anyerror!void,
            /// 由本页 + 当前游标推导下一游标;返回 null 即终止。
            /// 各 service 的 while 守卫在这里表达:
            ///   userList -> next_openid 非空返回该串、否则 null;
            ///   kfMsgList -> 本页 records 非空返回新 msgId 游标、否则 null;
            ///   listAll -> 本页非空且 begin+limit < total 返回新 offset、否则 null。
            next_cursor: *const fn (ctx: *anyopaque, page: Page, cursor: Cursor) ?Cursor,
        };

        /// 累加式翻页循环,镜像上述三个 Java no-arg 重载的 while 模式。
        /// 首页无条件并入(对齐 Java 先取首页再进 while);之后每并入一页,
        /// 由 next_cursor 决定是否继续。返回 !void(分配/传输错误透传)。
        pub fn run(self: Self, gpa: std.mem.Allocator, acc: *Acc, initial_cursor: Cursor) !void {
            var cursor = initial_cursor;
            while (true) {
                const page = try self.vtable.fetch(self.ctx, gpa, cursor);
                try self.vtable.merge(self.ctx, gpa, acc, page);
                cursor = self.vtable.next_cursor(self.ctx, page, cursor) orelse break;
            }
        }
    };
}

// ===========================================================================
// 内联测试(由集成 worker 挂入测试图)
// ===========================================================================

test "urlEncode: ASCII 安全字符 / 空格->+ / 非 ASCII->%XX" {
    const gpa = testing.allocator;
    {
        const e = try urlEncode(gpa, "ABCxyz019-_.~");
        defer gpa.free(e);
        try testing.expectEqualStrings("ABCxyz019-_.~", e);
    }
    {
        const e = try urlEncode(gpa, "a b+c");
        defer gpa.free(e);
        try testing.expectEqualStrings("a+b%2Bc", e); // '+' 非安全字符 -> %2B
    }
    {
        const e = try urlEncode(gpa, "中"); // UTF-8 E4 B8 AD
        defer gpa.free(e);
        try testing.expectEqualStrings("%E4%B8%AD", e);
    }
    {
        const e = try urlEncode(gpa, "");
        defer gpa.free(e);
        try testing.expectEqualStrings("", e);
    }
}

test "buildUrl: 无 query / 带 query / base 已含 ? / access_token 追加 / sep 正确" {
    const gpa = testing.allocator;
    // 无 query、无 token:原样返回
    {
        const u = try buildUrl(gpa, "https://api/x", &.{}, null);
        defer gpa.free(u);
        try testing.expectEqualStrings("https://api/x", u);
    }
    // 带 2 个 query + token:首 ? / 其余 & / value 编码 / token 最后
    {
        const q = [_]Query{
            .{ .key = "k1", .value = "a b" },
            .{ .key = "k2", .value = "v&2" },
        };
        const u = try buildUrl(gpa, "https://api/x", &q, "TOK");
        defer gpa.free(u);
        try testing.expectEqualStrings("https://api/x?k1=a+b&k2=v%262&access_token=TOK", u);
    }
    // base 已含 ?:首个参数用 &
    {
        const q = [_]Query{.{ .key = "a", .value = "1" }};
        const u = try buildUrl(gpa, "https://api/x?foo=bar", &q, null);
        defer gpa.free(u);
        try testing.expectEqualStrings("https://api/x?foo=bar&a=1", u);
    }
    // base 已含 ? + token(无 query):token 用 &
    {
        const u = try buildUrl(gpa, "https://api/x?foo=bar", &.{}, "TOK");
        defer gpa.free(u);
        try testing.expectEqualStrings("https://api/x?foo=bar&access_token=TOK", u);
    }
    // 无 query + token:token 用 ?
    {
        const u = try buildUrl(gpa, "https://api/x", &.{}, "TOK");
        defer gpa.free(u);
        try testing.expectEqualStrings("https://api/x?access_token=TOK", u);
    }
    // sep 正确性:3 个参数时仅首个是 ?,其余全 &
    {
        const q = [_]Query{
            .{ .key = "a", .value = "1" },
            .{ .key = "b", .value = "2" },
            .{ .key = "c", .value = "3" },
        };
        const u = try buildUrl(gpa, "base", &q, null);
        defer gpa.free(u);
        try testing.expectEqualStrings("base?a=1&b=2&c=3", u);
    }
}

test "rejectAccessTokenInUri: 镜像 executeInternal 的 uri 防御" {
    try rejectAccessTokenInUri("https://api/x?foo=1");
    try testing.expectError(error.UriContainsAccessToken, rejectAccessTokenInUri("https://api/x?access_token=abc"));
    try testing.expectError(error.UriContainsAccessToken, rejectAccessTokenInUri("x&access_token=abc"));
}

test "multipart: 字节级形状(media + description) / Content-Type / 头注入拒绝" {
    const gpa = testing.allocator;
    const body = try buildMultipartBody(gpa, "BOUND123", "pic.png", "\x89PNG\r\n", "{\"title\":\"t\"}");
    defer gpa.free(body);
    const expect =
        "--BOUND123\r\n" ++
        "Content-Disposition: form-data; name=\"media\"; filename=\"pic.png\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n" ++ // 原始二进制按字节透传(故意含 \r\n)
        "\r\n" ++
        "--BOUND123\r\n" ++
        "Content-Disposition: form-data; name=\"description\"\r\n" ++
        "Content-Type: text/plain; charset=UTF-8\r\n" ++
        "\r\n" ++
        "{\"title\":\"t\"}" ++
        "\r\n" ++
        "--BOUND123--\r\n";
    try testing.expectEqualStrings(expect, body);

    // 无 description 时不应出现该部分,且以结束边界收尾
    const body2 = try buildMultipartBody(gpa, "B", "f.bin", "XYZ", null);
    defer gpa.free(body2);
    try testing.expect(std.mem.indexOf(u8, body2, "name=\"description\"") == null);
    try testing.expect(std.mem.endsWith(u8, body2, "--B--\r\n"));

    const ct = try multipartContentType(gpa, "BOUND123");
    defer gpa.free(ct);
    try testing.expectEqualStrings("multipart/form-data; boundary=BOUND123", ct);

    // 头注入防护:filename / boundary 含 CRLF 或引号 -> 拒绝
    try testing.expectError(error.InvalidFilename, buildMultipartBody(gpa, "B", "a\r\nb", "x", null));
    try testing.expectError(error.InvalidFilename, buildMultipartBody(gpa, "B", "a\"b", "x", null));
    try testing.expectError(error.InvalidBoundary, buildMultipartBody(gpa, "B\r\nX", "f", "x", null));
    try testing.expectError(error.InvalidBoundary, buildMultipartBody(gpa, "", "f", "x", null));
}

// --- 翻页测试夹具(文件级,供下面 3 个 test 共用;ctx: *anyopaque + vtable) ---

const ItemAcc = struct {
    items: std.ArrayList([]const u8) = .empty,
    total_count: usize = 0,

    fn deinit(self: *ItemAcc, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }
};

// 形状 #1:next_openid 字符串游标(镜像 WxMpUserServiceImpl#userList)
const StrPage = struct {
    openids: []const []const u8,
    next_openid: ?[]const u8, // null / 空 = 无下一页
};
const str_o0 = [_][]const u8{ "A", "B" };
const str_o1 = [_][]const u8{"C"};
const str_o2 = [_][]const u8{ "D", "E" };
const str_pages = [_]StrPage{
    .{ .openids = &str_o0, .next_openid = "N1" },
    .{ .openids = &str_o1, .next_openid = "N2" },
    .{ .openids = &str_o2, .next_openid = null }, // 终止页
};

const StrState = struct {
    calls: usize = 0,
    pages: []const StrPage = &str_pages,

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, cursor: StringCursor) anyerror!StrPage {
        _ = gpa;
        const self: *StrState = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const idx: usize = if (cursor.len == 0)
            0
        else if (std.mem.eql(u8, cursor, "N1"))
            1
        else if (std.mem.eql(u8, cursor, "N2"))
            2
        else
            return error.BadCursor;
        if (idx >= self.pages.len) return error.TooManyFetches; // 终止失败即暴露为错误
        return self.pages[idx];
    }

    fn nextCursor(ctx: *anyopaque, page: StrPage, cursor: StringCursor) ?StringCursor {
        _ = ctx;
        _ = cursor;
        return page.next_openid; // Java: while (isNotEmpty(nextOpenid))
    }
};

fn strMerge(ctx: *anyopaque, gpa: std.mem.Allocator, acc: *ItemAcc, page: StrPage) anyerror!void {
    _ = ctx;
    try acc.items.appendSlice(gpa, page.openids); // Java: addAll(openids)
    acc.total_count += page.openids.len; // Java: count +=
}

const str_vtable = Paginator(ItemAcc, StrPage, StringCursor).VTable{
    .fetch = StrState.fetch,
    .merge = strMerge,
    .next_cursor = StrState.nextCursor,
};

// 形状 #2:offset/limit/total 数值游标(镜像 WxMpStoreServiceImpl#listAll,
// 及 WxMpKefuServiceImpl#kfMsgList 的空页终止)
const OffsetPage = struct {
    items: []const []const u8,
};
const off_i0 = [_][]const u8{ "s0", "s1" };
const off_i1 = [_][]const u8{"s2"};
const off_i2 = [_][]const u8{ "s3", "s4" };
const off_empty = [_][]const u8{};
const off_pages = [_]OffsetPage{
    .{ .items = &off_i0 }, // begin=0
    .{ .items = &off_i1 }, // begin=2
    .{ .items = &off_i2 }, // begin=4,total=5 -> 取完即停
};
const off_pages_empty_term = [_]OffsetPage{
    .{ .items = &off_i0 },
    .{ .items = &off_i1 },
    .{ .items = &off_empty }, // 空页 -> 终止(total=null,kefu 形状)
};

const OffsetState = struct {
    calls: usize = 0,
    pages: []const OffsetPage = &off_pages,

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, cursor: OffsetCursor) anyerror!OffsetPage {
        _ = gpa;
        const self: *OffsetState = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const idx: usize = cursor.begin / cursor.limit;
        if (idx >= self.pages.len) return error.TooManyFetches;
        return self.pages[idx];
    }

    fn nextCursor(ctx: *anyopaque, page: OffsetPage, cursor: OffsetCursor) ?OffsetCursor {
        _ = ctx;
        if (page.items.len == 0) return null; // Java: while (!records/businessList.isEmpty())
        const next_begin = cursor.begin + cursor.limit; // Java: begin += limit
        if (cursor.total) |t| {
            if (next_begin >= t) return null; // Java: if (begin >= totalCount) break
        }
        return .{ .begin = next_begin, .limit = cursor.limit, .total = cursor.total };
    }
};

fn offMerge(ctx: *anyopaque, gpa: std.mem.Allocator, acc: *ItemAcc, page: OffsetPage) anyerror!void {
    _ = ctx;
    try acc.items.appendSlice(gpa, page.items);
    acc.total_count += page.items.len;
}

const off_vtable = Paginator(ItemAcc, OffsetPage, OffsetCursor).VTable{
    .fetch = OffsetState.fetch,
    .merge = offMerge,
    .next_cursor = OffsetState.nextCursor,
};

test "paginate: next_openid 字符串游标(Java WxMpUserServiceImpl#userList)" {
    const gpa = testing.allocator;
    var state = StrState{};
    var acc = ItemAcc{};
    defer acc.deinit(gpa);
    var p = Paginator(ItemAcc, StrPage, StringCursor){ .ctx = &state, .vtable = &str_vtable };
    try p.run(gpa, &acc, ""); // 首页无 next_openid
    try testing.expectEqual(@as(usize, 3), state.calls); // 3 页后终止,无第 4 次 fetch
    try testing.expectEqual(@as(usize, 5), acc.total_count);
    try testing.expectEqualStrings("A", acc.items.items[0]);
    try testing.expectEqualStrings("E", acc.items.items[4]);
}

test "paginate: offset/limit/total 数值游标(Java WxMpStoreServiceImpl#listAll)" {
    const gpa = testing.allocator;
    var state = OffsetState{};
    var acc = ItemAcc{};
    defer acc.deinit(gpa);
    var p = Paginator(ItemAcc, OffsetPage, OffsetCursor){ .ctx = &state, .vtable = &off_vtable };
    try p.run(gpa, &acc, .{ .begin = 0, .limit = 2, .total = 5 });
    try testing.expectEqual(@as(usize, 3), state.calls); // begin 越过 total 即停
    try testing.expectEqual(@as(usize, 5), acc.total_count);
    try testing.expectEqualStrings("s4", acc.items.items[4]);
}

test "paginate: 空页终止 / total=null(Java WxMpKefuServiceImpl#kfMsgList)" {
    const gpa = testing.allocator;
    var state = OffsetState{ .pages = &off_pages_empty_term };
    var acc = ItemAcc{};
    defer acc.deinit(gpa);
    var p = Paginator(ItemAcc, OffsetPage, OffsetCursor){ .ctx = &state, .vtable = &off_vtable };
    try p.run(gpa, &acc, .{ .begin = 0, .limit = 2, .total = null }); // kefu 无 total 上界
    try testing.expectEqual(@as(usize, 3), state.calls); // 取到空页即停
    try testing.expectEqual(@as(usize, 3), acc.total_count); // 空页不累加
    try testing.expectEqualStrings("s2", acc.items.items[2]);
}
