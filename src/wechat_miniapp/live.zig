//! 直播间管理服务 —— 对应 Java `api.WxMaLiveService` +
//! `api.impl.WxMaLiveServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Broadcast.Room/Goods`:
//! - 房间:create/deleteroom/editroom/getpushurl/getsharedcode/addgoods
//!   /addassistant/modifyassistant/removeassistant/getassistantlist
//!   /addsubanchor/modifysubanchor/deletesubanchor/getsubanchor
//!   /updatefeedpublic/updatereplay/updatekf/updatecomment
//!   (前缀 /wxaapi/broadcast/room/,列表查询走 /wxa/business/getliveinfo);
//! - 商品:onsale/deleteInRoom/push/sort/getVideo(前缀 /wxaapi/broadcast/goods/,
//!   注意 deleteInRoom/getVideo 是驼峰路径,与微信端点一致)。
//!
//! 请求体键名与 Java 一致(roomId 驼峰;deleteRoom 用 `id`;
//! getLiveInfo 用 start/limit;getLiveReplay 用 action/room_id)。
//! 响应键:房间列表 `room_info`、回放 `live_replay`、成员小助手 `list`
//! (max_count 微信实际返回下划线,Java bean 未标 @SerializedName 是其缺陷,
//! 此处双读 max_count/maxCount)。
//! errcode≠0 已由基座折叠为 `.err`(createRoom 的 300036 例外,
//! 见方法注释 —— Java 在 catch 里把该错误的响应体当结果解析)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;
const live_goods = @import("live_goods.zig");

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const CREATE_ROOM_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/create";
const GET_LIVE_INFO_URL = "https://api.weixin.qq.com/wxa/business/getliveinfo";
const ADD_GOODS_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/addgoods";
const DELETE_ROOM_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/deleteroom";
const EDIT_ROOM_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/editroom";
const GET_PUSH_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/getpushurl";
const GET_SHARED_CODE_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/getsharedcode";
const ADD_ASSISTANT_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/addassistant";
const MODIFY_ASSISTANT_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/modifyassistant";
const REMOVE_ASSISTANT_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/removeassistant";
const GET_ASSISTANT_LIST_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/getassistantlist";
const ADD_SUBANCHOR_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/addsubanchor";
const MODIFY_SUBANCHOR_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/modifysubanchor";
const DELETE_SUBANCHOR_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/deletesubanchor";
const GET_SUBANCHOR_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/getsubanchor";
const UPDATE_FEED_PUBLIC_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/updatefeedpublic";
const UPDATE_REPLAY_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/updatereplay";
const UPDATE_KF_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/updatekf";
const UPDATE_COMMENT_URL = "https://api.weixin.qq.com/wxaapi/broadcast/room/updatecomment";
const ONSALE_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/onsale";
const DELETE_IN_ROOM_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/deleteInRoom";
const GOODS_PUSH_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/push";
const GOODS_SORT_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/sort";
const GOODS_GET_VIDEO_URL = "https://api.weixin.qq.com/wxaapi/broadcast/goods/getVideo";

// 内部:写单个 JSON 字符串值(新建 Stringify,避免同一实例二次 write 报
// "JSON document already complete")。
fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ------------------------------------------------------------------

