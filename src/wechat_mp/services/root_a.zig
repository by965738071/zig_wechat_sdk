//! mp 子服务聚合 A（menu/user_tag/qrcode/oauth/jssdk + 参考实现 user）。
//! 独立模块 mp_services_a（见 build.zig），与 mp_services_b 并行开发互不干扰。
pub const ai_open = @import("ai_open.zig");
pub const comment = @import("comment.zig");
pub const device = @import("device.zig");
pub const guide = @import("guide.zig");
pub const guide_buyer = @import("guide_buyer.zig");
pub const guide_massed_job = @import("guide_massed_job.zig");
pub const guide_material = @import("guide_material.zig");
pub const guide_tag = @import("guide_tag.zig");
pub const imgproc = @import("imgproc.zig");
pub const invoice = @import("invoice.zig");
pub const jssdk = @import("jssdk.zig");
pub const kf_session = @import("kf_session.zig");
pub const marketing = @import("marketing.zig");
pub const menu = @import("menu.zig");
pub const oauth = @import("oauth.zig");
pub const ocr = @import("ocr.zig");
pub const qrcode = @import("qrcode.zig");
pub const reimburse = @import("reimburse.zig");
pub const shake = @import("shake.zig");
pub const subscribe_msg = @import("subscribe_msg.zig");
pub const user = @import("user.zig");
pub const user_blacklist = @import("user_blacklist.zig");
pub const user_tag = @import("user_tag.zig");

test {
    _ = user;
    _ = menu;
    _ = user_tag;
    _ = qrcode;
    _ = oauth;
    _ = jssdk;
    _ = kf_session;
    _ = subscribe_msg;
    _ = comment;
    _ = user_blacklist;
    _ = guide;
    _ = guide_buyer;
    _ = guide_tag;
    _ = guide_massed_job;
    _ = invoice;
    _ = reimburse;
    _ = ai_open;
    _ = device;
    _ = guide_material;
    _ = marketing;
    _ = shake;
    _ = imgproc;
    _ = ocr;
}
