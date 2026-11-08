//! zig_wechat_sdk 模块入口 —— 对应 Java 工程的模块划分：
//!
//! | Java 模块              | Zig 目录              | 说明                         |
//! |------------------------|-----------------------|------------------------------|
//! | weixin-java-common     | `common/`             | 公共底座（已完成）           |
//! | weixin-java-mp         | `wechat_mp/`          | 公众号                       |
//! | weixin-java-miniapp    | `wechat_miniapp/`     | 小程序                       |
//! | weixin-java-open       | `wechat_open/`        | 第三方平台（开放平台）       |
//! | weixin-java-pay        | `wechat_pay/`         | 微信支付                     |
//!
//! 骨架阶段目标：复刻 Java 的**架构设计与公共方法**，而非逐个 API。
const std = @import("std");

// ---- common：公共底座（build.zig 模块名 "common"）----
pub const error_util = @import("common").error_util;
pub const result = @import("common").result;
pub const consts = @import("common").consts;
pub const json_util = @import("common").json_util;
pub const xml = @import("common").xml;
pub const token = @import("common").token;
pub const lock = @import("common").lock;
pub const random = @import("common").random;
pub const duplicate = @import("common").duplicate;
pub const session = @import("common").session;
pub const redis_ops = @import("common").redis_ops;

pub const crypt = struct {
    pub const aes_mode = @import("common").crypt.aes_mode;
    pub const pkcs7 = @import("common").crypt.pkcs7;
    pub const sha1 = @import("common").crypt.sha1;
    pub const sign = @import("common").crypt.sign;
    pub const wx_crypt = @import("common").crypt.wx_crypt;
};

// ---- 各业务模块（build.zig 中按依赖图注入）----
pub const wechat_mp = @import("wechat_mp");
pub const mp_services_a = @import("wechat_mp").services_a;
pub const mp_services_b = @import("wechat_mp").services_b;
pub const wechat_miniapp = @import("wechat_miniapp");
pub const wechat_open = @import("wechat_open");
pub const wechat_pay = @import("wechat_pay");

test {
    @import("std").testing.refAllDecls(@This());
    // 把 common 全部文件的 test 块挂进模块测试图，`zig build test` 即可跑通。
    _ = error_util;
    _ = result;
    _ = consts;
    _ = json_util;
    _ = xml;
    _ = token;
    _ = lock;
    _ = random;
    _ = duplicate;
    _ = session;
    _ = redis_ops;
    _ = crypt.aes_mode;
    _ = crypt.pkcs7;
    _ = crypt.sha1;
    _ = crypt.sign;
    _ = crypt.wx_crypt;
    _ = wechat_mp;
    _ = mp_services_a;
    _ = mp_services_b;
    _ = wechat_miniapp;
    _ = wechat_open;
    _ = wechat_pay;
}

/// 便捷打印（沿用脚手架示例）。
pub fn printAnotherMessage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
