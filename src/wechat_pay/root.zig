//! 微信支付模块入口 —— 对应 Java `weixin-java-pay`。
pub const config = @import("config.zig");
pub const sign = @import("sign.zig");
pub const crypt = @import("crypt.zig");
pub const service = @import("service.zig");
pub const mtls = @import("mtls.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = config;
    _ = sign;
    _ = crypt;
    _ = service;
    _ = mtls;
}
