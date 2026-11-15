//! mp 子服务聚合 B（template_msg/kefu/material/mass/datacube + media）。
//! 独立模块 mp_services_b（见 build.zig），与 mp_services_a 并行开发互不干扰。
pub const card = @import("card.zig");
pub const datacube = @import("datacube.zig");
pub const draft = @import("draft.zig");
pub const free_publish = @import("free_publish.zig");
pub const kefu = @import("kefu.zig");
pub const mass = @import("mass.zig");
pub const material = @import("material.zig");
pub const media = @import("media.zig");
pub const member_card = @import("member_card.zig");
pub const store = @import("store.zig");
pub const template_msg = @import("template_msg.zig");
pub const wifi = @import("wifi.zig");

test {
    _ = template_msg;
    _ = kefu;
    _ = material;
    _ = mass;
    _ = datacube;
    _ = media;
    _ = draft;
    _ = free_publish;
    _ = card;
    _ = member_card;
    _ = store;
    _ = wifi;
}
