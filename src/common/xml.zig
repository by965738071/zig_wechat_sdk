//! 极简 XML 工具 —— 对应 Java `util/xml/XStream*` 的职责子集。
//!
//! Java 端用 XStream 做「注解驱动的 XML ↔ POJO」双向映射。骨架阶段不复刻
//! 反射映射，而是提供两张「底座」：
//! 1. `parse`：把微信回调的**扁平** XML（`<xml><k>v|CDATA</k>...</xml>`）解析成
//!    字符串字典 —— 对应 `WxMpXmlMessage.fromXml` 与 pay 的 `BaseWxPayResult.toMap`
//!    （验签必须用原始报文全字段，这里保留原始 key→value 即可复算）；
//! 2. `Builder`：有序 key/value 列表 → `<xml>` 报文 —— 对应出站消息的 `toXml()`。
//!
//! 安全：与 Java XStreamInitializer 禁用 DTD 同理，遇到 `<!DOCTYPE` 直接报错（防 XXE）。
//! 不支持：属性、命名空间、深层嵌套结构（嵌套内容会被跳过并标注 TODO）。
const std = @import("std");

pub const Error = error{ InvalidXml, InvalidDoctype } || std.mem.Allocator.Error;

pub const Map = std.StringHashMap([]const u8);

/// 把扁平 XML 解析成 key→value（value 为分配好的去空白文本；CDATA 自动脱壳）。
/// 嵌套元素的文本被忽略（只保留直接挂在 <xml> 下的叶子字段）。
/// 生命周期：key 借用输入 `xml` 报文（不拷贝），value 是 dupe；
/// 故 map 必须在输入报文释放前用 `freeMap` 释放。
pub fn parse(allocator: std.mem.Allocator, xml: []const u8) Error!Map {
    var map = Map.init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.*);
        map.deinit();
    }

    // 栈元素直接存输入 xml 上的切片（与 map key 借用输入的约定一致），无需逐个释放。
    var stack = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer stack.deinit(allocator);

    var leaf_text: std.ArrayList(u8) = .empty;
    defer leaf_text.deinit(allocator);
    var pos: usize = 0;
    while (pos < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, pos, '<') orelse {
            // 尾部残留文本（不合法但容忍忽略）
            break;
        };
        // lt 之前的文本内容
        if (lt > pos and stack.items.len == 2) {
            try leaf_text.appendSlice(allocator, xml[pos..lt]);
        }
        pos = lt + 1;

        if (std.mem.startsWith(u8, xml[pos..], "!--")) {
            const end = std.mem.indexOfPos(u8, xml, pos, "-->") orelse return error.InvalidXml;
            pos = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[pos..], "?")) { // <?xml ...?>
            const end = std.mem.indexOfPos(u8, xml, pos, "?>") orelse return error.InvalidXml;
            pos = end + 2;
            continue;
        }
        if (std.mem.startsWith(u8, xml[pos..], "!DOCTYPE") or std.mem.startsWith(u8, xml[pos..], "!Entity")) {
            return error.InvalidDoctype; // 对齐 Java XStream 的 XXE 防护
        }
        if (std.mem.startsWith(u8, xml[pos..], "![CDATA[")) {
            const end = std.mem.indexOfPos(u8, xml, pos, "]]>") orelse return error.InvalidXml;
            if (stack.items.len == 2) {
                try leaf_text.appendSlice(allocator, xml[pos + 8 .. end]);
            }
            pos = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[pos..], "!")) { // 其它 <! 声明
            const end = std.mem.indexOfScalarPos(u8, xml, pos, '>') orelse return error.InvalidXml;
            pos = end + 1;
            continue;
        }

        // 普通标签（开/闭/自闭合）
        const gt = std.mem.indexOfScalarPos(u8, xml, pos, '>') orelse return error.InvalidXml;
        var tag = std.mem.trim(u8, xml[pos..gt], " \t\r\n");
        pos = gt + 1;

        if (tag.len == 0) return error.InvalidXml;

        if (tag[0] == '/') { // 闭合
            const name = std.mem.trim(u8, tag[1..], " \t\r\n");
            if (stack.items.len == 0 or !std.mem.eql(u8, stack.items[stack.items.len - 1], name)) {
                return error.InvalidXml; // 标签不匹配
            }
            _ = stack.pop(); // 存的是输入切片，无需释放；下面还要用 name 做 map key
            if (stack.items.len == 1) { // 刚关闭一个叶子字段
                const value = std.mem.trim(u8, leaf_text.items, " \t\r\n");
                try map.put(name, try allocator.dupe(u8, value));
                leaf_text.clearRetainingCapacity();
            }
            continue;
        }

        var self_closing = false;
        if (tag[tag.len - 1] == '/') {
            self_closing = true;
            tag = std.mem.trim(u8, tag[0 .. tag.len - 1], " \t\r\n"); // 0.18：trimRight 并入 trim
        }
        // 去掉属性（骨架不解析属性）
        if (std.mem.indexOfScalar(u8, tag, ' ')) |sp| tag = tag[0..sp];
        if (tag.len == 0) return error.InvalidXml;

        if (self_closing and stack.items.len == 1) {
            try map.put(tag, try allocator.dupe(u8, ""));
            continue;
        }
        try stack.append(allocator, tag);
    }
    // 收尾校验:所有已开启标签必须闭合,否则畸形/截断报文会被当成空结果吞掉。
    if (stack.items.len != 0) return error.InvalidXml;
    return map;
}

