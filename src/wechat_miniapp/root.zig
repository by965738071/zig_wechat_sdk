//! 小程序模块入口 —— 对应 Java `weixin-java-miniapp`。
pub const config = @import("config.zig");
pub const crypt = @import("crypt.zig");
pub const service = @import("service.zig");
pub const subscribe_msg = @import("subscribe_msg.zig");
pub const qrcode = @import("qrcode.zig");
pub const link = @import("link.zig");
pub const uniform_msg = @import("uniform_msg.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = config;
    _ = crypt;
    _ = service;
    _ = subscribe_msg;
    _ = qrcode;
    _ = link;
    _ = uniform_msg;
}
