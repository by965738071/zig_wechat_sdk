//! 被动回复消息(公众号)XML 构造器 —— 对应 WxJava `WxMpXmlOutMessage` 家族
//! (`TEXT()/IMAGE()/VOICE()/VIDEO()/MUSIC()/NEWS()...build()`)。
//!
//! 微信「被动回复用户消息」报文(官方文档):
//!   <xml><ToUserName><![CDATA[..]]></ToUserName>
//!        <FromUserName><![CDATA[..]]></FromUserName>
//!        <CreateTime>12345678</CreateTime><MsgType><![CDATA[text]]></MsgType>
//!        ...类型专属字段...</xml>
//! 字段名/大小写逐字对齐官方 XML 报文与 WxJava 的 @XStreamAlias:
//!   注意官方「参数表」把音乐链接写作 `MusicURL`,但 XML 报文样例与
//!   `WxMpXmlOutMusicMessage` 均为 `MusicUrl`(XML 大小写敏感),此处取后者。
//!
//! 所有权:所有构造器返回 gpa 拥有的 `[]u8`,调用方 `gpa.free`。
//! CreateTime 一律由调用方传入(秒级),保证离线测试确定性;需要真实时钟时用
//! `nowSeconds(io)`,构造器内部绝不触达时钟。
//!
//! 安全:字符串字段走 CDATA。`xml.zig` 的 `Builder.finish(true)` 直接把值塞进
//! CDATA 且不处理 `]]>`,会提前闭合 CDATA 段造成 XML 注入;本文件 `cdata()` 把
//! `]]>` 拆成相邻两段 CDATA(`]]]]><![CDATA[>`),既逐字保留内容又不注入标签;
//! 数值字段(CreateTime/ArticleCount)走 `xml.escape` 的非 CDATA 路径。
const std = @import("std");
const testing = std.testing;

const consts = @import("common").consts;
const xml = @import("common").xml;

/// 秒级 Unix 时间戳助手(与 wx_crypt.zig / service.zig 取时钟口径一致)。
/// 单独提供、构造器不主动调用,便于离线测试用固定值。
pub fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

/// 视频回复载荷(MediaId 必填,Title/Description 可选)。
pub const Video = struct {
    media_id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// 音乐回复载荷(ThumbMediaId 必填,其余可选)。
/// 注:官方文档参数表写作 `MusicURL`,XML 报文样例与 WxJava `@XStreamAlias`
/// 均为 `MusicUrl`;XML 大小写敏感,此处按线上报文取 `MusicUrl`。
pub const Music = struct {
    thumb_media_id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    music_url: ?[]const u8 = null,
    hq_music_url: ?[]const u8 = null,
};

/// 图文消息单条 item(官方 Title/Description/PicUrl/Url 均为必填)。
pub const Article = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    pic_url: []const u8 = "",
    url: []const u8 = "",
};

// ---- 内部写入助手 -----------------------------------------------------------

/// 写 `<![CDATA[value]]>`,但把 value 里的 `]]>` 拆分掉以防注入。
/// 拆分串 `]]]]><![CDATA[>` = "]]"(内容) + "]]>"(闭合当前段) + 重开一段,
/// 并把 ">" 作为新段首字符;解析端多段 CDATA 文本会自动拼接回原值。
fn cdata(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeAll("<![CDATA[");
    var rest = value;
    while (std.mem.indexOf(u8, rest, "]]>")) |i| {
        try w.writeAll(rest[0..i]);
        try w.writeAll("]]]]><![CDATA[>");
        rest = rest[i + 3 ..];
    }
    try w.writeAll(rest);
    try w.writeAll("]]>");
}

/// 字符串字段(CDATA)。
fn strField(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("<{s}>", .{name});
    try cdata(w, value);
    try w.print("</{s}>", .{name});
}

/// 数值字段(非 CDATA;复用 xml.zig 的文本转义,数值本身无需转义)。
fn numField(w: *std.Io.Writer, name: []const u8, value: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try w.print("<{s}>", .{name});
    try xml.escape(w, s);
    try w.print("</{s}>", .{name});
}

/// 可选字段:null 或空串不下发(对齐 xml.Builder.addIfNotEmpty 的「空字段不下发」约定)。
fn optField(w: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    if (value) |v| {
        if (v.len != 0) try strField(w, name, v);
    }
}

fn openTag(w: *std.Io.Writer, name: []const u8) !void {
    try w.print("<{s}>", .{name});
}
fn closeTag(w: *std.Io.Writer, name: []const u8) !void {
    try w.print("</{s}>", .{name});
}

