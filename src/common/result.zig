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
    return r catch |e| .{ .err = WxError.transport(allocator, "transport error: {s}", .{@errorName(e)}) };
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
