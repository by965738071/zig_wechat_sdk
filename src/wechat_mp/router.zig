//! 消息路由器 —— 对应 Java `api.session` 包:
//! `WxMpXmlMessage` / `WxMpXmlOutMessage` / `WxMpMessageRouter` /
//! `WxMpMatcher`(Rule) / `WxMpInterceptorChain` / `WxMpMessageHandler`。
//!
//! 复刻要点(对应 `BaseWxMessageRouter.doRoute`):
//! - 先排重(`common/duplicate.zig`,对应 Java 在 router 里注入 DuplicateChecker);
//! - 规则按注册顺序匹配,全部命中的 handler 依次执行,**最后一个非空回复生效**;
//! - interceptor 环绕 handler 执行(chain.next()),对应 Java 的
//!   `WxMpInterceptor.intercept(chain)` around 语义;
//! - Java 默认 async(线程池并发跑 handler),骨架先同步,异步化是 TODO
//!   (Zig 侧应换成任务队列而非线程池)。
const std = @import("std");
const xml = @import("common").xml;
const consts = @import("common").consts;
const duplicate = @import("common").duplicate;

pub const Error = std.mem.Allocator.Error || error{HandlerFailed} || xml.Error || std.Io.Writer.Error;

/// 入站消息(对应 `WxMpXmlMessage`)。字段即回调 XML 的扁平 k/v。
/// 自持报文副本 `source`,`fields` 的全部 key 借用它 —— 消息生命周期
/// 完全自包,不依赖调用方缓冲区存活(xml.parse 的借用契约在边界处
/// 用一次 dupe 兑换掉,消除悬空 key 风险;异步化后同样成立)。
pub const Message = struct {
    source: []const u8, // 原始报文的独立副本,唯一主人是 fields 携带的 allocator
    fields: xml.Map,

    pub fn fromXml(gpa: std.mem.Allocator, text: []const u8) !Message {
        const source = try gpa.dupe(u8, text);
        errdefer gpa.free(source);
        return .{ .source = source, .fields = try xml.parse(gpa, source) };
    }

    pub fn deinit(self: *Message) void {
        const gpa = self.fields.allocator; // Map 自持 allocator,无需外传
        xml.freeMap(&self.fields);
        gpa.free(self.source);
    }

    pub fn get(self: *const Message, key: []const u8) ?[]const u8 {
        return self.fields.get(key);
    }

    pub fn msgType(self: *const Message) ?[]const u8 {
        return self.get("MsgType");
    }
    pub fn event(self: *const Message) ?[]const u8 {
        return self.get("Event");
    }
    pub fn eventKey(self: *const Message) ?[]const u8 {
        return self.get("EventKey");
    }
    pub fn content(self: *const Message) ?[]const u8 {
        return self.get("Content");
    }
    pub fn fromUser(self: *const Message) ?[]const u8 {
        return self.get("FromUserName");
    }
    pub fn toUser(self: *const Message) ?[]const u8 {
        return self.get("ToUserName");
    }
    pub fn msgId(self: *const Message) ?[]const u8 {
        return self.get("MsgId");
    }
    pub fn createTime(self: *const Message) ?[]const u8 {
        return self.get("CreateTime");
    }

    /// 排重键(对应 `WxMessageDuplicateChecker` 的取键逻辑)。
    pub fn dedupKey(self: *const Message, buf: []u8) []const u8 {
        return duplicate.messageKey(buf, self.msgId(), self.fromUser(), self.createTime());
    }
};

/// 业务上下文(对应 Java 传入 route 的 `Map<String, Object> context`;
/// 骨架值类型为字符串,复杂对象可 JSON 化后放入)。
pub const Context = struct {
    gpa: std.mem.Allocator,
    attrs: std.StringHashMap([]const u8),
    /// 本次路由调用使用的 Io(由 `Router.route` 每次覆盖写入);
    /// 处理器构造回复报文时可用它取真实时间戳(对应 Java reply 的 CreateTime)。
    io: ?std.Io = null,

    pub fn init(gpa: std.mem.Allocator) Context {
        return .{ .gpa = gpa, .attrs = std.StringHashMap([]const u8).init(gpa) };
    }

    pub fn deinit(self: *Context) void {
        var it = self.attrs.iterator();
        while (it.next()) |kv| {
            self.gpa.free(@constCast(kv.key_ptr.*));
            self.gpa.free(@constCast(kv.value_ptr.*));
        }
        self.attrs.deinit();
    }

    pub fn set(self: *Context, key: []const u8, value: []const u8) !void {
        if (self.attrs.fetchRemove(key)) |old| {
            self.gpa.free(@constCast(old.key));
            self.gpa.free(@constCast(old.value));
        }
        try self.attrs.put(try self.gpa.dupe(u8, key), try self.gpa.dupe(u8, value));
    }

    pub fn get(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }
};

