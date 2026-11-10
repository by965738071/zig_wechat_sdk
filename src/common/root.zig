//! 公共底座模块入口 —— 对应 Java `weixin-java-common`。
//!
//! build.zig 以模块名 `common` 注入各业务模块，业务模块统一使用
//! `@import("common").<name>` 访问，不再使用相对路径。
//! 注意: Java 的 `WxError` 因 `error` 是 Zig 关键字，导出名用 `error_util`。
const std = @import("std");

pub const error_util = @import("error.zig");
pub const result = @import("result.zig");
pub const consts = @import("consts.zig");
pub const json_util = @import("json_util.zig");
pub const xml = @import("xml.zig");
pub const token = @import("token.zig");
pub const lock = @import("lock.zig");
pub const random = @import("random.zig");
pub const duplicate = @import("duplicate.zig");
pub const session = @import("session.zig");
pub const redis_ops = @import("redis_ops.zig");
pub const credentials = @import("credentials.zig");

/// 加密与签名族（对应 Java `me.chanjar.weixin.common.util.crypto/sign` 包）。
pub const crypt = struct {
    pub const aes_mode = @import("crypt/aes_mode.zig");
    pub const pkcs7 = @import("crypt/pkcs7.zig");
    pub const sha1 = @import("crypt/sha1.zig");
    pub const sign = @import("crypt/sign.zig");
    pub const wx_crypt = @import("crypt/wx_crypt.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    // crypt 是嵌套 struct,refAllDecls(@This()) 不递归进其内部声明,
    // 故 crypt/*.zig 的离线测试此前从未进入测试图。这里顶层显式引用,
    // 把这 10 个测试挂进图(不改变 pub const crypt 的 API 形状)。
    _ = @import("crypt/aes_mode.zig");
    _ = @import("crypt/wx_crypt.zig");
    _ = @import("crypt/sha1.zig");
    _ = @import("crypt/sign.zig");
    _ = @import("crypt/pkcs7.zig");
    _ = @import("credentials.zig");
}