/// 公共头:ToUserName / FromUserName / CreateTime / MsgType。
fn header(w: *std.Io.Writer, to_user: []const u8, from_user: []const u8, create_time: i64, msg_type: []const u8) !void {
    try strField(w, "ToUserName", to_user);
    try strField(w, "FromUserName", from_user);
    try numField(w, "CreateTime", create_time);
    try strField(w, "MsgType", msg_type);
}

// ---- 各消息类型构造器(均返回 gpa 拥有的 []u8,调用方 free)-------------------

/// 文本回复(Content)。ToUserName/FromUserName 由调用方按「交换收发方」传入。
pub fn text(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.text);
    try strField(w, "Content", content);
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

/// 图片回复(<Image><MediaId/></Image>)。
pub fn image(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, media_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.image);
    try openTag(w, "Image");
    try strField(w, "MediaId", media_id);
    try closeTag(w, "Image");
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

/// 语音回复(<Voice><MediaId/></Voice>)。
pub fn voice(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, media_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.voice);
    try openTag(w, "Voice");
    try strField(w, "MediaId", media_id);
    try closeTag(w, "Voice");
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

/// 视频回复(<Video><MediaId/><Title?/><Description?/></Video>)。
pub fn video(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, v: Video) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.video);
    try openTag(w, "Video");
    try strField(w, "MediaId", v.media_id);
    try optField(w, "Title", v.title);
    try optField(w, "Description", v.description);
    try closeTag(w, "Video");
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

/// 音乐回复(<Music><Title?/><Description?/><MusicUrl?/><HQMusicUrl?/><ThumbMediaId/></Music>)。
pub fn music(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, m: Music) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.music);
    try openTag(w, "Music");
    try optField(w, "Title", m.title);
    try optField(w, "Description", m.description);
    try optField(w, "MusicUrl", m.music_url);
    try optField(w, "HQMusicUrl", m.hq_music_url);
    try strField(w, "ThumbMediaId", m.thumb_media_id);
    try closeTag(w, "Music");
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

/// 图文回复(<ArticleCount>N</ArticleCount><Articles><item>..</item>..</Articles>)。
/// articles 允许 0 条(产出 ArticleCount=0 + 空 Articles,不崩溃),微信实际要求 >=1 条。
pub fn news(gpa: std.mem.Allocator, to_user: []const u8, from_user: []const u8, create_time: i64, articles: []const Article) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<xml>");
    try header(w, to_user, from_user, create_time, consts.XmlMsgType.news);
    try numField(w, "ArticleCount", @intCast(articles.len));
    try openTag(w, "Articles");
    for (articles) |a| {
        try openTag(w, "item");
        try strField(w, "Title", a.title);
        try strField(w, "Description", a.description);
        try strField(w, "PicUrl", a.pic_url);
        try strField(w, "Url", a.url);
        try closeTag(w, "item");
    }
    try closeTag(w, "Articles");
    try w.writeAll("</xml>");
    return out.toOwnedSlice();
}

// ---- 测试 ------------------------------------------------------------------

test "reply.text: 官方报文形状与字段逐字检查" {
    const gpa = testing.allocator;
    const s = try text(gpa, "toUser", "fromUser", 12345678, "你好");
    defer gpa.free(s);
    try testing.expectEqualStrings(
        "<xml>" ++
            "<ToUserName><![CDATA[toUser]]></ToUserName>" ++
            "<FromUserName><![CDATA[fromUser]]></FromUserName>" ++
            "<CreateTime>12345678</CreateTime>" ++
            "<MsgType><![CDATA[text]]></MsgType>" ++
            "<Content><![CDATA[你好]]></Content>" ++
            "</xml>",
        s,
    );
}

test "reply: CDATA 特殊字符(<, &, ]]>) 逐字保留且防注入" {
    const gpa = testing.allocator;
    const evil = "a<b>&c]]>d<Injected>evil</Injected>e]]>f";
    const s = try text(gpa, "t", "f", 1, evil);
    defer gpa.free(s);
    // 输出里出现拆分标记(证明 ]]> 被处理),且没有裸的注入元素被解析成字段。
    try testing.expect(std.mem.indexOf(u8, s, "]]]]><![CDATA[>") != null);
    var m = try xml.parse(gpa, s);
    defer xml.freeMap(&m);
    try testing.expectEqualStrings(evil, m.get("Content").?); // 内容逐字还原
    try testing.expect(m.get("Injected") == null); // <Injected> 只是 CDATA 文本,不是字段
}

test "reply.image / reply.voice: 嵌套容器与 MediaId" {
    const gpa = testing.allocator;
    {
        const s = try image(gpa, "t", "f", 1, "MID_IMG");
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[image]]></MsgType>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Image><MediaId><![CDATA[MID_IMG]]></MediaId></Image>") != null);
    }
    {
        const s = try voice(gpa, "t", "f", 1, "MID_VOICE");
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[voice]]></MsgType>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Voice><MediaId><![CDATA[MID_VOICE]]></MediaId></Voice>") != null);
    }
}