/// 释放 parse 结果。
pub fn freeMap(map: *Map) void {
    const a = map.allocator;
    var it = map.iterator();
    while (it.next()) |e| a.free(e.value_ptr.*);
    map.deinit();
}

/// 有序 XML 构造器（对应 XStream 序列化出站消息）。
pub const Builder = struct {
    gpa: std.mem.Allocator,
    pairs: std.ArrayList(Pair),

    pub const Pair = struct { key: []const u8, value: []const u8 };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa, .pairs = .empty };
    }

    pub fn deinit(self: *Builder) void {
        self.pairs.deinit(self.gpa);
    }

    pub fn add(self: *Builder, key: []const u8, value: []const u8) !void {
        try self.pairs.append(self.gpa, .{ .key = key, .value = value });
    }

    /// 值为空则跳过（对应微信「空字段不下发」的常见约定）。
    pub fn addIfNotEmpty(self: *Builder, key: []const u8, value: []const u8) !void {
        if (value.len == 0) return;
        try self.add(key, value);
    }

    pub fn finish(self: *Builder, use_cdata: bool) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer out.deinit();
        try out.writer.writeAll("<xml>");
        for (self.pairs.items) |p| {
            try out.writer.print("<{s}>", .{p.key});
            if (use_cdata) {
                try out.writer.print("<![CDATA[{s}]]>", .{p.value});
            } else {
                try escape(&out.writer, p.value);
            }
            try out.writer.print("</{s}>", .{p.key});
        }
        try out.writer.writeAll("</xml>");
        return out.toOwnedSlice();
    }
};

/// XML 文本转义（非 CDATA 路径）。
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

/// 提取指定标签的内容（含 CDATA 脱壳）；用于 pay V2 报文粗取字段。
pub fn extractTag(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) ?[]const u8 {
    const open = std.fmt.allocPrint(allocator, "<{s}>", .{tag}) catch return null;
    defer allocator.free(open);
    const start = std.mem.indexOf(u8, xml, open) orelse return null;
    const close = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
    defer allocator.free(close);
    const content_start = start + open.len;
    const end = std.mem.indexOfPos(u8, xml, content_start, close) orelse return null;
    var body = xml[content_start..end];
    if (std.mem.startsWith(u8, body, "<![CDATA[") and std.mem.endsWith(u8, body, "]]>")) {
        body = body[9 .. body.len - 3];
    }
    return body;
}

test "xml parse flat with cdata" {
    const gpa = std.testing.allocator;
    const xml =
        \\<xml><ToUserName><![CDATA[gh_123]]></ToUserName>
        \\<FromUserName>oABC</FromUserName>
        \\<MsgType><![CDATA[event]]></MsgType>
        \\<Event><![CDATA[CLICK]]></Event>
        \\<CreateTime>1700000000</CreateTime></xml>
    ;
    var m = try parse(gpa, xml);
    defer freeMap(&m);
    try std.testing.expectEqualStrings("gh_123", m.get("ToUserName").?);
    try std.testing.expectEqualStrings("oABC", m.get("FromUserName").?);
    try std.testing.expectEqualStrings("CLICK", m.get("Event").?);
    try std.testing.expectEqualStrings("1700000000", m.get("CreateTime").?);
}

test "xml builder + extract" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    try b.add("ToUserName", "oX");
    try b.add("Content", "hello & <world>");
    const xml = try b.finish(false);
    defer gpa.free(xml);
    try std.testing.expectEqualStrings(
        "<xml><ToUserName>oX</ToUserName><Content>hello &amp; &lt;world&gt;</Content></xml>",
        xml,
    );
}

// ---------------------------------------------------------------------------
// 边界 / 错误路径(畸形、截断、XXE、空值、超长输入)
// ---------------------------------------------------------------------------

test "xml parse: XXE / DOCTYPE rejected (XmlUtilsTest.java testXml2Map_xxe)" {
    const gpa = std.testing.allocator;
    // 逐字迁移 Java XmlUtilsTest.testXml2Map_xxe 的报文:遇到 <!DOCTYPE 直接拒绝。
    const xxe =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" ++
        "<!DOCTYPE test [\n" ++
        "<!ENTITY xxe SYSTEM \"file:///etc/passwd\">\n" ++
        "]>\n" ++
        "<xml></xml>";
    try std.testing.expectError(error.InvalidDoctype, parse(gpa, xxe));
    // <!Entity 变体同样拒绝(对齐 XStream 禁用 DTD 的 XXE 防护)。
    try std.testing.expectError(error.InvalidDoctype, parse(gpa, "<xml><!Entity foo></xml>"));
}

