//! 第三方平台模块入口 —— 对应 Java `weixin-java-open`。
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const message = @import("message.zig");
pub const component = @import("component.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = config;
    _ = http;
    _ = message;
    _ = component;
}