test "reply.video: MediaId + 可选 Title/Description" {
    const gpa = testing.allocator;
    {
        const s = try video(gpa, "toUser", "fromUser", 12345678, .{
            .media_id = "MID",
            .title = "tt",
            .description = "dd",
        });
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[video]]></MsgType>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Video><MediaId><![CDATA[MID]]></MediaId><Title><![CDATA[tt]]></Title><Description><![CDATA[dd]]></Description></Video>") != null);
    }
    {
        // 可选字段缺省 -> 不下发
        const s = try video(gpa, "t", "f", 1, .{ .media_id = "M" });
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<MediaId><![CDATA[M]]></MediaId>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Title>") == null);
        try testing.expect(std.mem.indexOf(u8, s, "<Description>") == null);
    }
}

test "reply.music: 官方字段名(含 MusicUrl / HQMusicUrl 大小写)" {
    const gpa = testing.allocator;
    const s = try music(gpa, "toUser", "fromUser", 12345678, .{
        .thumb_media_id = "THUMB",
        .title = "TITLE",
        .description = "DESC",
        .music_url = "http://music",
        .hq_music_url = "http://hq",
    });
    defer gpa.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[music]]></MsgType>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Music>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Title><![CDATA[TITLE]]></Title>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Description><![CDATA[DESC]]></Description>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<MusicUrl><![CDATA[http://music]]></MusicUrl>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<HQMusicUrl><![CDATA[http://hq]]></HQMusicUrl>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<ThumbMediaId><![CDATA[THUMB]]></ThumbMediaId>") != null);
    // 文档参数表写作 MusicURL(XML 大小写敏感),此处按官方报文样例与 WxJava 取 MusicUrl
    try testing.expect(std.mem.indexOf(u8, s, "<MusicURL>") == null);
}

test "reply.news: 多图文 ArticleCount / item / 各字段" {
    const gpa = testing.allocator;
    const s = try news(gpa, "toUser", "fromUser", 12345678, &.{
        .{ .title = "t1", .description = "d1", .pic_url = "http://p1", .url = "http://u1" },
        .{ .title = "t2", .description = "d2", .pic_url = "http://p2", .url = "http://u2" },
    });
    defer gpa.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<MsgType><![CDATA[news]]></MsgType>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<ArticleCount>2</ArticleCount>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Articles><item>") != null);
    // 恰好 2 个 <item>
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, "<item>")) |i| {
        count += 1;
        pos = i + 6;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.indexOf(u8, s, "<Title><![CDATA[t1]]></Title>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Description><![CDATA[d2]]></Description>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<PicUrl><![CDATA[http://p2]]></PicUrl>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<Url><![CDATA[http://u2]]></Url>") != null);
}

test "reply: 空值 / 边界(空 Content、恰为 ]]>、0 图文、可选字段空串)" {
    const gpa = testing.allocator;
    {
        const s = try text(gpa, "", "", 0, "");
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<ToUserName><![CDATA[]]></ToUserName>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<CreateTime>0</CreateTime>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Content><![CDATA[]]></Content>") != null);
    }
    {
        // 值恰为 "]]>" -> 拆分后解析端仍还原为 "]]>"
        const s = try text(gpa, "t", "f", 1, "]]>");
        defer gpa.free(s);
        var m = try xml.parse(gpa, s);
        defer xml.freeMap(&m);
        try testing.expectEqualStrings("]]>", m.get("Content").?);
    }
    {
        // 0 篇图文:不崩溃,产出 ArticleCount=0 + 空 Articles
        const s = try news(gpa, "t", "f", 1, &.{});
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<ArticleCount>0</ArticleCount>") != null);
        try testing.expect(std.mem.indexOf(u8, s, "<Articles></Articles>") != null);
    }
    {
        // 可选字段 null / 空串 -> 不下发;必填 ThumbMediaId 仍下发
        const s = try music(gpa, "t", "f", 1, .{ .thumb_media_id = "MID", .title = "", .description = null });
        defer gpa.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "<Title>") == null);
        try testing.expect(std.mem.indexOf(u8, s, "<Description>") == null);
        try testing.expect(std.mem.indexOf(u8, s, "<MusicUrl>") == null);
        try testing.expect(std.mem.indexOf(u8, s, "<HQMusicUrl>") == null);
        try testing.expect(std.mem.indexOf(u8, s, "<ThumbMediaId><![CDATA[MID]]></ThumbMediaId>") != null);
    }
}

test "reply.nowSeconds: 真实秒级时间戳(>0)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    try testing.expect(nowSeconds(threaded.io()) > 0);
}