test "xml parse: truncated / mismatched / unterminated constructs -> InvalidXml" {
    const gpa = std.testing.allocator;
    // 截断报文:标签未闭合,收尾校验 stack 非空 -> InvalidXml(不被当成空结果吞掉)。
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><a>1"));
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml"));
    // 闭合标签名与栈顶不匹配。
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><a></b></xml>"));
    // 空标签名 <>.
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><></xml>"));
    // 各「未终止」构造:CDATA / 注释 / 处理指令。
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><a><![CDATA[never closed</a></xml>"));
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><!-- never closed"));
    try std.testing.expectError(error.InvalidXml, parse(gpa, "<xml><?xml version=\"1.0\""));
}

test "xml parse: comments / PI / self-closing / attributes / whitespace" {
    const gpa = std.testing.allocator;
    const doc =
        "<?xml version=\"1.0\"?>\n" ++
        "<xml>\n" ++
        "<!-- a comment -->\n" ++
        "<a>  spaced  </a>\n" ++
        "<b attr=\"ignored\">value</b>\n" ++
        "<empty/>\n" ++
        "</xml>";
    var m = try parse(gpa, doc);
    defer freeMap(&m);
    try std.testing.expectEqualStrings("spaced", m.get("a").?); // 叶子文本 trim
    try std.testing.expectEqualStrings("value", m.get("b").?); // 属性被剥离
    try std.testing.expectEqualStrings("", m.get("empty").?); // 自闭合 -> 空值
    try std.testing.expectEqual(@as(usize, 3), m.count());
}

test "xml parse: flat-only, nested children skipped (骨架已知限制)" {
    const gpa = std.testing.allocator;
    const doc = "<xml><outer><inner>deep</inner></outer><leaf>ok</leaf></xml>";
    var m = try parse(gpa, doc);
    defer freeMap(&m);
    // 骨架只保留 <xml> 直接叶子字段:嵌套 inner 被跳过。
    // 注:Java XmlUtils.xml2Map 会返回嵌套 Map(见 XmlUtilsTest.testXml2Map),
    // 这是骨架的已知简化,不宣称与 Java 一致。
    try std.testing.expect(m.get("inner") == null);
    try std.testing.expectEqualStrings("ok", m.get("leaf").?);
    try std.testing.expectEqualStrings("", m.get("outer").?);
}

test "xml escape + Builder(cdata / addIfNotEmpty)" {
    const gpa = std.testing.allocator;
    {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try escape(&out.writer, "a<b>c&d\"e'f"); // 5 个需转义字符全覆盖
        const s = try out.toOwnedSlice();
        defer gpa.free(s);
        try std.testing.expectEqualStrings("a&lt;b&gt;c&amp;d&quot;e&apos;f", s);
    }
    {
        var b = Builder.init(gpa);
        defer b.deinit();
        try b.add("A", "x<y"); // cdata 路径:值原样不转义
        try b.addIfNotEmpty("SKIP", ""); // 空值跳过(微信「空字段不下发」)
        try b.addIfNotEmpty("B", "value");
        const s = try b.finish(true);
        defer gpa.free(s);
        try std.testing.expectEqualStrings("<xml><A><![CDATA[x<y]]></A><B><![CDATA[value]]></B></xml>", s);
    }
}

test "xml extractTag: CDATA / plain / missing / unclosed" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("Hello", extractTag(gpa, "<xml><a><![CDATA[Hello]]></a></xml>", "a").?);
    try std.testing.expectEqualStrings("World", extractTag(gpa, "<xml><a>World</a></xml>", "a").?);
    try std.testing.expect(extractTag(gpa, "<xml><a>World</a></xml>", "missing") == null);
    try std.testing.expect(extractTag(gpa, "<xml><a>World", "a") == null); // 无闭合标签
}

test "xml parse: empty input + very long value (空值 / 超长输入)" {
    const gpa = std.testing.allocator;
    {
        var m = try parse(gpa, "");
        defer freeMap(&m);
        try std.testing.expectEqual(@as(usize, 0), m.count());
    }
    {
        const big = try gpa.alloc(u8, 100_000);
        defer gpa.free(big);
        @memset(big, 'x');
        const doc = try std.fmt.allocPrint(gpa, "<xml><big>{s}</big></xml>", .{big});
        defer gpa.free(doc);
        var m = try parse(gpa, doc);
        defer freeMap(&m); // 先于 doc 释放(key 借用 doc)
        try std.testing.expectEqualStrings(big, m.get("big").?);
        try std.testing.expectEqual(@as(usize, 100_000), m.get("big").?.len);
    }
}
