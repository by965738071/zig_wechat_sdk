//! 统一错误模型 —— 对应 Java `me.chanjar.weixin.common.error` 包。
//!
//! Java 端：`WxError`（错误载荷）+ `WxErrorException`（受检异常）+
//! `WxRuntimeException`（运行时异常）+ 按 `WxType` 分派的错误码枚举表。
//! Zig 端没有异常机制，统一用 `result.WxResult(T)`（tagged union）携带本文件的 `WxError`。
//!
//! 所有权约定：WxError 内的 `error_msg` / `error_msg_en` / `raw` 均由
//! `allocator` 分配（拥有所有权），用毕调用 `deinit`。
const std = @import("std");

/// 对应 Java `enums/WxType`：微信各业务线，决定错误码表的翻译分派。
pub const WxType = enum {
    cp, // 企业号/企业微信
    mp, // 公众号
    mini_app, // 小程序
    open, // 开放平台/第三方平台
    pay, // 微信支付
    channel, // 视频号

    pub fn label(self: WxType) []const u8 {
        return switch (self) {
            .cp => "企业微信",
            .mp => "微信公众号",
            .mini_app => "微信小程序",
            .open => "微信开放平台",
            .pay => "微信支付",
            .channel => "微信视频号",
        };
    }
};

/// 对应 Java `error/WxError`。
///
/// `source` 标明错误来源：微信协议 errcode、网络传输、加解密、配置缺失……
/// Java 里前者走 WxErrorException、后几类走 WxRuntimeException；
/// 这里统一为 WxError + source 标签（对应 Zig 无 checked exception 的现实）。
pub const WxError = struct {
    pub const Source = enum {
        wechat_api, // 微信返回了 errcode != 0
        transport, // 网络/IO 错误（Java 中包装为 code=-1 的 WxErrorException）
        crypto, // 加解密失败（Java 中是 WxRuntimeException）
        config, // 配置缺失/非法
        internal, // 其他内部错误（对应 Java WxErrorException(String)，code=-99）
    };

    allocator: std.mem.Allocator,
    source: Source = .wechat_api,
    /// 微信 errcode；约定 transport=-1，其余内部错误=-99。
    error_code: i64 = 0,
    /// 可读描述（若能从码表翻译则优先中文，否则是 fmt 生成的消息）。拥有所有权。
    error_msg: []const u8 = "",
    /// 原始英文 errmsg（对应 Java WxError.errorMsgEn）。拥有所有权。
    error_msg_en: []const u8 = "",
    /// 原始 JSON/XML 报文，便于排障（对应 Java WxError.json）。拥有所有权。
    raw: ?[]const u8 = null,
    /// 所属业务线（影响码表翻译）。null = 未知：`transport/internal/...` 等
    /// 辅助构造路径不掌握业务线，不拿默认值冒充；`fromJson` 路径显式传入。
    /// （对齐 Java：WxError 本身也无此字段，只有子类/显式 fromJson 才带类型。）
    wx_type: ?WxType = null,

    /// 从微信 API 返回的 JSON 构造（对应 Java `WxError.fromJson(json, type)`）。
    /// 解析 errcode/errmsg，并按码表翻译成中文；原始英文存入 error_msg_en。
    /// 非 JSON 输入不报错，只保留 raw。
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8, wx_type: WxType) !WxError {
        var self = WxError{ .allocator = allocator, .wx_type = wx_type };
        self.raw = try allocator.dupe(u8, json);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return self;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self,
        };
        if (obj.get("errcode")) |c| {
            switch (c) {
                .integer => |i| self.error_code = i,
                .float => |f| self.error_code = @intFromFloat(f),
                else => {},
            }
        }
        if (obj.get("errmsg")) |m| {
            if (m == .string) self.error_msg_en = try allocator.dupe(u8, m.string);
        }
        // 码表翻译：按业务线查各自的中文码表（对齐 Java WxError.fromJson 的分派）。
        if (lookupHint(wx_type, self.error_code)) |hint| {
            self.error_msg = try allocator.dupe(u8, hint);
        } else if (self.error_msg_en.len > 0) {
            self.error_msg = try allocator.dupe(u8, self.error_msg_en);
        }
        return self;
    }

    /// 传输层错误（对应 Java 把 IOException 包装成 code=-1 的 WxErrorException）。
    /// 保留 -1 是为了与「系统繁忙」共用同一类指数退避重试路径（与 Java 行为一致）。
    pub fn transport(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) WxError {
        return initMsg(allocator, .transport, -1, fmt, args);
    }

    /// 内部错误（对应 Java WxErrorException(String)，code=-99）。
    pub fn internal(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) WxError {
        return initMsg(allocator, .internal, -99, fmt, args);
    }

    pub fn configError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) WxError {
        return initMsg(allocator, .config, -99, fmt, args);
    }

    pub fn cryptoError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) WxError {
        return initMsg(allocator, .crypto, -99, fmt, args);
    }

    fn initMsg(allocator: std.mem.Allocator, source: Source, code: i64, comptime fmt: []const u8, args: anytype) WxError {
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch return WxError{
            .allocator = allocator,
            .source = source,
            .error_code = code,
            .error_msg = "", // 置空，避免 deinit 把静态串当堆内存 free
        };
        return WxError{
            .allocator = allocator,
            .source = source,
            .error_code = code,
            .error_msg = msg,
        };
    }

    pub fn deinit(self: *WxError) void {
        const a = self.allocator;
        if (self.raw) |r| a.free(r);
        if (self.error_msg.len > 0) a.free(@constCast(self.error_msg));
        if (self.error_msg_en.len > 0) a.free(@constCast(self.error_msg_en));
        self.* = undefined;
    }
};

