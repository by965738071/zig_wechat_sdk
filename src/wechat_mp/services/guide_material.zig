//! 顾问素材服务 —— 逐字对齐 Java `api.WxMpGuideMaterialService` +
//! `api.impl.WxMpGuideMaterialServiceImpl`,端点常量取自 `api_url.zig:Guide`
//! (镜像 Java `enums.WxMpApiUrl.Guide` 的 9 个 material 常量)。
//!
//! Java 接口 9 个方法(名称逐字对齐,impl:20-86,全部 POST):
//!   setGuideCardMaterial(mediaId,type,title,path,appId)
//!                          {"type","media_id","title","path","appid"}(LinkedHashMap 顺序)
//!   getGuideCardMaterial(type)  {"type"} → card_list[{title,appid,path,picurl,master_id,slave_id}]
//!   delGuideCardMaterial(type,title,path,appId)
//!                          {"type","title","path","appid"}
//!   setGuideImageMaterial(mediaId,type)  {"media_id","type"}
//!   getGuideImageMaterial(type,start,num)
//!                          {"type","start","num"} → {total_num,model_list[{picurl}]}
//!   delGuideImageMaterial(type,picUrl)  {"type","picurl"}
//!   setGuideWordMaterial(type,word)     {"type","word"}
//!   getGuideWordMaterial(type,start,num)
//!                          {"type","start","num"} → {total_num,word_list[{word,create_time}]}
//!   delGuideWordMaterial(type,word)     {"type","word"}
//!
//! Java↔Zig 差异:
//!   - Java impl 定义了 ACCOUNT/OPENID 两常量但从未使用,不搬运;
//!   - `WxMpGuideCardMaterialInfo` bean 6 字段逐字收录;
//!   - `WxMpGuideImgMaterialInfoList.model_list` 每项只 picurl 一字段 → `[]ImgItem`;
//!   - `WxMpGuideWordMaterialInfoList` 的列表字段是 **word_list**(非 model_list,
//!     两个 bean 字段名不同,逐字保留)→ `[]WordItem{word,create_time}`。
//!
//! 内存所有权:结果 gpa 拥有,用毕 `deinit()`;`.err` 载荷 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

/// 小程序卡片素材 —— 对应 `WxMpGuideCardMaterialInfo`(6 字段逐字)。
pub const CardMaterialInfo = struct {
    gpa: std.mem.Allocator,
    title: []u8,
    appid: []u8,
    path: []u8,
    picurl: []u8,
    master_id: i64 = 0,
    slave_id: i64 = 0,

    pub fn deinit(self: *CardMaterialInfo) void {
        self.gpa.free(self.title);
        self.gpa.free(self.appid);
        self.gpa.free(self.path);
        self.gpa.free(self.picurl);
        self.* = undefined;
    }
};

/// 图片素材项 —— 对应 `WxMpGuideImgMaterialInfo`(仅 picurl)。
pub const ImgItem = struct {
    gpa: std.mem.Allocator,
    picurl: []u8,

    pub fn deinit(self: *ImgItem) void {
        self.gpa.free(self.picurl);
        self.* = undefined;
    }
};

/// 图片素材列表 —— 对应 `WxMpGuideImgMaterialInfoList`{total_num,model_list}。
pub const ImgMaterialList = struct {
    gpa: std.mem.Allocator,
    total_num: i64 = 0,
    model_list: []ImgItem = &.{},

    pub fn deinit(self: *ImgMaterialList) void {
        for (self.model_list) |*it| it.deinit();
        if (self.model_list.len > 0) self.gpa.free(self.model_list);
        self.* = undefined;
    }
};

/// 文字素材项 —— 对应 `WxMpGuideWordMaterialInfo`{word,create_time}。
pub const WordItem = struct {
    gpa: std.mem.Allocator,
    word: []u8,
    create_time: i64 = 0,

    pub fn deinit(self: *WordItem) void {
        self.gpa.free(self.word);
        self.* = undefined;
    }
};

