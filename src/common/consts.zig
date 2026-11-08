//! 公共常量 —— 对应 Java `api/WxConsts`。
//!
//! 收录骨架需要的常量：token 失效码、收发消息类型、事件类型、菜单按钮类型等。
//! 注意微信事件名的大小写不对称（subscribe 小写、CLICK 大写），与 Java 保持一致。
const std = @import("std");

/// 触发 access_token 强制刷新的错误码（对应 `WxConsts.ACCESS_TOKEN_ERROR_CODES`）。
pub const ACCESS_TOKEN_ERROR_CODES = [_]i64{ 40001, 40014, 42001 };

pub fn isAccessTokenError(code: i64) bool {
    for (ACCESS_TOKEN_ERROR_CODES) |c| if (c == code) return true;
    return false;
}

/// 「系统繁忙」错误码：走指数退避重试（对应 Java 的重试逻辑）。
pub const SYSTEM_BUSY_CODE: i64 = -1;

/// 收发消息的 MsgType（对应 `XmlMsgType`）。
pub const XmlMsgType = struct {
    pub const text = "text";
    pub const image = "image";
    pub const voice = "voice";
    pub const shortvideo = "shortvideo";
    pub const video = "video";
    pub const news = "news";
    pub const music = "music";
    pub const location = "location";
    pub const link = "link";
    pub const event = "event";
    pub const device_text = "device_text";
    pub const device_event = "device_event";
    pub const device_status = "device_status";
    pub const hardware = "hardware";
};

/// 事件类型（对应 `EventType`；注意大小写与微信文档一致）。
pub const EventType = struct {
    pub const subscribe = "subscribe";
    pub const unsubscribe = "unsubscribe";
    pub const SCAN = "SCAN";
    pub const LOCATION = "LOCATION";
    pub const CLICK = "CLICK";
    pub const VIEW = "VIEW";
    pub const MASSSENDJOBFINISH = "MASSSENDJOBFINISH";
    pub const template_send_job_finish = "template_send_job_finish";
};

/// 客服消息类型（对应 `KefuMsgType`）。
pub const KefuMsgType = struct {
    pub const text = "text";
    pub const image = "image";
    pub const voice = "voice";
    pub const video = "video";
    pub const music = "music";
    pub const news = "news";
    pub const mpnews = "mpnews";
    pub const markdown = "markdown";
    pub const file = "file";
    pub const textcard = "textcard";
    pub const wxcard = "wxcard";
    pub const transfer_customer_service = "transfer_customer_service";
    pub const miniprogrampage = "miniprogrampage";
};

/// 群发消息类型（对应 `MassMsgType`）。
pub const MassMsgType = struct {
    pub const mpnews = "mpnews";
    pub const text = "text";
    pub const voice = "voice";
    pub const image = "image";
    pub const images = "images";
    pub const mpvideo = "mpvideo";
};

/// 菜单按钮类型（对应 `MenuButtonType`）。
pub const MenuButtonType = struct {
    pub const click = "click";
    pub const view = "view";
    pub const miniprogram = "miniprogram";
    pub const scancode_push = "scancode_push";
    pub const scancode_waitmsg = "scancode_waitmsg";
    pub const pic_sysphoto = "pic_sysphoto";
    pub const pic_photo_or_album = "pic_photo_or_album";
    pub const pic_weixin = "pic_weixin";
    pub const location_select = "location_select";
    pub const media_id = "media_id";
    pub const view_limited = "view_limited";
};

/// 多媒体文件类型（对应 `MediaFileType`）。
pub const MediaFileType = struct {
    pub const image = "image";
    pub const voice = "voice";
    pub const video = "video";
    pub const thumb = "thumb";
    pub const file = "file";
};

/// OAuth2 作用域（对应 `OAuth2Scope`）。
pub const OAuth2Scope = struct {
    pub const snsapi_base = "snsapi_base";
    pub const snsapi_userinfo = "snsapi_userinfo";
    pub const snsapi_privateinfo = "snsapi_privateinfo";
};

/// access_token / ticket 提前过期余量（秒）。
/// 对应各 ConfigStorage `updateAccessToken` 里预留的 200s。
pub const TOKEN_EXPIRE_SLACK_SECONDS: i64 = 200;

/// token 刷新 tryLock 轮询间隔（毫秒）与总预算（毫秒），对应
/// BaseWxMpServiceImpl.getAccessToken 的 tryLock(100ms) + 3s 总超时。
pub const TOKEN_LOCK_POLL_MS: u64 = 100;
pub const TOKEN_LOCK_BUDGET_MS: u64 = 3_000;

/// 重试默认参数（对应 retrySleepMillis=1000，maxRetryTimes=5）。
pub const DEFAULT_RETRY_SLEEP_MS: i64 = 1_000;
pub const DEFAULT_MAX_RETRY_TIMES: u32 = 5;

test "constants sanity" {
    try std.testing.expect(isAccessTokenError(42001));
    try std.testing.expect(!isAccessTokenError(-1));
}