/// 按业务线 + errcode 查中文提示（对应 Java 各 `*ErrorMsgEnum.findMsgByCode()`）。
/// 分派与 Java `WxError.fromJson` 的 switch 一致：MP / CP / MiniApp / Open /
/// Channel 各查各自的码表；Pay 落在 `default` 分支不翻译；wx_type 为 null
/// （未知来源的辅助构造错误）也不翻译，由调用方回退到英文 errmsg。
/// 各码表按 Java 枚举「代表性」收录常用码，未收录的码返回 null。
pub fn lookupHint(wx_type: ?WxType, code: i64) ?[]const u8 {
    const t = wx_type orelse return null;
    return switch (t) {
        .mp => mp_hint(code),
        .mini_app => ma_hint(code),
        .cp => cp_hint(code),
        .open => open_hint(code),
        .channel => channel_hint(code),
        // Java WxError.fromJson 的 switch 无 Pay 分支（default 直接返回），
        // 支付业务线不做码表翻译，保持与 Java 一致。
        .pay => null,
    };
}

/// 对应 Java `error/WxMpErrorMsgEnum`（公众号）。
fn mp_hint(code: i64) ?[]const u8 {
    return switch (code) {
        -1 => "系统繁忙，此时请开发者稍候再试",
        0 => "请求成功",
        40001 => "access_token 无效或已过期，请检查 access_token 正确性（有效期 7200 秒）",
        40013 => "不合法的 appid",
        40014 => "不合法的 access_token",
        41001 => "缺少 access_token 参数",
        42001 => "access_token 超时，请检查 access_token 的有效期",
        43001 => "需要 GET 请求",
        43002 => "需要 POST 请求",
        43004 => "需要 HTTPS 请求",
        44002 => "POST 的 body 为空",
        45009 => "接口调用超过限额",
        40164 => "调用方 IP 不在白名单中",
        46003 => "菜单不存在",
        48001 => "接口未授权",
        // 逐字补齐 WxMpErrorMsgEnum 中「Java 有、骨架先前未收录」的代表性常量
        40002 => "不合法的凭证类型",
        40003 => "不合法的 OpenID ，请开发者确认 OpenID （该用户）是否已关注公众号，或是否是其他公众号的 OpenID",
        40004 => "不合法的媒体文件类型",
        40007 => "不合法的媒体文件 id",
        41002 => "缺少 appid 参数",
        42002 => "refresh_token 超时",
        44001 => "多媒体文件为空",
        45011 => "API 调用太频繁，请稍候再试",
        47001 => "解析 JSON/XML 内容错误",
        48002 => "粉丝拒收消息（粉丝在公众号选项中，关闭了 “ 接收消息 ” ）",
        50001 => "用户未授权该 api",
        50002 => "用户受限，可能是违规后接口被封禁",
        50005 => "用户未关注公众号",
        61451 => "参数错误 (invalid parameter)",
        61500 => "日期格式错误",
        else => null,
    };
}