/// 文字素材列表 —— 对应 `WxMpGuideWordMaterialInfoList`{total_num,word_list}。
pub const WordMaterialList = struct {
    gpa: std.mem.Allocator,
    total_num: i64 = 0,
    word_list: []WordItem = &.{},

    pub fn deinit(self: *WordMaterialList) void {
        for (self.word_list) |*it| it.deinit();
        if (self.word_list.len > 0) self.gpa.free(self.word_list);
        self.* = undefined;
    }
};

pub const GuideMaterialService = struct {
    svc: *service_mod.Service,

    /// 对应 `#setGuideCardMaterial`(impl:20-28):
    /// {"type","media_id","title","path","appid"}(LinkedHashMap 插入顺序)。
    pub fn setGuideCardMaterial(self: *GuideMaterialService, io: std.Io, media_id: []const u8, mtype: i64, title: []const u8, path: []const u8, appid: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("media_id", media_id) catch return .{ .err = oom(gpa) };
        ob.putStr("title", title) catch return .{ .err = oom(gpa) };
        ob.putStr("path", path) catch return .{ .err = oom(gpa) };
        ob.putStr("appid", appid) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.set_guide_card_material, body);
    }

    /// 对应 `#getGuideCardMaterial`(impl:30-34):{"type"} → card_list[]。
    pub fn getGuideCardMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64) WxResult([]CardMaterialInfo) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Guide.get_guide_card_material, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getguidecardmaterial response not json", .{}) };
        defer parsed.deinit();
        var list: std.ArrayList(CardMaterialInfo) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "card_list")) |arr| {
            for (arr.items) |item| {
                var it = CardMaterialInfo{
                    .gpa = gpa,
                    .title = gpa.dupe(u8, json_util.getStrOr(item, "title", "")) catch
                        return .{ .err = oom(gpa) },
                    .appid = gpa.dupe(u8, json_util.getStrOr(item, "appid", "")) catch
                        return .{ .err = oom(gpa) },
                    .path = gpa.dupe(u8, json_util.getStrOr(item, "path", "")) catch
                        return .{ .err = oom(gpa) },
                    .picurl = gpa.dupe(u8, json_util.getStrOr(item, "picurl", "")) catch
                        return .{ .err = oom(gpa) },
                    .master_id = json_util.getIntOr(item, "master_id", 0),
                    .slave_id = json_util.getIntOr(item, "slave_id", 0),
                };
                errdefer it.deinit();
                list.append(gpa, it) catch return .{ .err = oom(gpa) };
            }
        }
        return .{ .ok = list.toOwnedSlice(gpa) catch return .{ .err = oom(gpa) } };
    }

    /// 对应 `#delGuideCardMaterial`(impl:36-44):
    /// {"type","title","path","appid"}(LinkedHashMap 插入顺序)。
    pub fn delGuideCardMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, title: []const u8, path: []const u8, appid: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("title", title) catch return .{ .err = oom(gpa) };
        ob.putStr("path", path) catch return .{ .err = oom(gpa) };
        ob.putStr("appid", appid) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.del_guide_card_material, body);
    }

    /// 对应 `#setGuideImageMaterial`(impl:46-48):{"media_id","type"}。
    pub fn setGuideImageMaterial(self: *GuideMaterialService, io: std.Io, media_id: []const u8, mtype: i64) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("media_id", media_id) catch return .{ .err = oom(gpa) };
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.set_guide_image_material, body);
    }

    /// 对应 `#getGuideImageMaterial`(impl:50-54):
    /// {"type","start","num"} → {total_num,model_list[{picurl}]}。
    pub fn getGuideImageMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, start: i64, num: i64) WxResult(ImgMaterialList) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putInt("start", start) catch return .{ .err = oom(gpa) };
        ob.putInt("num", num) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Guide.get_guide_image_material, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getguideimagematerial response not json", .{}) };
        defer parsed.deinit();
        var r = ImgMaterialList{ .gpa = gpa, .total_num = json_util.getIntOr(parsed.value, "total_num", 0) };
        errdefer r.deinit();
        var list: std.ArrayList(ImgItem) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "model_list")) |arr| {
            for (arr.items) |item| {
                var it = ImgItem{
                    .gpa = gpa,
                    .picurl = gpa.dupe(u8, json_util.getStrOr(item, "picurl", "")) catch
                        return .{ .err = oom(gpa) },
                };
                errdefer it.deinit();
                list.append(gpa, it) catch return .{ .err = oom(gpa) };
            }
        }
        r.model_list = list.toOwnedSlice(gpa) catch return .{ .err = oom(gpa) };
        return .{ .ok = r };
    }

    /// 对应 `#delGuideImageMaterial`(impl:56-58):{"type","picurl"}。
    pub fn delGuideImageMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, picurl: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("picurl", picurl) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.del_guide_image_material, body);
    }

    /// 对应 `#setGuideWordMaterial`(impl:60-62):{"type","word"}。
    pub fn setGuideWordMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, word: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("word", word) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.set_guide_word_material, body);
    }

    /// 对应 `#getGuideWordMaterial`(impl:64-68):
    /// {"type","start","num"} → {total_num,word_list[{word,create_time}]}。
    pub fn getGuideWordMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, start: i64, num: i64) WxResult(WordMaterialList) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putInt("start", start) catch return .{ .err = oom(gpa) };
        ob.putInt("num", num) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        const resp = switch (h.apiPost(self.svc, io, api_url.Guide.get_guide_word_material, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getguidewordmaterial response not json", .{}) };
        defer parsed.deinit();
        var r = WordMaterialList{ .gpa = gpa, .total_num = json_util.getIntOr(parsed.value, "total_num", 0) };
        errdefer r.deinit();
        var list: std.ArrayList(WordItem) = .empty;
        errdefer {
            for (list.items) |*it| it.deinit();
            list.deinit(gpa);
        }
        if (json_util.getArray(parsed.value, "word_list")) |arr| {
            for (arr.items) |item| {
                var it = WordItem{
                    .gpa = gpa,
                    .word = gpa.dupe(u8, json_util.getStrOr(item, "word", "")) catch
                        return .{ .err = oom(gpa) },
                    .create_time = json_util.getIntOr(item, "create_time", 0),
                };
                errdefer it.deinit();
                list.append(gpa, it) catch return .{ .err = oom(gpa) };
            }
        }
        r.word_list = list.toOwnedSlice(gpa) catch return .{ .err = oom(gpa) };
        return .{ .ok = r };
    }

    /// 对应 `#delGuideWordMaterial`(impl:70-72):{"type","word"}。
    pub fn delGuideWordMaterial(self: *GuideMaterialService, io: std.Io, mtype: i64, word: []const u8) Done {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putInt("type", mtype) catch return .{ .err = oom(gpa) };
        ob.putStr("word", word) catch return .{ .err = oom(gpa) };
        const body = ob.toJson() catch return .{ .err = oom(gpa) };
        defer gpa.free(body);
        return h.postVoid(self.svc, io, api_url.Guide.del_guide_word_material, body);
    }
};

