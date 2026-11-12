//! mp 子服务聚合 B（template_msg/kefu/material/mass/datacube + media）。
//! 独立模块 mp_services_b（见 build.zig），与 mp_services_a 并行开发互不干扰。
pub const datacube = @import("datacube.zig");
pub const kefu = @import("kefu.zig");
pub const mass = @import("mass.zig");
pub const material = @import("material.zig");
pub const media = @import("media.zig");
pub const template_msg = @import("template_msg.zig");

test {
    _ = template_msg;
    _ = kefu;
    _ = material;
    _ = mass;
    _ = datacube;
    _ = media;
}