/// 对应 Java `error/WxMaErrorMsgEnum`（小程序；该枚举不含 -1/0，故此处也不收录）。
fn ma_hint(code: i64) ?[]const u8 {
    return switch (code) {
        40001 => "access_token 无效或 AppSecret 错误",
        40002 => "不合法的凭证类型",
        40003 => "openid 不正确",
        40004 => "无效媒体文件类型",
        40007 => "无效媒体文件 ID",
        40013 => "appid不正确/不合法(避免异常字符,注意大小写)，或者不符合绑定关系要求",
        40029 => "code 无效",
        40037 => "template_id 不正确",
        41028 => "form_id 不正确，或者过期",
        41029 => "请求的参数不正确",
        41030 => "请求的参数不正确",
        42001 => "access_token 过期",
        44002 => "post 数据为空",
        45009 => "调用分钟频率受限",
        45011 => "频率限制，每个用户每分钟100次",
        45015 => "回复时间超过限制",
        45029 => "接口调用超过限额",
        45047 => "客服接口下行条数超过上限",
        45072 => "command字段取值不对",
        45080 => "下发输入状态，需要之前30秒内跟用户有过消息交互",
        45081 => "已经在输入状态，不可重复下发",
        47001 => "post 数据中参数缺失",
        47501 => "参数 activity_id 错误",
        48001 => "API 功能未授权",
        87014 => "内容含有违法违规内容",
        // 逐字补齐 WxMaErrorMsgEnum 代表性常量
        40097 => "参数错误",
        43101 => "用户拒绝接受消息，如果用户之前曾经订阅过，则表示用户取消了订阅关系",
        47003 => "模板参数不准确，可能为空或者不满足规则，errmsg会提示具体是哪个字段出错",
        47502 => "参数 target_state 错误",
        47503 => "参数 version_type 错误",
        47504 => "activity_id 过期",
        48006 => "api 禁止清零调用次数，因为清零次数达到上限",
        85001 => "微信号不存在或微信号设置为不可搜索",
        87013 => "撤回次数达到上限（每天5次，每个月 10 次）",
        else => null,
    };
}

/// 对应 Java `error/WxCpErrorMsgEnum`（企业微信）。
fn cp_hint(code: i64) ?[]const u8 {
    return switch (code) {
        -1 => "系统繁忙；服务器暂不可用，建议稍候重试。建议重试次数不超过3次。",
        0 => "请求成功；接口调用成功",
        40001 => "不合法的secret参数；secret在应用详情/通讯录管理助手可查看",
        40003 => "无效的UserID",
        40004 => "不合法的媒体文件类型；不满足系统文件要求。参考：上传的媒体文件限制",
        40013 => "不合法的CorpID；需确认CorpID是否填写正确，在 web管理端-设置 可查看",
        40014 => "不合法的access_token",
        41001 => "缺少access_token参数",
        42001 => "access_token已过期；access_token有时效性，需要重新获取一次",
        45009 => "接口调用超过限制",
        48002 => "API接口无权限调用",
        50002 => "成员不在权限范围；请检查应用或管理组的权限范围",
        60020 => "访问ip不在白名单之中；请确认访问ip是否在服务商白名单IP列表",
        301002 => "无权限操作指定的应用",
        else => null,
    };
}

/// 对应 Java `error/WxOpenErrorMsgEnum`（开放平台 / 第三方平台）。
fn open_hint(code: i64) ?[]const u8 {
    return switch (code) {
        -1 => "系统繁忙，此时请开发者稍候再试",
        0 => "请求成功",
        1003 => "POST参数非法",
        40001 => "获取 access_token 时 AppSecret 错误，或者 access_token 无效。请开发者认真比对 AppSecret  的正确性，或查看是否正在为恰当的公众号调用接口",
        40002 => "不合法的凭证类型",
        40003 => "不合法的 OpenID ，请开发者确认 OpenID （该用户）是否已关注公众号，或是否是其他公众号的 OpenID",
        40007 => "不合法的媒体文件 id",
        41001 => "缺少 access_token 参数",
        43001 => "需要 GET 请求",
        43002 => "需要 POST 请求",
        44002 => "POST 的数据包为空",
        45009 => "接口调用超过限制",
        48001 => "api 功能未授权，请确认公众号已获得该接口，可以在公众平台官网 - 开发者中心页中查看接口权限",
        50002 => "用户受限，可能是用户帐号被冻结或注销",
        61007 => "接口未授权给第三方平台",
        // 逐字补齐 WxOpenErrorMsgEnum 代表性常量
        20002 => "商品id不存在",
        40005 => "上传素材文件格式不对",
        40006 => "上传素材文件大小超出限制",
        40164 => "invalid ip, not in whitelist",
        41021 => "missing component_access_token",
        42006 => "component_access_token expired",
        43004 => "需要接收者关注",
        43101 => "用户拒绝接受消息，如果用户之前曾经订阅过，则表示用户取消了订阅关系",
        48002 => "粉丝拒收消息（粉丝在公众号选项中，关闭了 “ 接收消息 ” ）",
        50001 => "用户未授权该 api",
        else => null,
    };
}

