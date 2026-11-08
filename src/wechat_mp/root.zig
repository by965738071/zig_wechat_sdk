//! 公众号模块入口 —— 对应 Java `weixin-java-mp` 的 `me.chanjar.weixin.mp` 包。
//! 子服务在 services/ 目录，按 A/B 两组聚合（services/root_a|root_b.zig），便于并行开发。
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const service = @import("service.zig");
pub const router = @import("router.zig");
pub const mp = @import("mp.zig");
pub const services_a = @import("services/root_a.zig");
pub const services_b = @import("services/root_b.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = config;
    _ = http;
    _ = service;
    _ = router;
    _ = mp;
    _ = services_a;
    _ = services_b;
}
