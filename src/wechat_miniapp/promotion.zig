//! 小程序推广员服务 —— 对应 Java `api.WxMaPromotionService` +
//! `api.impl.WxMaPromotionServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Promotion`(前缀 promoter/):
//! addrole/getrole/updaterole/addpromoter/getpromoter/updatepromoter/
//! getinvitationmaterial/sendmsg/singlesendmsg/getmsg/getmsgclickdata/
//! getsharematerial/getrelation/getorder,均 POST。
//!
//! 与 Java 的差异(重要):
//! - Java getPromoter/getRelation/getOrder 里 `errcode != 0 || errcode != 103006`
//!   恒真(应为 `&&`),导致即使 errcode=0 也必然抛异常 —— 实际不可用。
//!   Zig 按意图修正:errcode=0 正常;errcode=103006(空列表)视为成功返回空结果,
//!   其余错误照常 `.err`。
//! - GetPromoterResponse.total_cnt Java 声明为 String(微信可能返回数字),
//!   looseStr 归一化为字符串,与 Gson 宽容转换一致。
//! - errcode≠0 已由基座折叠为 `.err`,WxMaBaseResponse 的 errcode/errmsg
//!   载荷字段不再保留(仅 fail_list 元素内的逐条 errcode/errmsg 保留)。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

/// 「空列表」错误码 —— Java `WxMaPromotionServiceImpl.ERR_CODE_OF_EMPTY_LIST`。
const ERR_CODE_OF_EMPTY_LIST: i64 = 103006;

const ADD_ROLE_URL = "https://api.weixin.qq.com/promoter/addrole";
const GET_ROLE_URL = "https://api.weixin.qq.com/promoter/getrole";
const UPDATE_ROLE_URL = "https://api.weixin.qq.com/promoter/updaterole";
const ADD_PROMOTER_URL = "https://api.weixin.qq.com/promoter/addpromoter";
const GET_PROMOTER_URL = "https://api.weixin.qq.com/promoter/getpromoter";
const UPDATE_PROMOTER_URL = "https://api.weixin.qq.com/promoter/updatepromoter";
const GET_INVITATION_MATERIAL_URL = "https://api.weixin.qq.com/promoter/getinvitationmaterial";
const SEND_MSG_URL = "https://api.weixin.qq.com/promoter/sendmsg";
const SINGLE_SEND_MSG_URL = "https://api.weixin.qq.com/promoter/singlesendmsg";
const GET_MSG_URL = "https://api.weixin.qq.com/promoter/getmsg";
const GET_MSG_CLICK_DATA_URL = "https://api.weixin.qq.com/promoter/getmsgclickdata";
const GET_SHARE_MATERIAL_URL = "https://api.weixin.qq.com/promoter/getsharematerial";
const GET_RELATION_URL = "https://api.weixin.qq.com/promoter/getrelation";
const GET_ORDER_URL = "https://api.weixin.qq.com/promoter/getorder";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

/// 宽容取字符串:接受 .string/.number_string/.integer(Gson 对 String 字段的
/// 数字→字符串宽容转换)。返回 gpa 拥有的副本。
fn looseStr(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) !?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const c = o.get(key) orelse return null;
    switch (c) {
        .string => |s| return try gpa.dupe(u8, s),
        .number_string => |s| return try gpa.dupe(u8, s),
        .integer => |i| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return null;
            return try gpa.dupe(u8, s);
        },
        else => return null,
    }
}

/// 数组元素取整数(裸值,无 key)。
fn valueInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// 数组元素取字符串(裸值,无 key)。
fn valueStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

// --- 请求 bean ------------------------------------------------------------------