/// 匹配规则(对应 `WxMpMatchers.type("text").matcher(...)` 组合)。
/// 非 null 的条件全部满足才算命中。
pub const Rule = struct {
    msg_type: ?[]const u8 = null,
    event: ?[]const u8 = null,
    event_key: ?[]const u8 = null,
    content_equals: ?[]const u8 = null,
    /// 自定义谓词(对应 `Matcher.matches`)
    custom: ?MatchFn = null,
    custom_ptr: *anyopaque = undefined,

    pub const MatchFn = *const fn (ptr: *anyopaque, msg: *const Message) bool;

    pub fn matches(self: *const Rule, msg: *const Message) bool {
        if (self.msg_type) |v| {
            const m = msg.msgType() orelse return false;
            if (!std.mem.eql(u8, m, v)) return false;
        }
        if (self.event) |v| {
            const e = msg.event() orelse return false;
            if (!std.mem.eql(u8, e, v)) return false;
        }
        if (self.event_key) |v| {
            const k = msg.eventKey() orelse return false;
            if (!std.mem.eql(u8, k, v)) return false;
        }
        if (self.content_equals) |v| {
            const c = msg.content() orelse return false;
            if (!std.mem.eql(u8, c, v)) return false;
        }
        if (self.custom) |f| {
            if (!f(self.custom_ptr, msg)) return false;
        }
        return true;
    }
};

/// 业务处理器(对应 `WxMpMessageHandler.handle(message, context)`)。
/// 返回 gpa 分配的回复 xml(可选);null 表示不回复/交给下一个 handler。
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ctx: *anyopaque, msg: *Message, cx: *Context) Error!?[]u8,
    };

    pub fn handle(self: Handler, msg: *Message, cx: *Context) Error!?[]u8 {
        return self.vtable.handle(self.ptr, msg, cx);
    }
};

/// 拦截器(对应 `WxMpInterceptor`):调用 chain.next() 放行,可在前后加工。
pub const Interceptor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        intercept: *const fn (ctx: *anyopaque, chain: *Chain) Error!?[]u8,
    };

    pub fn intercept(self: Interceptor, chain: *Chain) Error!?[]u8 {
        return self.vtable.intercept(self.ptr, chain);
    }
};

/// handler 调用链(对应 `WxMpInterceptorChain`):先拦截器、最后 handler。
pub const Chain = struct {
    interceptors: []const Interceptor,
    idx: usize = 0,
    msg: *Message,
    context: *Context,
    handler: Handler,

    pub fn next(self: *Chain) Error!?[]u8 {
        if (self.idx < self.interceptors.len) {
            const it = self.interceptors[self.idx];
            self.idx += 1;
            return it.intercept(self);
        }
        return self.handler.handle(self.msg, self.context);
    }
};

/// 路由器(对应 `WxMpMessageRouterImpl`)。
pub const Router = struct {
    gpa: std.mem.Allocator,
    bindings: std.ArrayList(Binding),
    interceptors: std.ArrayList(Interceptor),
    /// 可选排重器(命中重复直接当作「已处理」返回 null)
    duplicate_checker: ?duplicate.Checker = null,
    /// 对应 Java `logUnhandledMessage`;骨架走 std.log
    log_unhandled: bool = true,

    pub const Binding = struct { rule: Rule, handler: Handler };

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{
            .gpa = gpa,
            .bindings = .empty,
            .interceptors = .empty,
        };
    }

    pub fn deinit(self: *Router) void {
        self.bindings.deinit(self.gpa);
        self.interceptors.deinit(self.gpa);
    }

    /// 对应 `rule(matcher).handler(h)` 注册(Zig 无需链式,直接重复调用)。
    pub fn rule(self: *Router, r: Rule, h: Handler) !void {
        try self.bindings.append(self.gpa, .{ .rule = r, .handler = h });
    }

    pub fn interceptor(self: *Router, it: Interceptor) !void {
        try self.interceptors.append(self.gpa, it);
    }

    /// 路由入口(对应 `route(WxMpXmlMessage message, Map context)`)。
    /// 返回 gpa 分配的回复 xml(调用方释放),null = 不回复。
    pub fn route(self: *Router, io: std.Io, msg: *Message, cx: *Context) Error!?[]u8 {
        cx.io = io; // 处理器构造回复时可用(真实 CreateTime)
        // 排重(对应 doRoute 里的 duplicateChecker)
        if (self.duplicate_checker) |dc| {
            var keybuf: [128]u8 = undefined;
            if (dc.isDuplicate(io, msg.dedupKey(&keybuf))) return null;
        }

        var last: ?[]u8 = null; // 「最后一个非空回复生效」
        for (self.bindings.items) |b| {
            if (!b.rule.matches(msg)) continue;
            var chain = Chain{
                .interceptors = self.interceptors.items,
                .msg = msg,
                .context = cx,
                .handler = b.handler,
            };
            const reply = try chain.next();
            if (reply) |r| {
                if (last) |old| self.gpa.free(old);
                last = r;
            }
        }
        if (last == null and self.log_unhandled) {
            std.log.debug("unhandled wx message: msgType={s} event={s}", .{
                msg.msgType() orelse "?", msg.event() orelse "?",
            });
        }
        return last;
    }

    /// 便捷入口:XML 文本 → 解析 → 路由 → 释放消息。
    pub fn routeXml(self: *Router, io: std.Io, text: []const u8, cx: *Context) Error!?[]u8 {
        var msg = try Message.fromXml(self.gpa, text);
        defer msg.deinit();
        return self.route(io, &msg, cx);
    }
};

