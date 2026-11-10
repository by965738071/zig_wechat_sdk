//! `WxResult(T)` —— Java `throws WxErrorException` 的 Zig 对应物。
//!
//! Java SDK 的约定：业务方法要么返回解析好的 result，要么抛 `WxErrorException`
//! （连网络 IOException 也被包装成它）。Zig 没有异常，这里用带载荷的 tagged
//! union 完整保留该语义：
//! - `.ok`  —— 成功，携带值；
//! - `.err` —— 失败，携带 `WxError`（协议 errcode 或传输/内部错误）。
//!
//! 调用方习惯写法：
//! ```zig
//! const r = svc.get_user_info(openid);
//! switch (r) {
//!     .ok => |user| { ... },
//!     .err => |e| std.log.err("wx failed [{d}] {s}", .{ e.error_code, e.error_msg }),
//! }
//! ```
const std = @import("std");
pub const WxError = @import("error.zig").WxError;

/// 对应 Java 的 `T method(...) throws WxErrorException`。
pub fn WxResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: WxError,

        /// 便捷判错。
        pub fn failed(self: @This()) bool {
            return switch (self) {
                .err => true,
                .ok => false,
            };
        }

        /// 成功则返回值的只读指针，失败返回 null。
        pub fn value(self: *const @This()) ?*const T {
            return switch (self.*) {
                .ok => |*v| v,
                .err => null,
            };
        }
    };
}

/// 无返回值的方法（对应 Java 的 `void method() throws WxErrorException`）。
pub const Done = WxResult(void);

// ---------------------------------------------------------------------------
// HTTP 应答载荷 —— 对应 Java `CloseableHttpResponse`(org.apache.http) 的
// 「响应头 + 响应体」二元结构。`RequestExecutor` vtable 用 `executeEx` 回传它。
// ---------------------------------------------------------------------------

/// 一个响应头(名/值)。对应 `org.apache.http.Header`。
pub const Header = struct { name: []const u8, value: []const u8 };

/// 执行器应答:响应体 + 响应头。
/// 所有权:`body` 由 gpa 拥有;`headers` 非空时,头数组及每个 name/value 都由
/// gpa 拥有(经 `dupeHeaders`/`parseHeaders` 产出),`deinit` 一并释放。
/// `headers == &.{}`(静态空切片)是合法的「无响应头」占位,不释放数组。
pub const Response = struct {
    body: []u8,
    headers: []const Header = &.{},

    /// 大小写不敏感取头值(HTTP 头名大小写不敏感,对应 `getFirstHeader`)。
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        return headerValue(self.headers, name);
    }

    /// 释放响应头、返回 body(所有权转移给调用方)。用于「只要 body」的兼容路径
    /// (如 `Service`/`v3Send` 的既有调用方),避免丢弃 header 造成泄漏。
    pub fn takeBody(self: Response, gpa: std.mem.Allocator) []u8 {
        if (self.headers.len > 0) {
            for (self.headers) |h| {
                gpa.free(@constCast(h.name));
                gpa.free(@constCast(h.value));
            }
            gpa.free(@constCast(self.headers));
        }
        return self.body;
    }

    pub fn deinit(self: Response, gpa: std.mem.Allocator) void {
        gpa.free(self.takeBody(gpa));
    }
};

/// 释放 `dupeHeaders`/`parseHeaders` 产出的 gpa 拥有的头列表(空占位安全)。
/// 供真实执行器在「只要 body」路径丢弃响应头时复用,与 `Response.takeBody` 同口径。
pub fn freeHeaders(gpa: std.mem.Allocator, headers: []const Header) void {
    if (headers.len == 0) return;
    for (headers) |h| {
        gpa.free(@constCast(h.name));
        gpa.free(@constCast(h.value));
    }
    gpa.free(@constCast(headers));
}