// ---------------------------------------------------------------------------
// 契约测试:9 端点 URL/method/请求体 + card_list/model_list/word_list 解析
// (逐字对照 WxMpApiUrl.Guide + WxMpGuideMaterialServiceImpl + 各 bean)
// ---------------------------------------------------------------------------

test "GuideMaterial 契约: card 三端点 + set/del image/word (WxMpApiUrl.Guide)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/setguidecardmaterial", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/guide/getguidecardmaterial", .response = "{\"errcode\":0,\"card_list\":[{\"title\":\"小程序卡片\",\"appid\":\"wx123\",\"path\":\"pages/index\",\"picurl\":\"https://mmbiz.qpic.cn/1.jpg\",\"master_id\":1,\"slave_id\":2}]}" },
        .{ .match = "cgi-bin/guide/delguidecardmaterial", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/guide/setguideimagematerial", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/guide/delguideimagematerial", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/guide/setguidewordmaterial", .response = "{\"errcode\":0}" },
        .{ .match = "cgi-bin/guide/delguidewordmaterial", .response = "{\"errcode\":0}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideMaterialService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // setGuideCardMaterial: {"type","media_id","title","path","appid"}(插入顺序)
    switch (svc.setGuideCardMaterial(io, "MEDIA1", 0, "小程序卡片", "pages/index", "wx123")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetCard;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/setguidecardmaterial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":0,\"media_id\":\"MEDIA1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"title\":\"小程序卡片\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"appid\":\"wx123\"") != null);

    // getGuideCardMaterial: {"type"} → card_list[]
    switch (svc.getGuideCardMaterial(io, 0)) {
        .ok => |cards| {
            defer {
                for (cards) |*c| c.deinit();
                if (cards.len > 0) gpa.free(cards);
            }
            try testing.expectEqual(@as(usize, 1), cards.len);
            try testing.expectEqualStrings("小程序卡片", cards[0].title);
            try testing.expectEqualStrings("wx123", cards[0].appid);
            try testing.expectEqual(@as(i64, 1), cards[0].master_id);
            try testing.expectEqual(@as(i64, 2), cards[0].slave_id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGetCard;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":0") != null);

    // delGuideCardMaterial: {"type","title","path","appid"}
    switch (svc.delGuideCardMaterial(io, 0, "小程序卡片", "pages/index", "wx123")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDelCard;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidecardmaterial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"path\":\"pages/index\"") != null);

    // setGuideImageMaterial: {"media_id","type"}
    switch (svc.setGuideImageMaterial(io, "MEDIA1", 0)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetImage;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/setguideimagematerial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"media_id\":\"MEDIA1\",\"type\":0") != null);

    // delGuideImageMaterial: {"type","picurl"}
    switch (svc.delGuideImageMaterial(io, 0, "https://mmbiz.qpic.cn/1.jpg")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDelImage;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguideimagematerial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"picurl\":\"https://mmbiz.qpic.cn/1.jpg\"") != null);

    // setGuideWordMaterial: {"type","word"}
    switch (svc.setGuideWordMaterial(io, 0, "欢迎光临")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideSetWord;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/setguidewordmaterial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"word\":\"欢迎光临\"") != null);

    // delGuideWordMaterial: {"type","word"}
    switch (svc.delGuideWordMaterial(io, 0, "欢迎光临")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideDelWord;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/delguidewordmaterial") != null);
}