/// 对应 Java `error/WxChannelErrorMsgEnum`（视频号小店）。
fn channel_hint(code: i64) ?[]const u8 {
    return switch (code) {
        -1 => "系统繁忙，此时请开发者稍候再试",
        0 => "请求成功",
        40001 => "获取 access_token 时 AppSecret 错误，或者 access_token 无效。请开发者认真检查 AppSecret 的正确性",
        40003 => "请检查 openid 的正确性",
        40013 => "请检查 appid 的正确性，避免异常字符，注意大小写",
        40066 => "请检查API的URL是否与文档一致",
        41001 => "缺少 access_token 参数",
        42001 => "access_token失效，需要重新获取新的access_token",
        44002 => "POST 的数据包为空",
        45011 => "命中每分钟的频率限制",
        47001 => "解析 JSON/XML 内容错误",
        48001 => "没有该接口权限",
        50001 => "请找用户获取该api授权",
        61004 => "需要登录 channels.weixin.qq.com/shop 配置IP白名单",
        61007 => "请检查第三方平台服务商检查已获取的授权集",
        10080001 => "账号已注销",
        else => null,
    };
}

test "WxError fromJson parses errcode/errmsg" {
    const gpa = std.testing.allocator;
    var e = try WxError.fromJson(gpa, "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}", .mp);
    defer e.deinit();
    try std.testing.expectEqual(@as(i64, 40001), e.error_code);
    try std.testing.expectEqualStrings("invalid credential", e.error_msg_en);
    try std.testing.expect(e.error_msg.len > 0); // 已翻译
}

test "lookupHint dispatches per WxType (Java error code enums)" {
    // mp — WxMpErrorMsgEnum
    try std.testing.expectEqualStrings("请求成功", lookupHint(.mp, 0).?);
    // mini_app — 独立的 WxMaErrorMsgEnum（与 mp 文案不同，且无 0 码）
    try std.testing.expectEqualStrings("access_token 无效或 AppSecret 错误", lookupHint(.mini_app, 40001).?);
    try std.testing.expect(lookupHint(.mini_app, 0) == null);
    // cp — WxCpErrorMsgEnum
    try std.testing.expectEqualStrings("无效的UserID", lookupHint(.cp, 40003).?);
    // open — WxOpenErrorMsgEnum
    try std.testing.expectEqualStrings("接口未授权给第三方平台", lookupHint(.open, 61007).?);
    // channel — WxChannelErrorMsgEnum
    try std.testing.expectEqualStrings("没有该接口权限", lookupHint(.channel, 48001).?);
    // pay — Java default 分支不翻译
    try std.testing.expect(lookupHint(.pay, 40001) == null);
    // wx_type 未知不翻译
    try std.testing.expect(lookupHint(null, 40001) == null);
    // 未收录的码
    try std.testing.expect(lookupHint(.mp, 999999) == null);

    // 本轮逐字补齐的代表性常量(对照各 *ErrorMsgEnum.java)
    try std.testing.expectEqualStrings("不合法的凭证类型", lookupHint(.mp, 40002).?);
    try std.testing.expectEqualStrings("不合法的媒体文件 id", lookupHint(.mp, 40007).?);
    try std.testing.expectEqualStrings("解析 JSON/XML 内容错误", lookupHint(.mp, 47001).?);
    try std.testing.expectEqualStrings("参数错误 (invalid parameter)", lookupHint(.mp, 61451).?);
    try std.testing.expectEqualStrings("activity_id 过期", lookupHint(.mini_app, 47504).?);
    try std.testing.expectEqualStrings("模板参数不准确，可能为空或者不满足规则，errmsg会提示具体是哪个字段出错", lookupHint(.mini_app, 47003).?);
    try std.testing.expectEqualStrings("商品id不存在", lookupHint(.open, 20002).?);
    try std.testing.expectEqualStrings("missing component_access_token", lookupHint(.open, 41021).?);
    try std.testing.expectEqualStrings("需要接收者关注", lookupHint(.open, 43004).?);
}

test "WxError fromJson translates per business line" {
    const gpa = std.testing.allocator;
    {
        var e = try WxError.fromJson(gpa, "{\"errcode\":40003,\"errmsg\":\"invalid userid\"}", .cp);
        defer e.deinit();
        try std.testing.expectEqualStrings("无效的UserID", e.error_msg);
        try std.testing.expectEqualStrings("invalid userid", e.error_msg_en);
    }
    {
        var e = try WxError.fromJson(gpa, "{\"errcode\":61007,\"errmsg\":\"unauthorized\"}", .open);
        defer e.deinit();
        try std.testing.expectEqualStrings("接口未授权给第三方平台", e.error_msg);
    }
    {
        var e = try WxError.fromJson(gpa, "{\"errcode\":48001,\"errmsg\":\"no permission\"}", .channel);
        defer e.deinit();
        try std.testing.expectEqualStrings("没有该接口权限", e.error_msg);
    }
    {
        var e = try WxError.fromJson(gpa, "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}", .pay);
        defer e.deinit();
        // Java default 分支：无码表翻译，回退英文 errmsg
        try std.testing.expectEqualStrings("invalid credential", e.error_msg);
    }
}