/// 对应 `promoter.request.WxMaPromotionAddRoleRequest`(name 必填,desc 非必填)。
pub const AddRoleRequest = struct {
    name: []const u8,
    desc: ?[]const u8 = null,

    pub fn to_json(self: AddRoleRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"name\":");
        try js(w, self.name);
        if (self.desc) |v| {
            try w.writeAll(",\"desc\":");
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetRoleRequest`(role_id 非必填)。
pub const GetRoleRequest = struct {
    role_id: ?i64 = null,

    pub fn to_json(self: GetRoleRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        if (self.role_id) |v| try w.print("\"role_id\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromoterUpdateRoleRequest`(role_id 必填)。
pub const UpdateRoleRequest = struct {
    role_id: i64,
    name: ?[]const u8 = null,
    desc: ?[]const u8 = null,

    pub fn to_json(self: UpdateRoleRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"role_id\":{d}", .{self.role_id});
        if (self.name) |v| {
            try w.writeAll(",\"name\":");
            try js(w, v);
        }
        if (self.desc) |v| {
            try w.writeAll(",\"desc\":");
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionAddPromoterRequest.Promoter`
/// (openid/role_id 必填,其余非必填)。
pub const Promoter = struct {
    openid: []const u8,
    role_id: i64,
    retail_id: ?[]const u8 = null,
    extra_info: ?[]const u8 = null,
    name: ?[]const u8 = null,
    phone: ?[]const u8 = null,
};

/// 对应 `promoter.request.WxMaPromotionAddPromoterRequest`。
pub const AddPromoterRequest = struct {
    promoter_list: []const Promoter,

    pub fn to_json(self: AddPromoterRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"promoter_list\":[");
        for (self.promoter_list, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"openid\":");
            try js(w, p.openid);
            try w.print(",\"role_id\":{d}", .{p.role_id});
            if (p.retail_id) |v| {
                try w.writeAll(",\"retail_id\":");
                try js(w, v);
            }
            if (p.extra_info) |v| {
                try w.writeAll(",\"extra_info\":");
                try js(w, v);
            }
            if (p.name) |v| {
                try w.writeAll(",\"name\":");
                try js(w, v);
            }
            if (p.phone) |v| {
                try w.writeAll(",\"phone\":");
                try js(w, v);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetPromoterRequest`(全字段非必填)。
pub const GetPromoterRequest = struct {
    openid: ?[]const u8 = null,
    role_id: ?i64 = null,
    retail_id: ?[]const u8 = null,
    begin_time: ?i64 = null,
    end_time: ?i64 = null,
    /// 分页透传,单次拉取上限 1000,超过须分页。
    start_id: ?[]const u8 = null,
    /// 默认返回 openid,填 1 返回 unionid。
    need_unionid: ?i64 = null,
    auth_status: ?i64 = null,
    decl_status: ?[]const u8 = null,

    pub fn to_json(self: GetPromoterRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeByte('{');
        var sep: []const u8 = "";
        if (self.openid) |v| {
            try w.print("{s}\"openid\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.role_id) |v| {
            try w.print("{s}\"role_id\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.retail_id) |v| {
            try w.print("{s}\"retail_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.begin_time) |v| {
            try w.print("{s}\"begin_time\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.end_time) |v| {
            try w.print("{s}\"end_time\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.start_id) |v| {
            try w.print("{s}\"start_id\":", .{sep});
            try js(w, v);
            sep = ",";
        }
        if (self.need_unionid) |v| {
            try w.print("{s}\"need_unionid\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.auth_status) |v| {
            try w.print("{s}\"auth_status\":{d}", .{ sep, v });
            sep = ",";
        }
        if (self.decl_status) |v| {
            try w.print("{s}\"decl_status\":", .{sep});
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionUpdatePromoterRequest`(id 必填)。
pub const UpdatePromoterRequest = struct {
    id: []const u8,
    role_id: ?i64 = null,
    retail_id: ?[]const u8 = null,
    extra_info: ?[]const u8 = null,
    name: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    decl_status: ?[]const u8 = null,

    pub fn to_json(self: UpdatePromoterRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"id\":");
        try js(w, self.id);
        if (self.role_id) |v| try w.print(",\"role_id\":{d}", .{v});
        if (self.retail_id) |v| {
            try w.writeAll(",\"retail_id\":");
            try js(w, v);
        }
        if (self.extra_info) |v| {
            try w.writeAll(",\"extra_info\":");
            try js(w, v);
        }
        if (self.name) |v| {
            try w.writeAll(",\"name\":");
            try js(w, v);
        }
        if (self.phone) |v| {
            try w.writeAll(",\"phone\":");
            try js(w, v);
        }
        if (self.decl_status) |v| {
            try w.writeAll(",\"decl_status\":");
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetInvitationMaterialRequest`
/// (role_id 必填)。
pub const GetInvitationMaterialRequest = struct {
    role_id: i64,
    invitation_type: ?i64 = null,

    pub fn to_json(self: GetInvitationMaterialRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"role_id\":{d}", .{self.role_id});
        if (self.invitation_type) |v| try w.print(",\"invitation_type\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionSendMsgRequest`
/// (msg_type/content/path 必填)。list_type:1 发给 role_id 下所有推广员,
/// 2 发给 retail_id 下所有推广员,3 发给 id 对应推广员,0/不填发全部。
/// content 为 json 格式字符串,整体作为字符串值传入。
pub const SendMsgRequest = struct {
    msg_type: i64,
    content: []const u8,
    /// 非必填,不填默认为调起接口的 appid。
    appid: ?[]const u8 = null,
    path: []const u8,
    list_type: ?i64 = null,
    /// list_type=1 时必填。
    role_id: ?[]const i64 = null,
    /// list_type=2 时必填。
    retail_id: ?[]const []const u8 = null,
    /// list_type=3 时必填。
    id: ?[]const []const u8 = null,

    pub fn to_json(self: SendMsgRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"msg_type\":{d},\"content\":", .{self.msg_type});
        try js(w, self.content);
        if (self.appid) |v| {
            try w.writeAll(",\"appid\":");
            try js(w, v);
        }
        try w.writeAll(",\"path\":");
        try js(w, self.path);
        if (self.list_type) |v| try w.print(",\"list_type\":{d}", .{v});
        if (self.role_id) |arr| {
            try w.writeAll(",\"role_id\":[");
            for (arr, 0..) |v, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{d}", .{v});
            }
            try w.writeByte(']');
        }
        if (self.retail_id) |arr| {
            try w.writeAll(",\"retail_id\":[");
            for (arr, 0..) |v, i| {
                if (i > 0) try w.writeByte(',');
                try js(w, v);
            }
            try w.writeByte(']');
        }
        if (self.id) |arr| {
            try w.writeAll(",\"id\":[");
            for (arr, 0..) |v, i| {
                if (i > 0) try w.writeByte(',');
                try js(w, v);
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionSingleSendMsgRequest`
/// (msg_type/content/path 必填,appid/openid 非必填)。
pub const SingleSendMsgRequest = struct {
    msg_type: i64,
    content: []const u8,
    appid: ?[]const u8 = null,
    path: []const u8,
    openid: ?[]const u8 = null,

    pub fn to_json(self: SingleSendMsgRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"msg_type\":{d},\"content\":", .{self.msg_type});
        try js(w, self.content);
        if (self.appid) |v| {
            try w.writeAll(",\"appid\":");
            try js(w, v);
        }
        try w.writeAll(",\"path\":");
        try js(w, self.path);
        if (self.openid) |v| {
            try w.writeAll(",\"openid\":");
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetMsgRequest`(msg_id 必填)。
pub const GetMsgRequest = struct {
    msg_id: []const u8,

    pub fn to_json(self: GetMsgRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"msg_id\":");
        try js(w, self.msg_id);
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetMsgClickDataRequest`
/// (send_date/dimonsion/msg_type/msg_id 必填;字段名 dimonsion 为微信原样拼写)。
pub const GetMsgClickDataRequest = struct {
    send_date: []const u8,
    dimonsion: i64,
    msg_type: i64,
    msg_id: []const u8,
    begin_send_time: ?i64 = null,
    end_send_time: ?i64 = null,

    pub fn to_json(self: GetMsgClickDataRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"send_date\":");
        try js(w, self.send_date);
        try w.print(",\"dimonsion\":{d},\"msg_type\":{d},\"msg_id\":", .{ self.dimonsion, self.msg_type });
        try js(w, self.msg_id);
        if (self.begin_send_time) |v| try w.print(",\"begin_send_time\":{d}", .{v});
        if (self.end_send_time) |v| try w.print(",\"end_send_time\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetShareMaterialRequest`
/// (path/openid 必填)。
pub const GetShareMaterialRequest = struct {
    path: []const u8,
    openid: []const u8,
    extra_info: ?[]const u8 = null,
    title: ?[]const u8 = null,
    share_type: ?i64 = null,
    env_version: ?[]const u8 = null,

    pub fn to_json(self: GetShareMaterialRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"path\":");
        try js(w, self.path);
        try w.writeAll(",\"openid\":");
        try js(w, self.openid);
        if (self.extra_info) |v| {
            try w.writeAll(",\"extra_info\":");
            try js(w, v);
        }
        if (self.title) |v| {
            try w.writeAll(",\"title\":");
            try js(w, v);
        }
        if (self.share_type) |v| try w.print(",\"share_type\":{d}", .{v});
        if (self.env_version) |v| {
            try w.writeAll(",\"env_version\":");
            try js(w, v);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetRelationRequest`(openid 必填)。
pub const GetRelationRequest = struct {
    openid: []const u8,
    begin_time: ?i64 = null,
    end_time: ?i64 = null,
    scene: ?i64 = null,
    path: ?[]const u8 = null,
    start_id: ?[]const u8 = null,
    need_unionid: ?i64 = null,

    pub fn to_json(self: GetRelationRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid\":");
        try js(w, self.openid);
        if (self.begin_time) |v| try w.print(",\"begin_time\":{d}", .{v});
        if (self.end_time) |v| try w.print(",\"end_time\":{d}", .{v});
        if (self.scene) |v| try w.print(",\"scene\":{d}", .{v});
        if (self.path) |v| {
            try w.writeAll(",\"path\":");
            try js(w, v);
        }
        if (self.start_id) |v| {
            try w.writeAll(",\"start_id\":");
            try js(w, v);
        }
        if (self.need_unionid) |v| try w.print(",\"need_unionid\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

/// 对应 `promoter.request.WxMaPromotionGetOrderRequest`(openid 必填)。
pub const GetOrderRequest = struct {
    openid: []const u8,
    mch_id: ?[]const u8 = null,
    trade_no: ?[]const u8 = null,
    out_trade_no: ?[]const u8 = null,
    /// 订单状态:1 支付完成 2 退款受理。
    status: ?i64 = null,
    start_id: ?[]const u8 = null,
    need_unionid: ?i64 = null,
    /// 订单支付日期,格式 yyyyMMdd,如 20230801。
    date: ?i64 = null,

    pub fn to_json(self: GetOrderRequest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"openid\":");
        try js(w, self.openid);
        if (self.mch_id) |v| {
            try w.writeAll(",\"mch_id\":");
            try js(w, v);
        }
        if (self.trade_no) |v| {
            try w.writeAll(",\"trade_no\":");
            try js(w, v);
        }
        if (self.out_trade_no) |v| {
            try w.writeAll(",\"out_trade_no\":");
            try js(w, v);
        }
        if (self.status) |v| try w.print(",\"status\":{d}", .{v});
        if (self.start_id) |v| {
            try w.writeAll(",\"start_id\":");
            try js(w, v);
        }
        if (self.need_unionid) |v| try w.print(",\"need_unionid\":{d}", .{v});
        if (self.date) |v| try w.print(",\"date\":{d}", .{v});
        try w.writeByte('}');
        return out.toOwnedSlice();
    }
};

// --- 响应 bean ------------------------------------------------------------------

/// 对应 `promoter.response.WxMaPromotionAddRoleResponse`。gpa 拥有。
pub const AddRoleResult = struct {
    gpa: std.mem.Allocator,
    role_id: ?i64,
    name: ?[]const u8,
    desc: ?[]const u8,

    pub fn deinit(self: *AddRoleResult) void {
        const g = self.gpa;
        if (self.name) |s| g.free(@constCast(s));
        if (self.desc) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const AddRoleResult) void {
        const g = self.gpa;
        if (self.name) |s| g.free(s);
        if (self.desc) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetRoleResponse.Role`。gpa 拥有。
pub const Role = struct {
    gpa: std.mem.Allocator,
    role_id: ?i64,
    name: ?[]const u8,
    desc: ?[]const u8,

    pub fn deinit(self: *Role) void {
        const g = self.gpa;
        if (self.name) |s| g.free(@constCast(s));
        if (self.desc) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const Role) void {
        const g = self.gpa;
        if (self.name) |s| g.free(s);
        if (self.desc) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetRoleResponse`。gpa 拥有。
pub const GetRoleResult = struct {
    gpa: std.mem.Allocator,
    role_list: []Role,
    total_cnt: ?i64,

    pub fn deinit(self: *GetRoleResult) void {
        const g = self.gpa;
        for (self.role_list) |*r| r.deinit();
        g.free(self.role_list);
    }

    pub fn deinitConst(self: *const GetRoleResult) void {
        const g = self.gpa;
        for (self.role_list) |*r| r.deinitConst();
        g.free(self.role_list);
    }
};

/// 对应 `promoter.response.WxMaPromotionAddPromoterResponse.Promoter`
/// (fail_list 元素,含逐条 errcode/errmsg)。gpa 拥有。
pub const AddPromoterFail = struct {
    gpa: std.mem.Allocator,
    openid: ?[]const u8,
    role_id: ?i64,
    retail_id: ?[]const u8,
    extra_info: ?[]const u8,
    name: ?[]const u8,
    phone: ?[]const u8,
    errcode: ?i64,
    errmsg: ?[]const u8,

    pub fn deinit(self: *AddPromoterFail) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(@constCast(s));
        if (self.retail_id) |s| g.free(@constCast(s));
        if (self.extra_info) |s| g.free(@constCast(s));
        if (self.name) |s| g.free(@constCast(s));
        if (self.phone) |s| g.free(@constCast(s));
        if (self.errmsg) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const AddPromoterFail) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(s);
        if (self.retail_id) |s| g.free(s);
        if (self.extra_info) |s| g.free(s);
        if (self.name) |s| g.free(s);
        if (self.phone) |s| g.free(s);
        if (self.errmsg) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionAddPromoterResponse`。gpa 拥有。
pub const AddPromoterResult = struct {
    gpa: std.mem.Allocator,
    total_cnt: ?i64,
    fail_cnt: ?i64,
    fail_list: []AddPromoterFail,

    pub fn deinit(self: *AddPromoterResult) void {
        const g = self.gpa;
        for (self.fail_list) |*f| f.deinit();
        g.free(self.fail_list);
    }

    pub fn deinitConst(self: *const AddPromoterResult) void {
        const g = self.gpa;
        for (self.fail_list) |*f| f.deinitConst();
        g.free(self.fail_list);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetPromoterResponse.Promoter`。gpa 拥有。
pub const PromoterInfo = struct {
    gpa: std.mem.Allocator,
    openid: ?[]const u8,
    role_id: ?i64,
    retail_id: ?[]const u8,
    extra_info: ?[]const u8,
    name: ?[]const u8,
    phone: ?[]const u8,
    auth_status: ?i64,
    decl_status: ?[]const u8,
    update_time: ?i64,
    id: ?[]const u8,

    pub fn deinit(self: *PromoterInfo) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(@constCast(s));
        if (self.retail_id) |s| g.free(@constCast(s));
        if (self.extra_info) |s| g.free(@constCast(s));
        if (self.name) |s| g.free(@constCast(s));
        if (self.phone) |s| g.free(@constCast(s));
        if (self.decl_status) |s| g.free(@constCast(s));
        if (self.id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const PromoterInfo) void {
        const g = self.gpa;
        if (self.openid) |s| g.free(s);
        if (self.retail_id) |s| g.free(s);
        if (self.extra_info) |s| g.free(s);
        if (self.name) |s| g.free(s);
        if (self.phone) |s| g.free(s);
        if (self.decl_status) |s| g.free(s);
        if (self.id) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetPromoterResponse`。gpa 拥有。
/// total_cnt Java 声明为 String(微信可能回数字,looseStr 归一化)。
pub const GetPromoterResult = struct {
    gpa: std.mem.Allocator,
    total_cnt: ?[]const u8,
    promoter_list: []PromoterInfo,

    pub fn deinit(self: *GetPromoterResult) void {
        const g = self.gpa;
        if (self.total_cnt) |s| g.free(@constCast(s));
        for (self.promoter_list) |*p| p.deinit();
        g.free(self.promoter_list);
    }

    pub fn deinitConst(self: *const GetPromoterResult) void {
        const g = self.gpa;
        if (self.total_cnt) |s| g.free(s);
        for (self.promoter_list) |*p| p.deinitConst();
        g.free(self.promoter_list);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetInvitationMaterialResponse`。gpa 拥有。
pub const GetInvitationMaterialResult = struct {
    gpa: std.mem.Allocator,
    poster: ?[]const u8,
    qrcode: ?[]const u8,
    tag: ?[]const u8,

    pub fn deinit(self: *GetInvitationMaterialResult) void {
        const g = self.gpa;
        if (self.poster) |s| g.free(@constCast(s));
        if (self.qrcode) |s| g.free(@constCast(s));
        if (self.tag) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const GetInvitationMaterialResult) void {
        const g = self.gpa;
        if (self.poster) |s| g.free(s);
        if (self.qrcode) |s| g.free(s);
        if (self.tag) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionSendMsgResponse`。gpa 拥有。
pub const SendMsgResult = struct {
    gpa: std.mem.Allocator,
    msg_id: ?[]const u8,

    pub fn deinit(self: *SendMsgResult) void {
        const g = self.gpa;
        if (self.msg_id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const SendMsgResult) void {
        const g = self.gpa;
        if (self.msg_id) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetMsgResponse.FailInfo`。gpa 拥有。
pub const MsgFailInfo = struct {
    gpa: std.mem.Allocator,
    id: ?[]const u8,
    errorcode: ?i64,

    pub fn deinit(self: *MsgFailInfo) void {
        const g = self.gpa;
        if (self.id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const MsgFailInfo) void {
        const g = self.gpa;
        if (self.id) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetMsgResponse`。gpa 拥有。
pub const GetMsgResult = struct {
    gpa: std.mem.Allocator,
    send_cnt: ?i64,
    percent: ?i64,
    fail_cnt: ?i64,
    fail_info: []MsgFailInfo,
    fail_info_url: ?[]const u8,
    msg_type: ?i64,
    content: ?[]const u8,
    appid: ?[]const u8,
    path: ?[]const u8,
    list_type: ?i64,
    role_id: []i64,
    retail_id: [][]const u8,
    id: [][]const u8,

    pub fn deinit(self: *GetMsgResult) void {
        const g = self.gpa;
        for (self.fail_info) |*f| f.deinit();
        g.free(self.fail_info);
        if (self.fail_info_url) |s| g.free(@constCast(s));
        if (self.content) |s| g.free(@constCast(s));
        if (self.appid) |s| g.free(@constCast(s));
        if (self.path) |s| g.free(@constCast(s));
        g.free(self.role_id);
        for (self.retail_id) |s| g.free(@constCast(s));
        g.free(self.retail_id);
        for (self.id) |s| g.free(@constCast(s));
        g.free(self.id);
    }

    pub fn deinitConst(self: *const GetMsgResult) void {
        const g = self.gpa;
        for (self.fail_info) |*f| f.deinitConst();
        g.free(self.fail_info);
        if (self.fail_info_url) |s| g.free(s);
        if (self.content) |s| g.free(s);
        if (self.appid) |s| g.free(s);
        if (self.path) |s| g.free(s);
        g.free(self.role_id);
        for (self.retail_id) |s| g.free(s);
        g.free(self.retail_id);
        for (self.id) |s| g.free(s);
        g.free(self.id);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetMsgClickDataResponse.Dimonsion`
/// (Dimonsion 为 Java 原样拼写)。gpa 拥有。
pub const MsgClickDimonsion = struct {
    gpa: std.mem.Allocator,
    click_uv: ?i64,
    click_pv: ?i64,
    msg_type: ?i64,
    msg_id: ?[]const u8,
    send_time: ?i64,

    pub fn deinit(self: *MsgClickDimonsion) void {
        const g = self.gpa;
        if (self.msg_id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const MsgClickDimonsion) void {
        const g = self.gpa;
        if (self.msg_id) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetMsgClickDataResponse`。gpa 拥有。
pub const GetMsgClickDataResult = struct {
    gpa: std.mem.Allocator,
    data_list: []MsgClickDimonsion,

    pub fn deinit(self: *GetMsgClickDataResult) void {
        const g = self.gpa;
        for (self.data_list) |*d| d.deinit();
        g.free(self.data_list);
    }

    pub fn deinitConst(self: *const GetMsgClickDataResult) void {
        const g = self.gpa;
        for (self.data_list) |*d| d.deinitConst();
        g.free(self.data_list);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetShareMaterialResponse`。gpa 拥有。
pub const GetShareMaterialResult = struct {
    gpa: std.mem.Allocator,
    share_path: ?[]const u8,
    qrcode: ?[]const u8,
    tag: ?[]const u8,

    pub fn deinit(self: *GetShareMaterialResult) void {
        const g = self.gpa;
        if (self.share_path) |s| g.free(@constCast(s));
        if (self.qrcode) |s| g.free(@constCast(s));
        if (self.tag) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const GetShareMaterialResult) void {
        const g = self.gpa;
        if (self.share_path) |s| g.free(s);
        if (self.qrcode) |s| g.free(s);
        if (self.tag) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetRelationResponse.Relation`。gpa 拥有。
pub const Relation = struct {
    gpa: std.mem.Allocator,
    promoter_openid: ?[]const u8,
    role_id: ?i64,
    retail_id: ?[]const u8,
    extra_info: ?[]const u8,
    openid: ?[]const u8,
    create_time: ?i64,
    path: ?[]const u8,
    scene: ?i64,
    share_extra_info: ?[]const u8,

    pub fn deinit(self: *Relation) void {
        const g = self.gpa;
        if (self.promoter_openid) |s| g.free(@constCast(s));
        if (self.retail_id) |s| g.free(@constCast(s));
        if (self.extra_info) |s| g.free(@constCast(s));
        if (self.openid) |s| g.free(@constCast(s));
        if (self.path) |s| g.free(@constCast(s));
        if (self.share_extra_info) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const Relation) void {
        const g = self.gpa;
        if (self.promoter_openid) |s| g.free(s);
        if (self.retail_id) |s| g.free(s);
        if (self.extra_info) |s| g.free(s);
        if (self.openid) |s| g.free(s);
        if (self.path) |s| g.free(s);
        if (self.share_extra_info) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetRelationResponse`。gpa 拥有。
pub const GetRelationResult = struct {
    gpa: std.mem.Allocator,
    relation_list: []Relation,
    total_cnt: ?i64,
    start_id: ?[]const u8,

    pub fn deinit(self: *GetRelationResult) void {
        const g = self.gpa;
        for (self.relation_list) |*r| r.deinit();
        g.free(self.relation_list);
        if (self.start_id) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const GetRelationResult) void {
        const g = self.gpa;
        for (self.relation_list) |*r| r.deinitConst();
        g.free(self.relation_list);
        if (self.start_id) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetOrderResponse.Order`。gpa 拥有。
pub const PromotionOrder = struct {
    gpa: std.mem.Allocator,
    promoter_openid: ?[]const u8,
    role_id: ?i64,
    retail_id: ?[]const u8,
    extra_info: ?[]const u8,
    openid: ?[]const u8,
    create_time: ?i64,
    path: ?[]const u8,
    scene: ?i64,
    share_extra_info: ?[]const u8,
    mch_id: ?[]const u8,
    trade_no: ?[]const u8,
    out_trade_no: ?[]const u8,
    status: ?i64,
    paid_amount: ?i64,
    paid_time: ?i64,
    refunded_time: ?i64,

    pub fn deinit(self: *PromotionOrder) void {
        const g = self.gpa;
        if (self.promoter_openid) |s| g.free(@constCast(s));
        if (self.retail_id) |s| g.free(@constCast(s));
        if (self.extra_info) |s| g.free(@constCast(s));
        if (self.openid) |s| g.free(@constCast(s));
        if (self.path) |s| g.free(@constCast(s));
        if (self.share_extra_info) |s| g.free(@constCast(s));
        if (self.mch_id) |s| g.free(@constCast(s));
        if (self.trade_no) |s| g.free(@constCast(s));
        if (self.out_trade_no) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const PromotionOrder) void {
        const g = self.gpa;
        if (self.promoter_openid) |s| g.free(s);
        if (self.retail_id) |s| g.free(s);
        if (self.extra_info) |s| g.free(s);
        if (self.openid) |s| g.free(s);
        if (self.path) |s| g.free(s);
        if (self.share_extra_info) |s| g.free(s);
        if (self.mch_id) |s| g.free(s);
        if (self.trade_no) |s| g.free(s);
        if (self.out_trade_no) |s| g.free(s);
    }
};

/// 对应 `promoter.response.WxMaPromotionGetOrderResponse`。gpa 拥有。
pub const GetOrderResult = struct {
    gpa: std.mem.Allocator,
    order_list: []PromotionOrder,
    total_cnt: ?i64,
    start_id: ?i64,

    pub fn deinit(self: *GetOrderResult) void {
        const g = self.gpa;
        for (self.order_list) |*o| o.deinit();
        g.free(self.order_list);
    }

    pub fn deinitConst(self: *const GetOrderResult) void {
        const g = self.gpa;
        for (self.order_list) |*o| o.deinitConst();
        g.free(self.order_list);
    }
};

// --- 响应解析 -------------------------------------------------------------------

fn parseRole(gpa: std.mem.Allocator, obj: std.json.Value) !Role {
    var r = Role{ .gpa = gpa, .role_id = null, .name = null, .desc = null };
    errdefer r.deinit();
    r.role_id = json_util.getInt(obj, "role_id");
    if (json_util.getStr(obj, "name")) |s| r.name = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "desc")) |s| r.desc = try gpa.dupe(u8, s);
    return r;
}

fn parseAddPromoterFail(gpa: std.mem.Allocator, obj: std.json.Value) !AddPromoterFail {
    var f = AddPromoterFail{
        .gpa = gpa,
        .openid = null,
        .role_id = null,
        .retail_id = null,
        .extra_info = null,
        .name = null,
        .phone = null,
        .errcode = null,
        .errmsg = null,
    };
    errdefer f.deinit();
    if (json_util.getStr(obj, "openid")) |s| f.openid = try gpa.dupe(u8, s);
    f.role_id = json_util.getInt(obj, "role_id");
    if (json_util.getStr(obj, "retail_id")) |s| f.retail_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "extra_info")) |s| f.extra_info = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "name")) |s| f.name = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "phone")) |s| f.phone = try gpa.dupe(u8, s);
    f.errcode = json_util.getInt(obj, "errcode");
    if (json_util.getStr(obj, "errmsg")) |s| f.errmsg = try gpa.dupe(u8, s);
    return f;
}

fn parsePromoterInfo(gpa: std.mem.Allocator, obj: std.json.Value) !PromoterInfo {
    var p = PromoterInfo{
        .gpa = gpa,
        .openid = null,
        .role_id = null,
        .retail_id = null,
        .extra_info = null,
        .name = null,
        .phone = null,
        .auth_status = null,
        .decl_status = null,
        .update_time = null,
        .id = null,
    };
    errdefer p.deinit();
    if (json_util.getStr(obj, "openid")) |s| p.openid = try gpa.dupe(u8, s);
    p.role_id = json_util.getInt(obj, "role_id");
    if (json_util.getStr(obj, "retail_id")) |s| p.retail_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "extra_info")) |s| p.extra_info = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "name")) |s| p.name = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "phone")) |s| p.phone = try gpa.dupe(u8, s);
    p.auth_status = json_util.getInt(obj, "auth_status");
    if (json_util.getStr(obj, "decl_status")) |s| p.decl_status = try gpa.dupe(u8, s);
    p.update_time = json_util.getInt(obj, "update_time");
    if (json_util.getStr(obj, "id")) |s| p.id = try gpa.dupe(u8, s);
    return p;
}

fn parseMsgFailInfo(gpa: std.mem.Allocator, obj: std.json.Value) !MsgFailInfo {
    var f = MsgFailInfo{ .gpa = gpa, .id = null, .errorcode = null };
    errdefer f.deinit();
    if (json_util.getStr(obj, "id")) |s| f.id = try gpa.dupe(u8, s);
    f.errorcode = json_util.getInt(obj, "errorcode");
    return f;
}

fn parseMsgClickDimonsion(gpa: std.mem.Allocator, obj: std.json.Value) !MsgClickDimonsion {
    var d = MsgClickDimonsion{
        .gpa = gpa,
        .click_uv = null,
        .click_pv = null,
        .msg_type = null,
        .msg_id = null,
        .send_time = null,
    };
    errdefer d.deinit();
    d.click_uv = json_util.getInt(obj, "click_uv");
    d.click_pv = json_util.getInt(obj, "click_pv");
    d.msg_type = json_util.getInt(obj, "msg_type");
    if (json_util.getStr(obj, "msg_id")) |s| d.msg_id = try gpa.dupe(u8, s);
    d.send_time = json_util.getInt(obj, "send_time");
    return d;
}

fn parseRelation(gpa: std.mem.Allocator, obj: std.json.Value) !Relation {
    var r = Relation{
        .gpa = gpa,
        .promoter_openid = null,
        .role_id = null,
        .retail_id = null,
        .extra_info = null,
        .openid = null,
        .create_time = null,
        .path = null,
        .scene = null,
        .share_extra_info = null,
    };
    errdefer r.deinit();
    if (json_util.getStr(obj, "promoter_openid")) |s| r.promoter_openid = try gpa.dupe(u8, s);
    r.role_id = json_util.getInt(obj, "role_id");
    if (json_util.getStr(obj, "retail_id")) |s| r.retail_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "extra_info")) |s| r.extra_info = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "openid")) |s| r.openid = try gpa.dupe(u8, s);
    r.create_time = json_util.getInt(obj, "create_time");
    if (json_util.getStr(obj, "path")) |s| r.path = try gpa.dupe(u8, s);
    r.scene = json_util.getInt(obj, "scene");
    if (json_util.getStr(obj, "share_extra_info")) |s| r.share_extra_info = try gpa.dupe(u8, s);
    return r;
}

fn parsePromotionOrder(gpa: std.mem.Allocator, obj: std.json.Value) !PromotionOrder {
    var o = PromotionOrder{
        .gpa = gpa,
        .promoter_openid = null,
        .role_id = null,
        .retail_id = null,
        .extra_info = null,
        .openid = null,
        .create_time = null,
        .path = null,
        .scene = null,
        .share_extra_info = null,
        .mch_id = null,
        .trade_no = null,
        .out_trade_no = null,
        .status = null,
        .paid_amount = null,
        .paid_time = null,
        .refunded_time = null,
    };
    errdefer o.deinit();
    if (json_util.getStr(obj, "promoter_openid")) |s| o.promoter_openid = try gpa.dupe(u8, s);
    o.role_id = json_util.getInt(obj, "role_id");
    if (json_util.getStr(obj, "retail_id")) |s| o.retail_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "extra_info")) |s| o.extra_info = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "openid")) |s| o.openid = try gpa.dupe(u8, s);
    o.create_time = json_util.getInt(obj, "create_time");
    if (json_util.getStr(obj, "path")) |s| o.path = try gpa.dupe(u8, s);
    o.scene = json_util.getInt(obj, "scene");
    if (json_util.getStr(obj, "share_extra_info")) |s| o.share_extra_info = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "mch_id")) |s| o.mch_id = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "trade_no")) |s| o.trade_no = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "out_trade_no")) |s| o.out_trade_no = try gpa.dupe(u8, s);
    o.status = json_util.getInt(obj, "status");
    o.paid_amount = json_util.getInt(obj, "paid_amount");
    o.paid_time = json_util.getInt(obj, "paid_time");
    o.refunded_time = json_util.getInt(obj, "refunded_time");
    return o;
}

fn parseGetMsgResult(gpa: std.mem.Allocator, obj: std.json.Value) !GetMsgResult {
    var out = GetMsgResult{
        .gpa = gpa,
        .send_cnt = null,
        .percent = null,
        .fail_cnt = null,
        .fail_info = &[_]MsgFailInfo{},
        .fail_info_url = null,
        .msg_type = null,
        .content = null,
        .appid = null,
        .path = null,
        .list_type = null,
        .role_id = &[_]i64{},
        .retail_id = &[_][]const u8{},
        .id = &[_][]const u8{},
    };
    errdefer out.deinit();
    out.send_cnt = json_util.getInt(obj, "send_cnt");
    out.percent = json_util.getInt(obj, "percent");
    out.fail_cnt = json_util.getInt(obj, "fail_cnt");
    if (json_util.getArray(obj, "fail_info")) |arr| {
        const list = try gpa.alloc(MsgFailInfo, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*f| f.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseMsgFailInfo(gpa, item);
            filled += 1;
        }
        out.fail_info = list;
    }
    if (json_util.getStr(obj, "fail_info_url")) |s| out.fail_info_url = try gpa.dupe(u8, s);
    out.msg_type = json_util.getInt(obj, "msg_type");
    if (json_util.getStr(obj, "content")) |s| out.content = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "appid")) |s| out.appid = try gpa.dupe(u8, s);
    if (json_util.getStr(obj, "path")) |s| out.path = try gpa.dupe(u8, s);
    out.list_type = json_util.getInt(obj, "list_type");
    if (json_util.getArray(obj, "role_id")) |arr| {
        const list = try gpa.alloc(i64, arr.items.len);
        errdefer gpa.free(list);
        for (arr.items, 0..) |item, i| list[i] = valueInt(item) orelse 0;
        out.role_id = list;
    }
    if (json_util.getArray(obj, "retail_id")) |arr| {
        const list = try gpa.alloc([]const u8, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |s| gpa.free(@constCast(s));
            gpa.free(list);
        }
        for (arr.items) |item| {
            if (valueStr(item)) |s| {
                list[filled] = try gpa.dupe(u8, s);
                filled += 1;
            }
        }
        out.retail_id = list[0..filled];
    }
    if (json_util.getArray(obj, "id")) |arr| {
        const list = try gpa.alloc([]const u8, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |s| gpa.free(@constCast(s));
            gpa.free(list);
        }
        for (arr.items) |item| {
            if (valueStr(item)) |s| {
                list[filled] = try gpa.dupe(u8, s);
                filled += 1;
            }
        }
        out.id = list[0..filled];
    }
    return out;
}

// --- service ----------------------------------------------------------------------

pub const PromotionService = struct {
    svc: *mp_service.Service,

    /// 对应 `addRole(WxMaPromotionAddRoleRequest)`:POST addrole。
    pub fn addRole(self: *PromotionService, io: std.Io, req: AddRoleRequest) WxResult(AddRoleResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, ADD_ROLE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "addrole not json", .{}) };
        defer parsed.deinit();
        var out = AddRoleResult{ .gpa = gpa, .role_id = null, .name = null, .desc = null };
        out.role_id = json_util.getInt(parsed.value, "role_id");
        if (json_util.getStr(parsed.value, "name")) |s| {
            out.name = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (json_util.getStr(parsed.value, "desc")) |s| {
            out.desc = gpa.dupe(u8, s) catch {
                if (out.name) |n| gpa.free(@constCast(n));
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        return .{ .ok = out };
    }

    /// 对应 `getRole(WxMaPromotionGetRoleRequest)`:POST getrole → role_list。
    pub fn getRole(self: *PromotionService, io: std.Io, req: GetRoleRequest) WxResult(GetRoleResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_ROLE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getrole not json", .{}) };
        defer parsed.deinit();
        var list: []Role = &[_]Role{};
        if (json_util.getArray(parsed.value, "role_list")) |arr| {
            list = gpa.alloc(Role, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseRole(gpa, item) catch {
                    for (list[0..filled]) |*r| r.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        return .{ .ok = .{
            .gpa = gpa,
            .role_list = list,
            .total_cnt = json_util.getInt(parsed.value, "total_cnt"),
        } };
    }

    /// 对应 `updateRole(WxMaPromoterUpdateRoleRequest)`:POST updaterole
    /// (响应仅 errcode/errmsg → Done)。
    pub fn updateRole(self: *PromotionService, io: std.Io, req: UpdateRoleRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_ROLE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `addPromoter(WxMaPromotionAddPromoterRequest)`:POST addpromoter
    /// → total_cnt/fail_cnt/fail_list。
    pub fn addPromoter(self: *PromotionService, io: std.Io, req: AddPromoterRequest) WxResult(AddPromoterResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, ADD_PROMOTER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "addpromoter not json", .{}) };
        defer parsed.deinit();
        var list: []AddPromoterFail = &[_]AddPromoterFail{};
        if (json_util.getArray(parsed.value, "fail_list")) |arr| {
            list = gpa.alloc(AddPromoterFail, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseAddPromoterFail(gpa, item) catch {
                    for (list[0..filled]) |*f| f.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        return .{ .ok = .{
            .gpa = gpa,
            .total_cnt = json_util.getInt(parsed.value, "total_cnt"),
            .fail_cnt = json_util.getInt(parsed.value, "fail_cnt"),
            .fail_list = list,
        } };
    }

    /// 对应 `getPromoter(WxMaPromotionGetPromoterRequest)`:POST getpromoter。
    /// 修正 Java bug:原实现 `errcode != 0 || errcode != 103006` 恒真必抛;
    /// 按意图 errcode=103006(空列表)视为成功返回空结果。
    pub fn getPromoter(self: *PromotionService, io: std.Io, req: GetPromoterRequest) WxResult(GetPromoterResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp: []u8 = switch (self.svc.post(io, GET_PROMOTER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| if (e.error_code == ERR_CODE_OF_EMPTY_LIST) blk: {
                var err = e;
                err.deinit();
                break :blk &[_]u8{};
            } else return .{ .err = e },
        };
        if (resp.len == 0) {
            return .{ .ok = .{ .gpa = gpa, .total_cnt = null, .promoter_list = &[_]PromoterInfo{} } };
        }
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getpromoter not json", .{}) };
        defer parsed.deinit();
        var list: []PromoterInfo = &[_]PromoterInfo{};
        if (json_util.getArray(parsed.value, "promoter_list")) |arr| {
            list = gpa.alloc(PromoterInfo, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parsePromoterInfo(gpa, item) catch {
                    for (list[0..filled]) |*p| p.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        // total_cnt:Java String 字段,微信可能回数字,looseStr 归一化
        const total = looseStr(gpa, parsed.value, "total_cnt") catch {
            for (list) |*p| p.deinit();
            gpa.free(list);
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        };
        return .{ .ok = .{ .gpa = gpa, .total_cnt = total, .promoter_list = list } };
    }

    /// 对应 `updatePromoter(WxMaPromotionUpdatePromoterRequest)`:POST updatepromoter
    /// (响应仅 errcode/errmsg → Done)。
    pub fn updatePromoter(self: *PromotionService, io: std.Io, req: UpdatePromoterRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, UPDATE_PROMOTER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getInvitationMaterial(WxMaPromotionGetInvitationMaterialRequest)`:
    /// POST getinvitationmaterial → poster/qrcode/tag。
    pub fn getInvitationMaterial(self: *PromotionService, io: std.Io, req: GetInvitationMaterialRequest) WxResult(GetInvitationMaterialResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_INVITATION_MATERIAL_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getinvitationmaterial not json", .{}) };
        defer parsed.deinit();
        var out = GetInvitationMaterialResult{ .gpa = gpa, .poster = null, .qrcode = null, .tag = null };
        if (json_util.getStr(parsed.value, "poster")) |s| {
            out.poster = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (json_util.getStr(parsed.value, "qrcode")) |s| {
            out.qrcode = gpa.dupe(u8, s) catch {
                if (out.poster) |p| gpa.free(@constCast(p));
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        if (json_util.getStr(parsed.value, "tag")) |s| {
            out.tag = gpa.dupe(u8, s) catch {
                if (out.poster) |p| gpa.free(@constCast(p));
                if (out.qrcode) |q| gpa.free(@constCast(q));
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        return .{ .ok = out };
    }

    /// 对应 `sendMsg(WxMaPromotionSendMsgRequest)`:POST sendmsg → msg_id。
    pub fn sendMsg(self: *PromotionService, io: std.Io, req: SendMsgRequest) WxResult(SendMsgResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SEND_MSG_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sendmsg not json", .{}) };
        defer parsed.deinit();
        var out = SendMsgResult{ .gpa = gpa, .msg_id = null };
        if (json_util.getStr(parsed.value, "msg_id")) |s| {
            out.msg_id = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out };
    }

    /// 对应 `singleSendMsg(WxMaPromotionSingleSendMsgRequest)`:POST singlesendmsg
    /// (响应仅 errcode/errmsg → Done)。
    pub fn singleSendMsg(self: *PromotionService, io: std.Io, req: SingleSendMsgRequest) Done {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SINGLE_SEND_MSG_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getMsg(WxMaPromotionGetMsgRequest)`:POST getmsg → 送达结果。
    pub fn getMsg(self: *PromotionService, io: std.Io, req: GetMsgRequest) WxResult(GetMsgResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_MSG_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getmsg not json", .{}) };
        defer parsed.deinit();
        const out = parseGetMsgResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getMsgClickData(WxMaPromotionGetMsgClickDataRequest)`:
    /// POST getmsgclickdata → data_list。
    pub fn getMsgClickData(self: *PromotionService, io: std.Io, req: GetMsgClickDataRequest) WxResult(GetMsgClickDataResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_MSG_CLICK_DATA_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getmsgclickdata not json", .{}) };
        defer parsed.deinit();
        var list: []MsgClickDimonsion = &[_]MsgClickDimonsion{};
        if (json_util.getArray(parsed.value, "data_list")) |arr| {
            list = gpa.alloc(MsgClickDimonsion, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseMsgClickDimonsion(gpa, item) catch {
                    for (list[0..filled]) |*d| d.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        return .{ .ok = .{ .gpa = gpa, .data_list = list } };
    }

    /// 对应 `getShareMaterial(WxMaPromotionGetShareMaterialRequest)`:
    /// POST getsharematerial → share_path/qrcode/tag。
    pub fn getShareMaterial(self: *PromotionService, io: std.Io, req: GetShareMaterialRequest) WxResult(GetShareMaterialResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_SHARE_MATERIAL_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getsharematerial not json", .{}) };
        defer parsed.deinit();
        var out = GetShareMaterialResult{ .gpa = gpa, .share_path = null, .qrcode = null, .tag = null };
        if (json_util.getStr(parsed.value, "share_path")) |s| {
            out.share_path = gpa.dupe(u8, s) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (json_util.getStr(parsed.value, "qrcode")) |s| {
            out.qrcode = gpa.dupe(u8, s) catch {
                if (out.share_path) |p| gpa.free(@constCast(p));
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        if (json_util.getStr(parsed.value, "tag")) |s| {
            out.tag = gpa.dupe(u8, s) catch {
                if (out.share_path) |p| gpa.free(@constCast(p));
                if (out.qrcode) |q| gpa.free(@constCast(q));
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        return .{ .ok = out };
    }

    /// 对应 `getRelation(WxMaPromotionGetRelationRequest)`:POST getrelation。
    /// 修正 Java bug(同 getPromoter):103006(空列表)视为成功返回空结果。
    pub fn getRelation(self: *PromotionService, io: std.Io, req: GetRelationRequest) WxResult(GetRelationResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp: []u8 = switch (self.svc.post(io, GET_RELATION_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| if (e.error_code == ERR_CODE_OF_EMPTY_LIST) blk: {
                var err = e;
                err.deinit();
                break :blk &[_]u8{};
            } else return .{ .err = e },
        };
        if (resp.len == 0) {
            return .{ .ok = .{ .gpa = gpa, .relation_list = &[_]Relation{}, .total_cnt = null, .start_id = null } };
        }
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getrelation not json", .{}) };
        defer parsed.deinit();
        var list: []Relation = &[_]Relation{};
        if (json_util.getArray(parsed.value, "relation_list")) |arr| {
            list = gpa.alloc(Relation, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parseRelation(gpa, item) catch {
                    for (list[0..filled]) |*r| r.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        var start_id: ?[]const u8 = null;
        if (json_util.getStr(parsed.value, "start_id")) |s| {
            start_id = gpa.dupe(u8, s) catch {
                for (list) |*r| r.deinit();
                gpa.free(list);
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            };
        }
        return .{ .ok = .{
            .gpa = gpa,
            .relation_list = list,
            .total_cnt = json_util.getInt(parsed.value, "total_cnt"),
            .start_id = start_id,
        } };
    }

    /// 对应 `getOrder(WxMaPromotionGetOrderRequest)`:POST getorder。
    /// 修正 Java bug(同 getPromoter):103006(空列表)视为成功返回空结果。
    pub fn getOrder(self: *PromotionService, io: std.Io, req: GetOrderRequest) WxResult(GetOrderResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp: []u8 = switch (self.svc.post(io, GET_ORDER_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| if (e.error_code == ERR_CODE_OF_EMPTY_LIST) blk: {
                var err = e;
                err.deinit();
                break :blk &[_]u8{};
            } else return .{ .err = e },
        };
        if (resp.len == 0) {
            return .{ .ok = .{ .gpa = gpa, .order_list = &[_]PromotionOrder{}, .total_cnt = null, .start_id = null } };
        }
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "getorder not json", .{}) };
        defer parsed.deinit();
        var list: []PromotionOrder = &[_]PromotionOrder{};
        if (json_util.getArray(parsed.value, "order_list")) |arr| {
            list = gpa.alloc(PromotionOrder, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            for (arr.items) |item| {
                list[filled] = parsePromotionOrder(gpa, item) catch {
                    for (list[0..filled]) |*o| o.deinit();
                    gpa.free(list);
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                };
                filled += 1;
            }
        }
        return .{ .ok = .{
            .gpa = gpa,
            .order_list = list,
            .total_cnt = json_util.getInt(parsed.value, "total_cnt"),
            .start_id = json_util.getInt(parsed.value, "start_id"),
        } };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "promotion roles: add/get/update" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "addrole", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"role_id\":10,\"name\":\"金牌推广员\",\"desc\":\"top\"}" },
        .{ .match = "getrole", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"role_list\":[{\"role_id\":1,\"name\":\"r1\",\"desc\":\"d1\"},{\"role_id\":2,\"name\":\"r2\"}],\"total_cnt\":2}" },
        .{ .match = "updaterole", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = PromotionService{ .svc = &base };

    // addRole:POST {name,desc}
    var added = switch (s.addRole(io, .{ .name = "金牌推广员", .desc = "top" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer added.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/addrole") != null);
    try std.testing.expectEqualStrings("{\"name\":\"金牌推广员\",\"desc\":\"top\"}", m.last_body);
    try std.testing.expectEqual(@as(i64, 10), added.role_id.?);
    try std.testing.expectEqualStrings("金牌推广员", added.name.?);
    try std.testing.expectEqualStrings("top", added.desc.?);

    // getRole:role_id 为 null → 空请求体 {};解析 role_list
    var got = switch (s.getRole(io, .{})) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getrole") != null);
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), got.role_list.len);
    try std.testing.expectEqual(@as(i64, 1), got.role_list[0].role_id.?);
    try std.testing.expectEqualStrings("d1", got.role_list[0].desc.?);
    try std.testing.expectEqual(@as(i64, 2), got.total_cnt.?);

    // updateRole:POST {role_id,name};desc 省略 → Done
    switch (s.updateRole(io, .{ .role_id = 1, .name = "n2" })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/updaterole") != null);
    try std.testing.expectEqualStrings("{\"role_id\":1,\"name\":\"n2\"}", m.last_body);
}

test "promotion promoters: add/get/update + 103006 空列表" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "addpromoter", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total_cnt\":2,\"fail_cnt\":1,\"fail_list\":[{\"openid\":\"O2\",\"role_id\":2,\"errcode\":1907,\"errmsg\":\"已存在\"}]}" },
        .{ .match = "getpromoter", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total_cnt\":\"2\",\"promoter_list\":[{\"openid\":\"O1\",\"role_id\":1,\"auth_status\":1,\"decl_status\":\"CONFIRMED\",\"update_time\":1700000000,\"id\":\"ID1\"}]}" },
        .{ .match = "updatepromoter", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = PromotionService{ .svc = &base };

    // addPromoter:嵌套 promoter_list;元素 retail_id/extra_info/name 省略
    var added = switch (s.addPromoter(io, .{ .promoter_list = &.{
        .{ .openid = "O1", .role_id = 1, .retail_id = "R1" },
        .{ .openid = "O2", .role_id = 2, .phone = "13900000000" },
    } })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer added.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/addpromoter") != null);
    try std.testing.expectEqualStrings(
        "{\"promoter_list\":[{\"openid\":\"O1\",\"role_id\":1,\"retail_id\":\"R1\"},{\"openid\":\"O2\",\"role_id\":2,\"phone\":\"13900000000\"}]}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(i64, 2), added.total_cnt.?);
    try std.testing.expectEqual(@as(i64, 1), added.fail_cnt.?);
    try std.testing.expectEqual(@as(usize, 1), added.fail_list.len);
    try std.testing.expectEqualStrings("O2", added.fail_list[0].openid.?);
    try std.testing.expectEqual(@as(i64, 1907), added.fail_list[0].errcode.?);
    try std.testing.expectEqualStrings("已存在", added.fail_list[0].errmsg.?);

    // getPromoter:total_cnt 微信回数字时 Java String 字段宽容转换,此处回字符串
    var got = switch (s.getPromoter(io, .{ .openid = "O1", .need_unionid = 1 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getpromoter") != null);
    try std.testing.expectEqualStrings("{\"openid\":\"O1\",\"need_unionid\":1}", m.last_body);
    try std.testing.expectEqualStrings("2", got.total_cnt.?);
    try std.testing.expectEqual(@as(usize, 1), got.promoter_list.len);
    try std.testing.expectEqual(@as(i64, 1), got.promoter_list[0].auth_status.?);
    try std.testing.expectEqualStrings("CONFIRMED", got.promoter_list[0].decl_status.?);
    try std.testing.expectEqualStrings("ID1", got.promoter_list[0].id.?);

    // updatePromoter:POST {id,...} → Done
    switch (s.updatePromoter(io, .{ .id = "ID1", .role_id = 2, .phone = "13800000000" })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/updatepromoter") != null);
    try std.testing.expectEqualStrings("{\"id\":\"ID1\",\"role_id\":2,\"phone\":\"13800000000\"}", m.last_body);

    // getPromoter 103006:Java 原实现必抛(Zig 修正为空列表成功)
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getpromoter", .response = "{\"errcode\":103006,\"errmsg\":\"no data\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = PromotionService{ .svc = &base2 };
    var empty = switch (s2.getPromoter(io, .{})) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.promoter_list.len);
    try std.testing.expect(empty.total_cnt == null);
}

test "promotion msgs: send/single/get/clickdata/invitation" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 注意顺序:singlesendmsg 在 sendmsg 前、getmsgclickdata 在 getmsg 前(子串包含)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "singlesendmsg", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "sendmsg", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":\"MSG1\"}" },
        .{ .match = "getmsgclickdata", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data_list\":[{\"click_uv\":10,\"click_pv\":20,\"msg_type\":1,\"msg_id\":\"MSG1\",\"send_time\":1700000001}]}" },
        .{ .match = "getmsg", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"send_cnt\":100,\"percent\":80,\"fail_cnt\":1,\"fail_info\":[{\"id\":\"ID9\",\"errorcode\":1907}],\"fail_info_url\":\"https://fail\",\"msg_type\":1,\"content\":\"c\",\"appid\":\"APP\",\"path\":\"p\",\"list_type\":1,\"role_id\":[1,2],\"retail_id\":[\"r1\"],\"id\":[\"i1\"]}" },
        .{ .match = "getinvitationmaterial", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"poster\":\"https://poster\",\"qrcode\":\"https://qr\",\"tag\":\"TAG\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = PromotionService{ .svc = &base };

    // sendMsg:list_type=1 + role_id 数组;appid 包含
    var sent = switch (s.sendMsg(io, .{
        .msg_type = 1,
        .content = "{\"title\":\"今日优惠\"}",
        .appid = "APP",
        .path = "pages/index",
        .list_type = 1,
        .role_id = &.{ 1, 2 },
    })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer sent.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/sendmsg") != null);
    try std.testing.expectEqualStrings(
        "{\"msg_type\":1,\"content\":\"{\\\"title\\\":\\\"今日优惠\\\"}\",\"appid\":\"APP\",\"path\":\"pages/index\",\"list_type\":1,\"role_id\":[1,2]}",
        m.last_body,
    );
    try std.testing.expectEqualStrings("MSG1", sent.msg_id.?);

    // singleSendMsg:openid 包含 → Done
    switch (s.singleSendMsg(io, .{ .msg_type = 1, .content = "hi", .path = "pages/x", .openid = "O1" })) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/singlesendmsg") != null);
    try std.testing.expectEqualStrings("{\"msg_type\":1,\"content\":\"hi\",\"path\":\"pages/x\",\"openid\":\"O1\"}", m.last_body);

    // getMsg:解析 fail_info 与回显数组
    var got = switch (s.getMsg(io, .{ .msg_id = "MSG1" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getmsg") != null);
    try std.testing.expectEqualStrings("{\"msg_id\":\"MSG1\"}", m.last_body);
    try std.testing.expectEqual(@as(i64, 100), got.send_cnt.?);
    try std.testing.expectEqual(@as(i64, 80), got.percent.?);
    try std.testing.expectEqual(@as(i64, 1), got.fail_cnt.?);
    try std.testing.expectEqualStrings("ID9", got.fail_info[0].id.?);
    try std.testing.expectEqual(@as(i64, 1907), got.fail_info[0].errorcode.?);
    try std.testing.expectEqualStrings("https://fail", got.fail_info_url.?);
    try std.testing.expectEqual(@as(i64, 1), got.list_type.?);
    try std.testing.expectEqual(@as(usize, 2), got.role_id.len);
    try std.testing.expectEqual(@as(i64, 2), got.role_id[1]);
    try std.testing.expectEqual(@as(usize, 1), got.retail_id.len);
    try std.testing.expectEqualStrings("r1", got.retail_id[0]);
    try std.testing.expectEqualStrings("i1", got.id[0]);

    // getMsgClickData:dimonsion(微信原样拼写)
    var clicked = switch (s.getMsgClickData(io, .{
        .send_date = "20230801",
        .dimonsion = 1,
        .msg_type = 1,
        .msg_id = "MSG1",
        .begin_send_time = 1700000000,
        .end_send_time = 1700001000,
    })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer clicked.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getmsgclickdata") != null);
    try std.testing.expectEqualStrings(
        "{\"send_date\":\"20230801\",\"dimonsion\":1,\"msg_type\":1,\"msg_id\":\"MSG1\",\"begin_send_time\":1700000000,\"end_send_time\":1700001000}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(usize, 1), clicked.data_list.len);
    try std.testing.expectEqual(@as(i64, 10), clicked.data_list[0].click_uv.?);
    try std.testing.expectEqual(@as(i64, 20), clicked.data_list[0].click_pv.?);
    try std.testing.expectEqualStrings("MSG1", clicked.data_list[0].msg_id.?);

    // getInvitationMaterial:role_id 必填,invitation_type 省略时无该键
    var mat = switch (s.getInvitationMaterial(io, .{ .role_id = 1, .invitation_type = 2 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer mat.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getinvitationmaterial") != null);
    try std.testing.expectEqualStrings("{\"role_id\":1,\"invitation_type\":2}", m.last_body);
    try std.testing.expectEqualStrings("https://poster", mat.poster.?);
    try std.testing.expectEqualStrings("https://qr", mat.qrcode.?);
    try std.testing.expectEqualStrings("TAG", mat.tag.?);
}

test "promotion data: sharematerial/relation/order + 103006" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getsharematerial", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"share_path\":\"pages/share\",\"qrcode\":\"https://qr\",\"tag\":\"TAG\"}" },
        .{ .match = "getrelation", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"relation_list\":[{\"promoter_openid\":\"PO\",\"role_id\":1,\"openid\":\"O2\",\"create_time\":1700000000,\"scene\":1,\"path\":\"p\",\"share_extra_info\":\"sei\"}],\"total_cnt\":1,\"start_id\":\"SID\"}" },
        .{ .match = "getorder", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order_list\":[{\"promoter_openid\":\"PO\",\"role_id\":1,\"retail_id\":\"R\",\"openid\":\"O2\",\"create_time\":1700000000,\"path\":\"p\",\"scene\":1,\"share_extra_info\":\"s\",\"mch_id\":\"MCH\",\"trade_no\":\"TX\",\"out_trade_no\":\"OUT\",\"status\":1,\"paid_amount\":9900,\"paid_time\":1700000100,\"refunded_time\":1700000200}],\"total_cnt\":1,\"start_id\":100}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = PromotionService{ .svc = &base };

    // getShareMaterial:extra_info/env_version 省略
    var mat = switch (s.getShareMaterial(io, .{
        .path = "pages/x",
        .openid = "O1",
        .title = "t",
        .share_type = 1,
    })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer mat.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getsharematerial") != null);
    try std.testing.expectEqualStrings("{\"path\":\"pages/x\",\"openid\":\"O1\",\"title\":\"t\",\"share_type\":1}", m.last_body);
    try std.testing.expectEqualStrings("pages/share", mat.share_path.?);
    try std.testing.expectEqualStrings("https://qr", mat.qrcode.?);
    try std.testing.expectEqualStrings("TAG", mat.tag.?);

    // getRelation:start_id 为字符串(Java String)
    var rel = switch (s.getRelation(io, .{ .openid = "O1", .scene = 1, .need_unionid = 1 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer rel.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getrelation") != null);
    try std.testing.expectEqualStrings("{\"openid\":\"O1\",\"scene\":1,\"need_unionid\":1}", m.last_body);
    try std.testing.expectEqual(@as(usize, 1), rel.relation_list.len);
    try std.testing.expectEqualStrings("PO", rel.relation_list[0].promoter_openid.?);
    try std.testing.expectEqual(@as(i64, 1), rel.total_cnt.?);
    try std.testing.expectEqualStrings("SID", rel.start_id.?);

    // getOrder:全量字段;start_id 为数字(Java Long)
    var order = switch (s.getOrder(io, .{ .openid = "O1", .status = 1, .date = 20230801 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer order.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "promoter/getorder") != null);
    try std.testing.expectEqualStrings("{\"openid\":\"O1\",\"status\":1,\"date\":20230801}", m.last_body);
    try std.testing.expectEqual(@as(usize, 1), order.order_list.len);
    const o = order.order_list[0];
    try std.testing.expectEqualStrings("MCH", o.mch_id.?);
    try std.testing.expectEqualStrings("TX", o.trade_no.?);
    try std.testing.expectEqualStrings("OUT", o.out_trade_no.?);
    try std.testing.expectEqual(@as(i64, 9900), o.paid_amount.?);
    try std.testing.expectEqual(@as(i64, 1700000200), o.refunded_time.?);
    try std.testing.expectEqual(@as(i64, 100), order.start_id.?);

    // getRelation/getOrder 103006:Java 原实现必抛(Zig 修正为空列表成功)
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "getrelation", .response = "{\"errcode\":103006,\"errmsg\":\"no data\"}" },
        .{ .match = "getorder", .response = "{\"errcode\":103006,\"errmsg\":\"no data\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = PromotionService{ .svc = &base2 };
    var empty_rel = switch (s2.getRelation(io, .{ .openid = "O1" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer empty_rel.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rel.relation_list.len);
    var empty_order = switch (s2.getOrder(io, .{ .openid = "O1" })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer empty_order.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_order.order_list.len);
}