/// 大小写不敏感地在头列表里找第一个匹配项,返回值(与 `getFirstHeader` 一致)。
pub fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// 把借用的头列表整体 dupe 成 gpa 拥有的列表(供 `Response.headers`)。
pub fn dupeHeaders(gpa: std.mem.Allocator, raw: []const Header) ![]const Header {
    if (raw.len == 0) return &.{};
    const out = try gpa.alloc(Header, raw.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(out);
    }
    for (raw) |h| {
        const n = gpa.dupe(u8, h.name) catch |e| return e;
        const v = gpa.dupe(u8, h.value) catch |e| {
            gpa.free(n); // 尚未写入 out,函数级 errdefer 不会覆盖它
            return e;
        };
        out[filled] = .{ .name = n, .value = v };
        filled += 1;
    }
    return out;
}

/// 从**原始 HTTP 响应头字节**解析出响应头列表(gpa 拥有,用毕配合 Response.deinit)。
/// 对应 `std.http.Client.Response.Head.iterateHeaders()` 的解析口径,是真实
/// 执行器接入响应头回传时的协议层接缝:执行器拿到 head.bytes 后调用本函数即可。
/// 纯函数、不碰网络,便于离线单测。输入以 `\r\n\r\n` 结尾(含首行状态行)。
pub fn parseHeaders(gpa: std.mem.Allocator, head_bytes: []const u8) ![]const Header {
    var count: usize = 0;
    var probe = std.http.HeaderIterator.init(head_bytes);
    while (probe.next()) |_| count += 1;
    if (count == 0) return &.{};

    const out = try gpa.alloc(Header, count);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(out);
    }
    var it = std.http.HeaderIterator.init(head_bytes);
    while (it.next()) |h| {
        const n = gpa.dupe(u8, h.name) catch |e| return e;
        const v = gpa.dupe(u8, h.value) catch |e| {
            gpa.free(n); // 尚未写入 out,函数级 errdefer 不会覆盖它
            return e;
        };
        out[filled] = .{ .name = n, .value = v };
        filled += 1;
    }
    return out;
}

pub fn ok(comptime T: type, v: T) WxResult(T) {
    return .{ .ok = v };
}

pub fn err(comptime T: type, e: WxError) WxResult(T) {
    return .{ .err = e };
}

/// 把 `!T`（Zig 错误）折叠为 `WxResult(T)`：transport 错误 → WxError(code=-1)。
/// 对应 Java 里 `catch (IOException e) { throw new WxErrorException(e); }`。
pub fn fromZig(comptime T: type, allocator: std.mem.Allocator, r: anyerror!T) WxResult(T) {
    const v = r catch |e| return .{ .err = WxError.transport(allocator, "transport error: {s}", .{@errorName(e)}) };
    return .{ .ok = v };
}

test "WxResult basics" {
    const e = WxError{ .allocator = std.testing.allocator, .error_code = 40001, .error_msg = "x" };
    const r: WxResult(u8) = err(u8, e);
    try std.testing.expect(r.failed());
    try std.testing.expectEqual(@as(?*const u8, null), r.value());
}