test "GuideMaterial 契约: get image/word 列表 (model_list / word_list)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/guide/getguideimagematerial", .response = "{\"errcode\":0,\"total_num\":2,\"model_list\":[{\"picurl\":\"https://mmbiz.qpic.cn/1.jpg\"},{\"picurl\":\"https://mmbiz.qpic.cn/2.jpg\"}]}" },
        .{ .match = "cgi-bin/guide/getguidewordmaterial", .response = "{\"errcode\":0,\"total_num\":1,\"word_list\":[{\"word\":\"欢迎光临\",\"create_time\":1609459200}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = GuideMaterialService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // getGuideImageMaterial: {"type","start","num"} → total_num + model_list
    switch (svc.getGuideImageMaterial(io, 0, 0, 10)) {
        .ok => |*r| {
            var l = r.*;
            defer l.deinit();
            try testing.expectEqual(@as(i64, 2), l.total_num);
            try testing.expectEqual(@as(usize, 2), l.model_list.len);
            try testing.expectEqualStrings("https://mmbiz.qpic.cn/1.jpg", l.model_list[0].picurl);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGetImage;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguideimagematerial") != null);
    try testing.expect(std.mem.indexOf(u8, mock.body(), "\"type\":0,\"start\":0,\"num\":10") != null);

    // getGuideWordMaterial: → total_num + word_list(注意非 model_list)
    switch (svc.getGuideWordMaterial(io, 0, 0, 10)) {
        .ok => |*r| {
            var l = r.*;
            defer l.deinit();
            try testing.expectEqual(@as(i64, 1), l.total_num);
            try testing.expectEqual(@as(usize, 1), l.word_list.len);
            try testing.expectEqualStrings("欢迎光临", l.word_list[0].word);
            try testing.expectEqual(@as(i64, 1609459200), l.word_list[0].create_time);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.UnexpectedGuideGetWord;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/guide/getguidewordmaterial") != null);
}
