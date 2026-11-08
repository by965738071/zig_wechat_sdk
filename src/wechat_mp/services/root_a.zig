//! mp 子服务聚合 A（menu/user_tag/qrcode/oauth/jssdk + 参考实现 user）。
//! 独立模块 mp_services_a（见 build.zig），与 mp_services_b 并行开发互不干扰。
pub const user = @import("user.zig");
pub const menu = @import("menu.zig");
pub const user_tag = @import("user_tag.zig");
pub const qrcode = @import("qrcode.zig");
pub const oauth = @import("oauth.zig");
pub const jssdk = @import("jssdk.zig");

test {
    _ = user;
    _ = menu;
    _ = user_tag;
    _ = qrcode;
    _ = oauth;
    _ = jssdk;
}