test "Response.header is case-insensitive + deinit owns body/headers" {
    const gpa = std.testing.allocator;
    const raw = [_]Header{
        .{ .name = "Wechatpay-Timestamp", .value = "1700000000" },
        .{ .name = "Wechatpay-Nonce", .value = "ABC" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const headers = try dupeHeaders(gpa, &raw);
    const body = try gpa.dupe(u8, "{\"ok\":true}");
    var resp = Response{ .body = body, .headers = headers };

    // HTTP 头名大小写不敏感(对应 getFirstHeader)
    try std.testing.expectEqualStrings("1700000000", resp.header("wechatpay-timestamp").?);
    try std.testing.expectEqualStrings("ABC", resp.header("WECHATPAY-NONCE").?);
    try std.testing.expectEqualStrings("application/json", resp.header("content-type").?);
    try std.testing.expect(resp.header("Wechatpay-Signature") == null);
    resp.deinit(gpa); // 由 testing.allocator 兜底:漏/重复 free 都会失败
}

test "parseHeaders parses a raw HTTP head (protocol seam)" {
    const gpa = std.testing.allocator;
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "Wechatpay-Timestamp: 1700000000\r\n" ++
        "Wechatpay-Nonce: NONCE123\r\n" ++
        "Wechatpay-Signature: SIG==\r\n" ++
        "Wechatpay-Serial: SERIAL1\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "\r\n";
    const headers = try parseHeaders(gpa, head);
    const body = try gpa.dupe(u8, "");
    var resp = Response{ .body = body, .headers = headers };
    defer resp.deinit(gpa);

    try std.testing.expectEqualStrings("1700000000", resp.header("Wechatpay-Timestamp").?);
    try std.testing.expectEqualStrings("NONCE123", resp.header("wechatpay-nonce").?);
    try std.testing.expectEqualStrings("SIG==", resp.header("Wechatpay-Signature").?);
    try std.testing.expectEqualStrings("SERIAL1", resp.header("Wechatpay-Serial").?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", resp.header("content-type").?);
    try std.testing.expectEqual(@as(usize, 5), headers.len);
}

// ---------------------------------------------------------------------------
// 边界 / 辅助方法覆盖
// ---------------------------------------------------------------------------

test "WxResult helpers: ok/err/value/failed" {
    const gpa = std.testing.allocator;
    {
        const r: WxResult(u32) = ok(u32, 42);
        try std.testing.expect(!r.failed());
        try std.testing.expectEqual(@as(u32, 42), r.value().?.*);
    }
    {
        const r: WxResult(u32) = err(u32, WxError{ .allocator = gpa, .error_code = 40001, .error_msg = "x" });
        try std.testing.expect(r.failed());
        try std.testing.expectEqual(@as(?*const u32, null), r.value());
    }
    // fromZig 的成功/错误两路径由文件末「fromZig」用例单独覆盖(此前该函数存在
    // 「成功值未包进 .ok」的缺陷,本轮已修复)。
}

test "freeHeaders: owned headers released, empty placeholder safe" {
    const gpa = std.testing.allocator;
    const raw = [_]Header{
        .{ .name = "A", .value = "1" },
        .{ .name = "B", .value = "2" },
    };
    const hs = try dupeHeaders(gpa, &raw);
    freeHeaders(gpa, hs); // 由 testing.allocator 兜底:漏/重复 free 都会失败
    // 静态空占位(&.{})是合法的「无响应头」,不应被 free。
    freeHeaders(gpa, &.{});
    const parsed = try parseHeaders(gpa, "HTTP/1.1 200 OK\r\nX: y\r\n\r\n");
    freeHeaders(gpa, parsed);
}

test "Response.takeBody frees headers and transfers body" {
    const gpa = std.testing.allocator;
    {
        const raw = [_]Header{
            .{ .name = "A", .value = "1" },
            .{ .name = "B", .value = "2" },
        };
        const headers = try dupeHeaders(gpa, &raw);
        var resp = Response{ .body = try gpa.dupe(u8, "BODY"), .headers = headers };
        const body = resp.takeBody(gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("BODY", body);
        // 若 takeBody 漏释放 headers,testing.allocator 会报泄漏。
    }
    {
        // headers == &.{} 静态空占位:takeBody 不应 free 数组,只返回 body。
        var resp = Response{ .body = try gpa.dupe(u8, "X"), .headers = &.{} };
        const body = resp.takeBody(gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("X", body);
    }
}

test "headerValue first-match / dupeHeaders(empty) / parseHeaders(no headers)" {
    const gpa = std.testing.allocator;
    const hs = [_]Header{
        .{ .name = "X-Dup", .value = "first" },
        .{ .name = "x-dup", .value = "second" },
    };
    // getFirstHeader 口径:大小写不敏感且返回第一个匹配。
    try std.testing.expectEqualStrings("first", headerValue(&hs, "X-DUP").?);
    try std.testing.expect(headerValue(&hs, "missing") == null);

    // 空头列表返回静态占位,长度为 0。
    const empty = try dupeHeaders(gpa, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // 只有状态行、无头字段的 HTTP head -> 空头列表。
    const head = "HTTP/1.1 204 No Content\r\n\r\n";
    const parsed = try parseHeaders(gpa, head);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
    var r = Response{ .body = try gpa.dupe(u8, ""), .headers = parsed };
    r.deinit(gpa); // 空头占位 + body 一并释放
}

// ---------------------------------------------------------------------------
// fromZig:!T -> WxResult(T) 的成功/错误两路径(修复后覆盖)
// ---------------------------------------------------------------------------

test "fromZig: success wraps value in .ok; error folds to transport .err" {
    const gpa = std.testing.allocator;
    // 成功值确实进 .ok(此前缺陷:直接返回裸 T,从未包进 .ok)
    {
        var r = fromZig(u32, gpa, @as(anyerror!u32, 42));
        switch (r) {
            .ok => |v| try std.testing.expectEqual(@as(u32, 42), v),
            .err => |*e| {
                defer e.deinit();
                return error.ShouldBeOk;
            },
        }
    }
    // 错误折叠成 transport .err,code=-1,文案含 @errorName(e)
    {
        var r = fromZig(u32, gpa, @as(anyerror!u32, error.Boom));
        switch (r) {
            .ok => return error.ShouldBeErr,
            .err => |*e| {
                defer e.deinit(); // error_msg 由 allocPrint 拥有
                try std.testing.expectEqual(WxError.Source.transport, e.source);
                try std.testing.expectEqual(@as(i64, -1), e.error_code);
                try std.testing.expectEqualStrings("transport error: Boom", e.error_msg);
            },
        }
    }
    // void 载荷同样成立(Done 场景)
    {
        var r = fromZig(void, gpa, @as(anyerror!void, {}));
        switch (r) {
            .ok => {},
            .err => |*e| {
                defer e.deinit();
                return error.ShouldBeOk;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// OOM / 失败回退:dupeHeaders / parseHeaders 的 errdefer 逐点注入
// ---------------------------------------------------------------------------

test "dupeHeaders/parseHeaders: OOM unwinds errdefer with no leak" {
    const raw = [_]Header{
        .{ .name = "X-One", .value = "value-1" },
        .{ .name = "X-Two", .value = "value-2" },
    };
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "X-One: value-1\r\n" ++
        "X-Two: value-2\r\n" ++
        "\r\n";

    const H = struct {
        fn freeOwned(gpa: std.mem.Allocator, hs: []const Header) void {
            for (hs) |h| {
                gpa.free(@constCast(h.name));
                gpa.free(@constCast(h.value));
            }
            if (hs.len > 0) gpa.free(@constCast(hs));
        }
    };

    // 每个 fail_index 用全新 FailingAllocator 逐点注入 OOM:命中中途分配 ->
    // expectError(OutOfMemory),由函数级 errdefer + 「v dupe 失败时 free(n)」
    // 负责清理;未命中(fail_index 落在分配次数之外) -> 成功返回,手动释放。
    // 底层是 std.testing.allocator,两条路径任何泄漏都会在测试结束时被抓出。
    for ([_]usize{ 0, 1, 2, 3, 4, 5 }) |fail_at| {
        {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
            const fa = failing.allocator();
            if (dupeHeaders(fa, &raw)) |hs| {
                H.freeOwned(fa, hs);
            } else |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                try std.testing.expect(failing.has_induced_failure);
            }
        }
        {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
            const fa = failing.allocator();
            if (parseHeaders(fa, head)) |hs| {
                H.freeOwned(fa, hs);
            } else |e| {
                try std.testing.expectEqual(error.OutOfMemory, e);
                try std.testing.expect(failing.has_induced_failure);
            }
        }
    }
}