/// 文本回复构造(对应 `WxMpXmlOutMessage.TEXT().build()` + `outxml.BaseBuilder` 的
/// CreateTime = System.currentTimeMillis()/1000)。
/// `io` 为 null 时(无 Io 上下文)退化为 0,与原骨架行为一致。
pub fn textReply(gpa: std.mem.Allocator, io: ?std.Io, to_user: []const u8, from_user: []const u8, content: []const u8) ![]u8 {
    var b = xml.Builder.init(gpa);
    defer b.deinit();
    try b.add("ToUserName", to_user);
    try b.add("FromUserName", from_user);
    var tbuf: [24]u8 = undefined;
    // real 时钟 → Unix 秒级时间戳(与 Java 秒级 CreateTime 语义一致)
    const tval = if (io) |i|
        (std.fmt.bufPrint(&tbuf, "{d}", .{std.Io.Timestamp.now(i, .real).toSeconds()}) catch "0")
    else
        "0";
    try b.add("CreateTime", tval);
    try b.add("MsgType", consts.XmlMsgType.text);
    try b.add("Content", content);
    return b.finish(true);
}

// ---------------------------------------------------------------------------

const EchoHandler = struct {
    calls: usize = 0,

    fn handle(ctx: *anyopaque, msg: *Message, cx: *Context) Error!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const content = msg.content() orelse return null;
        return try textReply(std.testing.allocator, cx.io, msg.fromUser() orelse "", msg.toUser() orelse "", content);
    }
    const vtable = Handler.VTable{ .handle = handle };
};

test "router: rule matching, last-non-null-wins, interceptor around" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var router = Router.init(gpa);
    defer router.deinit();

    var echo = EchoHandler{};
    const echo_handler = Handler{ .ptr = @ptrCast(&echo), .vtable = &EchoHandler.vtable };

    // 规则1:文本 → echo
    try router.rule(.{ .msg_type = consts.XmlMsgType.text }, echo_handler);
    // 规则2:所有消息 → 固定回复「bye」(文本消息两条都命中 → 最后非空生效)
    const Bye = struct {
        fn h(ctx: *anyopaque, msg: *Message, cx: *Context) Error!?[]u8 {
            _ = ctx;
            _ = msg;
            return try textReply(std.testing.allocator, cx.io, "u1", "gh1", "bye");
        }
    };
    try router.rule(.{}, .{ .ptr = undefined, .vtable = &.{ .handle = Bye.h } });

    // 拦截器:仅计数放行
    const CountIt = struct {
        var n: usize = 0;
        fn i(ctx: *anyopaque, chain: *Chain) Error!?[]u8 {
            _ = ctx;
            n += 1;
            return chain.next();
        }
    };
    try router.interceptor(.{ .ptr = undefined, .vtable = &.{ .intercept = CountIt.i } });

    var cx = Context.init(gpa);
    defer cx.deinit();

    const reply = (try router.routeXml(io,
        \\<xml><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[hi]]></Content>
        \\<FromUserName><![CDATA[oU1]]></FromUserName><ToUserName><![CDATA[gh1]]></ToUserName>
        \\<MsgId>123</MsgId></xml>
    , &cx)).?;
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "bye") != null); // 最后一个非空生效
    // 拦截器链是 per-handler 的:两条规则都命中 → 各过一次链(与 Java 一致)
    try std.testing.expectEqual(@as(usize, 2), CountIt.n);

    // event 消息:规则1不命中;规则2是无条件规则→仍命中(验证无条件规则)
    const reply2 = try router.routeXml(io,
        \\<xml><MsgType><![CDATA[event]]></MsgType><Event><![CDATA[CLICK]]></Event>
        \\<FromUserName><![CDATA[oU1]]></FromUserName><ToUserName><![CDATA[gh1]]></ToUserName></xml>
    , &cx);
    try std.testing.expect(reply2 != null);
    if (reply2) |r| gpa.free(r);
}

test "Message: 自持 source —— 输入报文先释放,key 仍可用" {
    const gpa = std.testing.allocator;
    // 把报文放堆上,解析后立刻释放输入,复现「借用契约被踩碎」的场景
    const buf = try gpa.dupe(u8,
        \\<xml><MsgType>text</MsgType><Content>hi</Content>
        \\<FromUserName>oX</FromUserName><CreateTime>1700000000</CreateTime></xml>
    );
    var msg = try Message.fromXml(gpa, buf);
    gpa.free(buf); // ← 借用时代这里就是悬空 key 的起点,现在必须安全
    defer msg.deinit();

    try std.testing.expectEqualStrings("text", msg.msgType().?);
    try std.testing.expectEqualStrings("hi", msg.content().?);
    try std.testing.expectEqualStrings("oX", msg.fromUser().?);
    try std.testing.expectEqualStrings("1700000000", msg.createTime().?);
}