/// 对应 `WxMaCreateRoomResult`(qrcode_url 直播小程序码;roomId 驼峰键)。
pub const CreateRoomResult = struct {
    gpa: std.mem.Allocator,
    qrcode_url: ?[]const u8 = null,
    room_id: ?i64 = null,

    pub fn deinit(self: *CreateRoomResult) void {
        if (self.qrcode_url) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxMaLiveSharedCode`(响应键驼峰:cdnUrl/pagePath/posterUrl)。
pub const SharedCode = struct {
    gpa: std.mem.Allocator,
    cdn_url: ?[]const u8 = null,
    page_path: ?[]const u8 = null,
    poster_url: ?[]const u8 = null,

    pub fn deinit(self: *SharedCode) void {
        if (self.cdn_url) |s| self.gpa.free(@constCast(s));
        if (self.page_path) |s| self.gpa.free(@constCast(s));
        if (self.poster_url) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxMaLiveResult.RoomInfo`(键为下划线;注意是 `roomid` 不是 room_id;
/// goods 复用 live_goods 的 Goods bean —— Java 同为 WxMaLiveResult.Goods)。
pub const RoomInfo = struct {
    gpa: std.mem.Allocator,
    name: ?[]const u8 = null,
    roomid: ?i64 = null,
    cover_img: ?[]const u8 = null,
    share_img: ?[]const u8 = null,
    live_status: ?i64 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    anchor_name: ?[]const u8 = null,
    anchor_wechat: ?[]const u8 = null,
    anchor_img: ?[]const u8 = null,
    live_type: ?i64 = null,
    screen_type: ?i64 = null,
    close_like: ?i64 = null,
    close_goods: ?i64 = null,
    close_comment: ?i64 = null,
    close_kf: ?i64 = null,
    close_replay: ?i64 = null,
    is_feeds_public: ?i64 = null,
    creater_openid: ?[]const u8 = null,
    feeds_img: ?[]const u8 = null,
    goods: []live_goods.Goods = &.{},

    pub fn deinit(self: *RoomInfo) void {
        const a = self.gpa;
        if (self.name) |s| a.free(@constCast(s));
        if (self.cover_img) |s| a.free(@constCast(s));
        if (self.share_img) |s| a.free(@constCast(s));
        if (self.anchor_name) |s| a.free(@constCast(s));
        if (self.anchor_wechat) |s| a.free(@constCast(s));
        if (self.anchor_img) |s| a.free(@constCast(s));
        if (self.creater_openid) |s| a.free(@constCast(s));
        if (self.feeds_img) |s| a.free(@constCast(s));
        for (self.goods) |*g| g.deinit();
        if (self.goods.len > 0) a.free(self.goods);
        self.* = undefined;
    }
};

/// 对应 `WxMaLiveResult.LiveReplay`(expire_time/create_time/media_url,
/// 微信端全部返回字符串)。
pub const LiveReplay = struct {
    gpa: std.mem.Allocator,
    expire_time: ?[]const u8 = null,
    create_time: ?[]const u8 = null,
    media_url: ?[]const u8 = null,

    pub fn deinit(self: *LiveReplay) void {
        if (self.expire_time) |s| self.gpa.free(@constCast(s));
        if (self.create_time) |s| self.gpa.free(@constCast(s));
        if (self.media_url) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxMaLiveResult` 的直播间/回放查询面
/// (total/room_info[]/live_replay[];goods 面由 live_goods 承载)。
pub const LiveResult = struct {
    gpa: std.mem.Allocator,
    total: ?i64 = null,
    room_info: []RoomInfo = &.{},
    live_replay: []LiveReplay = &.{},

    pub fn deinit(self: *LiveResult) void {
        for (self.room_info) |*r| r.deinit();
        if (self.room_info.len > 0) self.gpa.free(self.room_info);
        for (self.live_replay) |*r| r.deinit();
        if (self.live_replay.len > 0) self.gpa.free(self.live_replay);
        self.* = undefined;
    }
};

/// 对应 `WxMaAssistantResult.Assistant`(键:timestamp/headimg/nickname/alias/openid)。
pub const Assistant = struct {
    gpa: std.mem.Allocator,
    timestamp: ?i64 = null,
    headimg: ?[]const u8 = null,
    nickname: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    openid: ?[]const u8 = null,

    pub fn deinit(self: *Assistant) void {
        const a = self.gpa;
        if (self.headimg) |s| a.free(@constCast(s));
        if (self.nickname) |s| a.free(@constCast(s));
        if (self.alias) |s| a.free(@constCast(s));
        if (self.openid) |s| a.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxMaAssistantResult`(count/max_count/list[];
/// max_count 双读,见文件头注)。
pub const AssistantList = struct {
    gpa: std.mem.Allocator,
    count: ?i64 = null,
    max_count: ?i64 = null,
    list: []Assistant = &.{},

    pub fn deinit(self: *AssistantList) void {
        for (self.list) |*a| a.deinit();
        if (self.list.len > 0) self.gpa.free(self.list);
        self.* = undefined;
    }
};

// --- service -------------------------------------------------------------------

pub const LiveService = struct {
    svc: *mp_service.Service,

    /// 对应 `createRoom(WxMaLiveRoomInfo)`:POST create(房间信息预构建 JSON)
    /// → CreateRoomResult(qrcode_url/roomId)。
    /// 300036(主播未实名认证)时 Java 会把错误响应体当结果解析
    /// (响应里带二维码),此处保持同一语义:`.err` 里携带完整 WxError,
    /// 由调用方参考;但 errcode==300036 时按 Java 折叠为 `.ok`。
    pub fn createRoom(self: *LiveService, io: std.Io, room_info_json: []const u8) WxResult(CreateRoomResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, CREATE_ROOM_URL, &.{}, room_info_json)) {
            .ok => |b| b,
            .err => |e| return self.createRoomErr(e),
        };
        defer gpa.free(resp);
        return parseCreateRoomResult(gpa, resp);
    }

    // 内部:createRoom 的 errcode=300036 分支(Java:catch 后按 getJson() 解析)。
    fn createRoomErr(self: *LiveService, e_in: WxError) WxResult(CreateRoomResult) {
        const gpa = self.svc.gpa;
        var e = e_in;
        if (e.error_code != 300036) return .{ .err = e };
        // 300036:响应体仍携带 qrcode_url —— 先复制 raw(e.deinit 会释放),
        // 再按 CreateRoomResult 解析(与 Java catch 分支一致)。
        const raw = gpa.dupe(u8, e.raw orelse "{}") catch {
            e.deinit();
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        e.deinit();
        defer gpa.free(raw);
        return parseCreateRoomResult(gpa, raw);
    }

    /// 对应 `deleteRoom(roomId)`:POST deleteroom **{"id":N}**(键是 id 不是 roomId)。
    pub fn deleteRoom(self: *LiveService, io: std.Io, room_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"id\":{d}}}", .{room_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DELETE_ROOM_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `editRoom(WxMaLiveRoomInfo)`:POST editroom(预构建 JSON,原样透传)。
    pub fn editRoom(self: *LiveService, io: std.Io, room_info_json: []const u8) Done {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, EDIT_ROOM_URL, &.{}, room_info_json)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getPushUrl(roomId)`:GET getpushurl?roomId= → pushAddr(gpa 拥有)。
    pub fn getPushUrl(self: *LiveService, io: std.Io, room_id: i64) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        var rid_buf: [24]u8 = undefined;
        const resp = switch (self.svc.get(io, GET_PUSH_URL, &.{
            .{ .key = "roomId", .value = std.fmt.bufPrint(&rid_buf, "{d}", .{room_id}) catch "" },
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live pushurl not json", .{}) };
        defer parsed.deinit();
        const addr = json_util.getStr(parsed.value, "pushAddr") orelse
            return .{ .err = WxError.transport(gpa, "live pushurl missing `pushAddr`", .{}) };
        return .{ .ok = gpa.dupe(u8, addr) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `getSharedCode(roomId, params)`:GET getsharedcode?roomId=[&params=]
    /// → SharedCode(cdnUrl/pagePath/posterUrl 驼峰键)。
    pub fn getSharedCode(self: *LiveService, io: std.Io, room_id: i64, params: ?[]const u8) WxResult(SharedCode) {
        const gpa = self.svc.gpa;
        var rid_buf: [24]u8 = undefined;
        const rid = std.fmt.bufPrint(&rid_buf, "{d}", .{room_id}) catch "";
        var queries: [2]mp_service.Query = undefined;
        var n: usize = 1;
        queries[0] = .{ .key = "roomId", .value = rid };
        if (params) |p| {
            queries[1] = .{ .key = "params", .value = p };
            n += 1;
        }
        const resp = switch (self.svc.get(io, GET_SHARED_CODE_URL, queries[0..n])) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live sharedcode not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = .{
            .gpa = gpa,
            .cdn_url = if (json_util.getStr(parsed.value, "cdnUrl")) |s| (gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }) else null,
            .page_path = if (json_util.getStr(parsed.value, "pagePath")) |s| (gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }) else null,
            .poster_url = if (json_util.getStr(parsed.value, "posterUrl")) |s| (gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) }) else null,
        } };
    }

    /// 对应 `getLiveInfo(start, limit)`:POST getliveinfo {start,limit}
    /// → LiveResult(total/room_info[])。
    pub fn getLiveInfo(self: *LiveService, io: std.Io, start: i64, limit: i64) WxResult(LiveResult) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"start\":{d},\"limit\":{d}}}", .{ start, limit }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_LIVE_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseLiveResult(gpa, resp);
    }

    /// 对应 `getLiveInfos()`:分页拉全量房间(start=0/limit=80,页间 100ms),
    /// 聚合 room_info 返回。Java 在 total=0 且无房间时会死循环(缺陷),
    /// 此处以「本页 0 新增即终止」兜底。
    pub fn getLiveInfos(self: *LiveService, io: std.Io) WxResult([]RoomInfo) {
        const gpa = self.svc.gpa;
        var results: std.ArrayList(RoomInfo) = .empty;
        var start: i64 = 0;
        const limit: i64 = 80;
        var total: i64 = 0;
        while (true) {
            if (total != 0 and total <= start) break;
            const page = switch (self.getLiveInfo(io, start, limit)) {
                .ok => |v| v,
                .err => |e| {
                    freeRoomInfos(gpa, &results);
                    return .{ .err = e };
                },
            };
            var p = page;
            const before = results.items.len;
            var moved: usize = 0;
            while (moved < p.room_info.len) : (moved += 1) {
                results.append(gpa, p.room_info[moved]) catch {
                    // append 失败:第 moved 项未迁移,所有权仍在 p ——
                    // 只释放未迁移项 + 数组壳;已迁移项归 results,由 freeRoomInfos 兜底。
                    for (p.room_info[moved..]) |*rest| rest.deinit();
                    gpa.free(p.room_info);
                    freeRoomInfos(gpa, &results);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
            }
            gpa.free(p.room_info); // 元素已按值迁移,仅释放数组壳
            total = p.total orelse 0;
            start = @intCast(results.items.len);
            if (results.items.len == before) break; // 0 新增:终止(防死循环)
            if (results.items.len > @as(usize, @intCast(@max(total, 0)))) break; // Java while 条件取反
            std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
        }
        const out = results.toOwnedSlice(gpa) catch {
            freeRoomInfos(gpa, &results);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        return .{ .ok = out };
    }

    /// 对应 `getLiveReplay(action, roomId, start, limit)`:POST getliveinfo
    /// {action,room_id,start,limit} → LiveResult(live_replay[])。
    pub fn getLiveReplay(self: *LiveService, io: std.Io, action: []const u8, room_id: i64, start: i64, limit: i64) WxResult(LiveResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
        w.writeAll("{\"action\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        sj.write(action) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print(",\"room_id\":{d},\"start\":{d},\"limit\":{d}}}", .{ room_id, start, limit }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, GET_LIVE_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        return parseLiveResult(gpa, resp);
    }

    /// 对应 `getLiveReplay(roomId, start, limit)`(action 固定 "get_replay")。
    pub fn getLiveReplayDefault(self: *LiveService, io: std.Io, room_id: i64, start: i64, limit: i64) WxResult(LiveResult) {
        return self.getLiveReplay(io, "get_replay", room_id, start, limit);
    }

    /// 对应 `addGoodsToRoom(roomId, goodsIds)`:POST room/addgoods
    /// {roomId,ids:[...]}(驼峰,与 Java 一致)。
    pub fn addGoodsToRoom(self: *LiveService, io: std.Io, room_id: i64, goods_ids: []const i64) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"roomId\":{d},\"ids\":[", .{room_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (goods_ids, 0..) |id, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print("{d}", .{id}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, ADD_GOODS_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `addAssistant(roomId, users)`:POST addassistant
    /// {roomId,users:[预构建]}(users 为 JSON 数组文本,
    /// 对应 Java 的 List<WxMaLiveAssistantInfo>)。
    pub fn addAssistant(self: *LiveService, io: std.Io, room_id: i64, users_json: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"roomId\":{d},\"users\":", .{room_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(users_json) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, ADD_ASSISTANT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `modifyAssistant(roomId, username, nickname)`:POST modifyassistant。
    pub fn modifyAssistant(self: *LiveService, io: std.Io, room_id: i64, username: []const u8, nickname: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"roomId\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print("{d},\"username\":", .{room_id}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, username) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"nickname\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, nickname) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, MODIFY_ASSISTANT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `removeAssistant(roomId, username)`:POST removeassistant。
    pub fn removeAssistant(self: *LiveService, io: std.Io, room_id: i64, username: []const u8) Done {
        return self.usernamePost(io, REMOVE_ASSISTANT_URL, room_id, username);
    }

    /// 对应 `addSubanchor(roomId, username)`:POST addsubanchor {roomId,username}。
    pub fn addSubanchor(self: *LiveService, io: std.Io, room_id: i64, username: []const u8) Done {
        return self.usernamePost(io, ADD_SUBANCHOR_URL, room_id, username);
    }

    /// 对应 `modifySubanchor(roomId, username)`:POST modifysubanchor。
    pub fn modifySubanchor(self: *LiveService, io: std.Io, room_id: i64, username: []const u8) Done {
        return self.usernamePost(io, MODIFY_SUBANCHOR_URL, room_id, username);
    }

    // 内部:removeAssistant/addSubanchor/modifySubanchor 共用
    // (POST {roomId,username})。
    fn usernamePost(self: *LiveService, io: std.Io, url: []const u8, room_id: i64, username: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
        w.writeAll("{\"roomId\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print("{d},\"username\":", .{room_id}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        sj.write(username) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `deleteSubanchor(roomId)`:POST deletesubanchor {roomId}。
    pub fn deleteSubanchor(self: *LiveService, io: std.Io, room_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d}}}", .{room_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DELETE_SUBANCHOR_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getSubanchor(roomId)`:GET getsubanchor?roomId= → username(gpa 拥有)。
    pub fn getSubanchor(self: *LiveService, io: std.Io, room_id: i64) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        var rid_buf: [24]u8 = undefined;
        const resp = switch (self.svc.get(io, GET_SUBANCHOR_URL, &.{
            .{ .key = "roomId", .value = std.fmt.bufPrint(&rid_buf, "{d}", .{room_id}) catch "" },
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live subanchor not json", .{}) };
        defer parsed.deinit();
        const name = json_util.getStr(parsed.value, "username") orelse
            return .{ .err = WxError.transport(gpa, "live subanchor missing `username`", .{}) };
        return .{ .ok = gpa.dupe(u8, name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `updatefeedpublic(roomId, isFeedsPublic)`:POST updatefeedpublic
    /// {roomId,isFeedsPublic}。
    pub fn updatefeedpublic(self: *LiveService, io: std.Io, room_id: i64, is_feeds_public: i64) Done {
        return self.flagPost(io, UPDATE_FEED_PUBLIC_URL, room_id, "isFeedsPublic", is_feeds_public);
    }

    /// 对应 `updatereplay(roomId, closeReplay)`:POST updatereplay。
    pub fn updatereplay(self: *LiveService, io: std.Io, room_id: i64, close_replay: i64) Done {
        return self.flagPost(io, UPDATE_REPLAY_URL, room_id, "closeReplay", close_replay);
    }

    /// 对应 `updatekf(roomId, closeKf)`:POST updatekf。
    pub fn updatekf(self: *LiveService, io: std.Io, room_id: i64, close_kf: i64) Done {
        return self.flagPost(io, UPDATE_KF_URL, room_id, "closeKf", close_kf);
    }

    /// 对应 `updatecomment(roomId, banComment)`:POST updatecomment。
    pub fn updatecomment(self: *LiveService, io: std.Io, room_id: i64, ban_comment: i64) Done {
        return self.flagPost(io, UPDATE_COMMENT_URL, room_id, "banComment", ban_comment);
    }

    // 内部:updatefeedpublic/updatereplay/updatekf/updatecomment 共用
    // (POST {roomId,<flagKey>:<flag>})。
    fn flagPost(self: *LiveService, io: std.Io, url: []const u8, room_id: i64, comptime flag_key: []const u8, flag: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d},\"{s}\":{d}}}", .{ room_id, flag_key, flag }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getAssistantList(roomId)`:GET getassistantlist?roomId=
    /// → AssistantList(count/max_count/list[])。
    pub fn getAssistantList(self: *LiveService, io: std.Io, room_id: i64) WxResult(AssistantList) {
        const gpa = self.svc.gpa;
        var rid_buf: [24]u8 = undefined;
        const resp = switch (self.svc.get(io, GET_ASSISTANT_LIST_URL, &.{
            .{ .key = "roomId", .value = std.fmt.bufPrint(&rid_buf, "{d}", .{room_id}) catch "" },
        })) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "assistant list not json", .{}) };
        defer parsed.deinit();
        var out = AssistantList{
            .gpa = gpa,
            .count = json_util.getInt(parsed.value, "count"),
            // 微信实际返回 max_count;Java bean 只标了 maxCount(缺陷),双读。
            .max_count = json_util.getInt(parsed.value, "max_count") orelse json_util.getInt(parsed.value, "maxCount"),
            .list = &.{},
        };
        errdefer out.deinit();
        if (json_util.getArray(parsed.value, "list")) |arr| {
            const items = gpa.alloc(Assistant, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*a| a.deinit();
                gpa.free(items);
            }
            for (arr.items) |item| {
                var a = Assistant{
                    .gpa = gpa,
                    .timestamp = json_util.getInt(item, "timestamp"),
                    .headimg = null,
                    .nickname = null,
                    .alias = null,
                    .openid = null,
                };
                if (json_util.getStr(item, "headimg")) |s| a.headimg = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "nickname")) |s| a.nickname = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "alias")) |s| a.alias = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "openid")) |s| a.openid = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                items[filled] = a;
                filled += 1;
            }
            out.list = items;
        }
        return .{ .ok = out };
    }

    /// 对应 `onsale(roomId, goodsId, onSale)`:POST goods/onsale
    /// {roomId,goodsId,onSale}(驼峰)。
    pub fn onsale(self: *LiveService, io: std.Io, room_id: i64, goods_id: i64, on_sale: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d},\"goodsId\":{d},\"onSale\":{d}}}", .{ room_id, goods_id, on_sale }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, ONSALE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `deleteInRoom(roomId, goodsId)`:POST goods/deleteInRoom
    /// {roomId,goodsId}(驼峰)。
    pub fn deleteInRoom(self: *LiveService, io: std.Io, room_id: i64, goods_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d},\"goodsId\":{d}}}", .{ room_id, goods_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DELETE_IN_ROOM_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `push(roomId, goodsId)`:POST goods/push {roomId,goodsId}(驼峰)。
    pub fn push(self: *LiveService, io: std.Io, room_id: i64, goods_id: i64) Done {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d},\"goodsId\":{d}}}", .{ room_id, goods_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GOODS_PUSH_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `sort(roomId, goods)`:POST goods/sort {roomId,goods:[预构建]}
    /// (goods 为 JSON 数组文本,元素 {url 原序,goodsId},与 Java
    /// List<Map<String,String>> 对应)。
    pub fn sort(self: *LiveService, io: std.Io, room_id: i64, goods_json: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"roomId\":{d},\"goods\":", .{room_id}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(goods_json) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, GOODS_SORT_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getVideo(roomId, goodsId)`:POST goods/getVideo {roomId,goodsId}
    /// → url(gpa 拥有)。
    pub fn getVideo(self: *LiveService, io: std.Io, room_id: i64, goods_id: i64) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"roomId\":{d},\"goodsId\":{d}}}", .{ room_id, goods_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GOODS_GET_VIDEO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "live video not json", .{}) };
        defer parsed.deinit();
        const url = json_util.getStr(parsed.value, "url") orelse
            return .{ .err = WxError.transport(gpa, "live video missing `url`", .{}) };
        return .{ .ok = gpa.dupe(u8, url) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }
};

// --- 解析辅助 ------------------------------------------------------------------

// 内部:释放 getLiveInfos 聚合中的房间列表(含各项与数组壳)。
fn freeRoomInfos(gpa: std.mem.Allocator, rs: *std.ArrayList(RoomInfo)) void {
    for (rs.items) |*r| r.deinit();
    rs.deinit(gpa);
}

// 内部:解析 CreateRoomResult(qrcode_url/roomId)。
fn parseCreateRoomResult(gpa: std.mem.Allocator, resp: []const u8) WxResult(CreateRoomResult) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "create room not json", .{}) };
    defer parsed.deinit();
    var out = CreateRoomResult{
        .gpa = gpa,
        .room_id = json_util.getInt(parsed.value, "roomId"),
        .qrcode_url = null,
    };
    if (json_util.getStr(parsed.value, "qrcode_url")) |s| out.qrcode_url = gpa.dupe(u8, s) catch
        return .{ .err = WxError.internal(gpa, "oom", .{}) };
    return .{ .ok = out };
}

// 内部:解析 LiveResult(total/room_info[]/live_replay[])。
fn parseLiveResult(gpa: std.mem.Allocator, resp: []const u8) WxResult(LiveResult) {
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "live result not json", .{}) };
    defer parsed.deinit();
    var out = LiveResult{
        .gpa = gpa,
        .total = json_util.getInt(parsed.value, "total"),
        .room_info = &.{},
        .live_replay = &.{},
    };
    errdefer out.deinit();
    if (json_util.getArray(parsed.value, "room_info")) |arr| {
        const items = gpa.alloc(RoomInfo, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |*r| r.deinit();
            gpa.free(items);
        }
        for (arr.items) |item| {
            items[filled] = parseRoomInfo(gpa, item) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            filled += 1;
        }
        out.room_info = items;
    }
    if (json_util.getArray(parsed.value, "live_replay")) |arr| {
        const items = gpa.alloc(LiveReplay, arr.items.len) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |*r| r.deinit();
            gpa.free(items);
        }
        for (arr.items) |item| {
            var r = LiveReplay{
                .gpa = gpa,
                .expire_time = null,
                .create_time = null,
                .media_url = null,
            };
            if (json_util.getStr(item, "expire_time")) |s| r.expire_time = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            if (json_util.getStr(item, "create_time")) |s| r.create_time = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            if (json_util.getStr(item, "media_url")) |s| r.media_url = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            items[filled] = r;
            filled += 1;
        }
        out.live_replay = items;
    }
    return .{ .ok = out };
}

// 内部:解析单个 RoomInfo(下划线键;roomid 非 room_id)。
fn parseRoomInfo(gpa: std.mem.Allocator, item: std.json.Value) !RoomInfo {
    var r = RoomInfo{
        .gpa = gpa,
        .name = null,
        .roomid = json_util.getInt(item, "roomid"),
        .cover_img = null,
        .share_img = null,
        .live_status = json_util.getInt(item, "live_status"),
        .start_time = json_util.getInt(item, "start_time"),
        .end_time = json_util.getInt(item, "end_time"),
        .anchor_name = null,
        .anchor_wechat = null,
        .anchor_img = null,
        .live_type = json_util.getInt(item, "live_type"),
        .screen_type = json_util.getInt(item, "screen_type"),
        .close_like = json_util.getInt(item, "close_like"),
        .close_goods = json_util.getInt(item, "close_goods"),
        .close_comment = json_util.getInt(item, "close_comment"),
        .close_kf = json_util.getInt(item, "close_kf"),
        .close_replay = json_util.getInt(item, "close_replay"),
        .is_feeds_public = json_util.getInt(item, "is_feeds_public"),
        .creater_openid = null,
        .feeds_img = null,
        .goods = &.{},
    };
    errdefer r.deinit();
    if (json_util.getStr(item, "name")) |s| r.name = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "cover_img")) |s| r.cover_img = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "share_img")) |s| r.share_img = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "anchor_name")) |s| r.anchor_name = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "anchor_wechat")) |s| r.anchor_wechat = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "anchor_img")) |s| r.anchor_img = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "creater_openid")) |s| r.creater_openid = try gpa.dupe(u8, s);
    if (json_util.getStr(item, "feeds_img")) |s| r.feeds_img = try gpa.dupe(u8, s);
    if (json_util.getArray(item, "goods")) |arr| {
        const items = try gpa.alloc(live_goods.Goods, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |*g| g.deinit();
            gpa.free(items);
        }
        for (arr.items) |gitem| {
            items[filled] = live_goods.parseGoods(gpa, gitem) catch |e| return e;
            filled += 1;
        }
        r.goods = items;
    }
    return r;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");
