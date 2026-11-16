//! 临时素材服务 —— 对应 Java `api.WxMaMediaService` + `api.impl.WxMaMediaServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Media`:
//! - uploadMedia:multipart 上传(/cgi-bin/media/upload?type=TYPE),基座 http 层
//!   暂不支持 multipart,未实现(待支持后补齐,对应 Java uploadMedia);
//! - getMedia:GET /cgi-bin/media/get?media_id=,响应为二进制图片字节
//!   (Java 下载到临时文件后返回 File,此处直接返回字节,由调用方落盘,
//!   gpa 拥有,调用方 free)。非 JSON 响应按成功透传,与 get_qrcode 同模式。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const result_mod = @import("common").result;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;

const MEDIA_GET_URL = "https://api.weixin.qq.com/cgi-bin/media/get";

// --- service -------------------------------------------------------------------

pub const MediaService = struct {
    svc: *mp_service.Service,

    /// 对应 `getMedia(mediaId)`:GET /cgi-bin/media/get?media_id=。
    /// 响应为二进制图片字节(gpa 拥有,调用方 free;Java 返回下载的临时文件,
    /// 此处返回原始字节,由调用方自行写盘)。
    pub fn getMedia(self: *MediaService, io: std.Io, media_id: []const u8) WxResult([]u8) {
        return self.svc.get(io, MEDIA_GET_URL, &.{
            .{ .key = "media_id", .value = media_id },
        });
    }

    // uploadMedia(multipart)暂未实现:基座 http 层不支持 multipart/form-data,
    // 对应 Java uploadMedia(mediaType, file) → WxMediaUploadResult。
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "media getMedia: binary bytes + query param" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "media/get", .response = "\x89PNG fake media" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = MediaService{ .svc = &base };

    const data = switch (s.getMedia(io, "MEDIA123")) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer gpa.free(data);
    try std.testing.expectEqualStrings("\x89PNG fake media", data);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "media/get?media_id=MEDIA123&access_token=TOK") != null);
}