const mp_http = @import("wechat_mp").http;

// 测试专用:按调用次数顺序返回响应的分页 mock(getLiveInfos 多页场景用;
// MockExecutor 按子串路由,多次 getliveinfo 只能命中同一条,无法模拟翻页)。
const PagedMock = struct {
    gpa: std.mem.Allocator,
    responses: []const []const u8,
    call: usize = 0,

    fn executeImpl(ctx: *anyopaque, g: std.mem.Allocator, io: std.Io, method: mp_http.RequestExecutor.Method, uri: []const u8, payload: ?[]const u8) mp_http.WxResult([]u8) {
        _ = io;
        _ = method;
        _ = payload;
        const self: *PagedMock = @ptrCast(@alignCast(ctx));
        const idx = @min(self.call, self.responses.len - 1);
        self.call += 1;
        _ = uri;
        return .{ .ok = g.dupe(u8, self.responses[idx]) catch
            return .{ .err = WxError.transport(g, "oom", .{}) } };
    }

    const vtable = mp_http.RequestExecutor.VTable{ .execute = executeImpl };
};

test "live room create/delete/edit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "room/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"roomId\":7,\"qrcode_url\":\"https://qr/7\"}" },
        .{ .match = "room/deleteroom", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "room/editroom", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveService{ .svc = &base };

    const room = "{\"name\":\"测试直播间\"}";
    const created = switch (s.createRoom(io, room)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var cr = created;
    defer cr.deinit();
    try std.testing.expectEqualStrings(room, m.last_body);
    try std.testing.expectEqual(@as(i64, 7), cr.room_id.?);
    try std.testing.expectEqualStrings("https://qr/7", cr.qrcode_url.?);

    // deleteRoom:{"id":N}(键是 id)
    try std.testing.expect(!s.deleteRoom(io, 7).failed());
    try std.testing.expectEqualStrings("{\"id\":7}", m.last_body);

    // editRoom:预构建 JSON 原样透传
    try std.testing.expect(!s.editRoom(io, room).failed());
    try std.testing.expectEqualStrings(room, m.last_body);
}

test "live createRoom errcode=300036 folds to ok (Java catch semantics)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        // 主播未实名:errcode=300036 但响应体仍带 qrcode_url
        .{ .match = "room/create", .response = "{\"errcode\":300036,\"errmsg\":\"anchor not verified\",\"qrcode_url\":\"https://qr/auth\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveService{ .svc = &base };

    const r = s.createRoom(io, "{}");
    switch (r) {
        .ok => |v| {
            var res = v;
            defer res.deinit();
            try std.testing.expectEqualStrings("https://qr/auth", res.qrcode_url.?);
            try std.testing.expect(res.room_id == null);
        },
        .err => return error.Unexpected,
    }

    // 对照:非 300036 错误正常走 .err
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "room/create", .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" },
    });
    defer m2.deinit();
    var cfg2 = try mock_mod.fakeTokenConfig(gpa);
    defer cfg2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg2.config(), m2.executor());
    var s2 = LiveService{ .svc = &base2 };
    switch (s2.createRoom(io, "{}")) {
        .ok => return error.Unexpected,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 40001), err.error_code);
        },
    }
}

test "live pushurl/sharedcode/subanchor/assistant" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getpushurl", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"pushAddr\":\"rtmp://push/1\"}" },
        .{ .match = "getsharedcode", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"cdnUrl\":\"https://cdn\",\"pagePath\":\"pages/live\",\"posterUrl\":\"https://poster\"}" },
        .{ .match = "getsubanchor", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"username\":\"sub1\"}" },
        .{ .match = "getassistantlist", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"count\":1,\"max_count\":5,\"list\":[{\"timestamp\":1600000000,\"headimg\":\"https://h\",\"nickname\":\"助手1\",\"alias\":\"a1\",\"openid\":\"o1\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveService{ .svc = &base };

    const addr = switch (s.getPushUrl(io, 1)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(@constCast(addr));
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getpushurl?roomId=1") != null);
    try std.testing.expectEqualStrings("rtmp://push/1", addr);

    const sc = switch (s.getSharedCode(io, 2, "abc")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var code = sc;
    defer code.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getsharedcode?roomId=2&params=abc") != null);
    try std.testing.expectEqualStrings("https://cdn", code.cdn_url.?);
    try std.testing.expectEqualStrings("pages/live", code.page_path.?);
    try std.testing.expectEqualStrings("https://poster", code.poster_url.?);

    const sub = switch (s.getSubanchor(io, 3)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(@constCast(sub));
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getsubanchor?roomId=3") != null);
    try std.testing.expectEqualStrings("sub1", sub);

    const al = switch (s.getAssistantList(io, 4)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var list = al;
    defer list.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "getassistantlist?roomId=4") != null);
    try std.testing.expectEqual(@as(i64, 1), list.count.?);
    try std.testing.expectEqual(@as(i64, 5), list.max_count.?);
    try std.testing.expectEqual(@as(usize, 1), list.list.len);
    try std.testing.expectEqualStrings("助手1", list.list[0].nickname.?);
    try std.testing.expectEqualStrings("a1", list.list[0].alias.?);
}

test "live getLiveInfo/getLiveReplay + getLiveInfos paging" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // getLiveInfos:两页(total=2,每页 1 间;PagedMock 按调用次数顺序返回)
    var pm = PagedMock{ .gpa = gpa, .responses = &.{
        "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":2,\"room_info\":[{\"name\":\"第1间\",\"roomid\":1,\"live_status\":101,\"start_time\":1600000000,\"end_time\":1600003600,\"anchor_name\":\"主播A\",\"goods\":[{\"goods_id\":11,\"cover_img\":\"https://img11\",\"name\":\"商品11\",\"price\":9.9}]}]}",
        "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":2,\"room_info\":[{\"name\":\"第2间\",\"roomid\":2}]}",
    } };
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), .{ .ptr = @ptrCast(&pm), .vtable = &PagedMock.vtable });
    var s = LiveService{ .svc = &base };

    const rooms = switch (s.getLiveInfos(io)) {
        .ok => |v| v,
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    };
    const rooms_mut = rooms;
    defer {
        for (rooms_mut) |*r| r.deinit();
        gpa.free(rooms_mut);
    }
    try std.testing.expectEqual(@as(usize, 2), pm.call);
    try std.testing.expectEqual(@as(usize, 2), rooms_mut.len);
    try std.testing.expectEqualStrings("第1间", rooms_mut[0].name.?);
    try std.testing.expectEqual(@as(i64, 1), rooms_mut[0].roomid.?);
    try std.testing.expectEqualStrings("主播A", rooms_mut[0].anchor_name.?);
    try std.testing.expectEqual(@as(i64, 101), rooms_mut[0].live_status.?);
    try std.testing.expectEqual(@as(usize, 1), rooms_mut[0].goods.len);
    try std.testing.expectEqual(@as(i64, 11), rooms_mut[0].goods[0].goods_id.?);
    try std.testing.expectEqualStrings("第2间", rooms_mut[1].name.?);

    // getLiveInfo 单页:POST {start,limit}(用子串路由 mock 验证请求体)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getliveinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"room_info\":[{\"name\":\"第1间\",\"roomid\":1}]}" },
    });
    defer m.deinit();
    var cfg2 = try mock_mod.fakeTokenConfig(gpa);
    defer cfg2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg2.config(), m.executor());
    var s2 = LiveService{ .svc = &base2 };

    const li = switch (s2.getLiveInfo(io, 0, 10)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var one = li;
    defer one.deinit();
    try std.testing.expectEqualStrings("{\"start\":0,\"limit\":10}", m.last_body);

    // getLiveReplay:POST {action,room_id,start,limit} → live_replay[]
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getliveinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"live_replay\":[{\"expire_time\":\"2020-01-01\",\"create_time\":\"2020-01-02\",\"media_url\":\"https://media/1\"}]}" },
    });
    defer m2.deinit();
    var cfg3 = try mock_mod.fakeTokenConfig(gpa);
    defer cfg3.deinit();
    var base3 = mp_service.Service.init(gpa, cfg3.config(), m2.executor());
    var s3 = LiveService{ .svc = &base3 };

    const rep = switch (s3.getLiveReplay(io, "get_replay", 1, 0, 10)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var replay = rep;
    defer replay.deinit();
    try std.testing.expectEqualStrings("{\"action\":\"get_replay\",\"room_id\":1,\"start\":0,\"limit\":10}", m2.last_body);
    try std.testing.expectEqual(@as(usize, 1), replay.live_replay.len);
    try std.testing.expectEqualStrings("https://media/1", replay.live_replay[0].media_url.?);

    const rep2 = switch (s3.getLiveReplayDefault(io, 1, 0, 10)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var replay2 = rep2;
    defer replay2.deinit();
    try std.testing.expectEqualStrings("{\"action\":\"get_replay\",\"room_id\":1,\"start\":0,\"limit\":10}", m2.last_body);
}

test "live room flags/goods mutations" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "broadcast/room/addgoods", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "addassistant", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "modifyassistant", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "removeassistant", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "addsubanchor", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "modifysubanchor", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "deletesubanchor", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "updatefeedpublic", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "updatereplay", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "updatekf", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "updatecomment", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/onsale", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/deleteInRoom", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/push", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/sort", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "goods/getVideo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://video/1\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = LiveService{ .svc = &base };

    // addGoodsToRoom:{roomId,ids:[...]}
    try std.testing.expect(!s.addGoodsToRoom(io, 1, &.{ 11, 12 }).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"ids\":[11,12]}", m.last_body);

    // addAssistant:{roomId,users:[...]}(users 预构建数组)
    try std.testing.expect(!s.addAssistant(io, 1, "[{\"username\":\"u1\",\"nickname\":\"n1\"}]").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"users\":[{\"username\":\"u1\",\"nickname\":\"n1\"}]}", m.last_body);

    try std.testing.expect(!s.modifyAssistant(io, 1, "u1", "n2").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"username\":\"u1\",\"nickname\":\"n2\"}", m.last_body);

    try std.testing.expect(!s.removeAssistant(io, 1, "u1").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"username\":\"u1\"}", m.last_body);

    try std.testing.expect(!s.addSubanchor(io, 1, "sub1").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"username\":\"sub1\"}", m.last_body);

    try std.testing.expect(!s.modifySubanchor(io, 1, "sub2").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"username\":\"sub2\"}", m.last_body);

    try std.testing.expect(!s.deleteSubanchor(io, 1).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1}", m.last_body);

    try std.testing.expect(!s.updatefeedpublic(io, 1, 1).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"isFeedsPublic\":1}", m.last_body);

    try std.testing.expect(!s.updatereplay(io, 1, 0).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"closeReplay\":0}", m.last_body);

    try std.testing.expect(!s.updatekf(io, 1, 0).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"closeKf\":0}", m.last_body);

    try std.testing.expect(!s.updatecomment(io, 1, 0).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"banComment\":0}", m.last_body);

    // onsale:{roomId,goodsId,onSale}
    try std.testing.expect(!s.onsale(io, 1, 11, 1).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"goodsId\":11,\"onSale\":1}", m.last_body);

    try std.testing.expect(!s.deleteInRoom(io, 1, 11).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"goodsId\":11}", m.last_body);

    try std.testing.expect(!s.push(io, 1, 11).failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"goodsId\":11}", m.last_body);

    // sort:{roomId,goods:[...]}
    try std.testing.expect(!s.sort(io, 1, "[{\"url\":\"pages/1\",\"goodsId\":11},{\"url\":\"pages/2\",\"goodsId\":12}]").failed());
    try std.testing.expectEqualStrings("{\"roomId\":1,\"goods\":[{\"url\":\"pages/1\",\"goodsId\":11},{\"url\":\"pages/2\",\"goodsId\":12}]}", m.last_body);

    // getVideo:POST {roomId,goodsId} → url
    const video = switch (s.getVideo(io, 1, 11)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(@constCast(video));
    try std.testing.expectEqualStrings("{\"roomId\":1,\"goodsId\":11}", m.last_body);
    try std.testing.expectEqualStrings("https://video/1", video);
}
