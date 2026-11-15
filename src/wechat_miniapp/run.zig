//! 微信运动服务 —— 对应 Java `api.WxMaRunService` + `api.impl.WxMaRunServiceImpl`。
//!
//! 不联网:`getRunStepInfo(sessionKey, encryptedData, iv)` = AES 解密后解析
//! `stepInfoList`(对应 Java `WxMaRunStepInfo.fromJson(WxMaCryptUtils.decrypt(...))`)。
//! 返回 gpa 拥有的 step 列表(每元素含 timestamp/step),调用方逐元素 free + free 列表。
const std = @import("std");
const json_util = @import("common").json_util;
const crypt_mod = @import("crypt.zig");
const mp_service = @import("wechat_mp").service;

pub const RunStepInfo = struct {
    gpa: std.mem.Allocator,
    timestamp: i64,
    step: i64,

    pub fn deinit(self: *RunStepInfo) void {
        _ = self.gpa;
    }
};

pub const RunStepList = struct {
    gpa: std.mem.Allocator,
    items: []RunStepInfo,

    pub fn deinit(self: *RunStepList) void {
        for (self.items) |*it| it.deinit();
        self.gpa.free(@constCast(self.items));
    }
};

pub const RunService = struct {
    svc: *mp_service.Service,

    /// 对应 `getRunStepInfo(sessionKey, encryptedData, ivStr)`。
    pub fn getRunStepInfo(self: *RunService, session_key: []const u8, encrypted_data: []const u8, iv: []const u8) (crypt_mod.Error || error{BadJson})!RunStepList {
        const gpa = self.svc.gpa;
        const plain = try crypt_mod.decrypt(gpa, session_key, encrypted_data, iv);
        defer gpa.free(plain);
        const parsed = json_util.parse(gpa, plain) catch return error.BadJson;
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "stepInfoList") orelse
            return .{ .gpa = gpa, .items = &.{} };
        var out: std.ArrayList(RunStepInfo) = .empty;
        for (arr.items) |el| {
            try out.append(gpa, .{
                .gpa = gpa,
                .timestamp = json_util.getIntOr(el, "timestamp", 0),
                .step = json_util.getIntOr(el, "step", 0),
            });
        }
        return .{ .gpa = gpa, .items = try out.toOwnedSlice(gpa) };
    }
};

// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "run getRunStepInfo: decrypt + parse stepInfoList" {
    const gpa = std.testing.allocator;
    var m = mock_mod.MockExecutor.init(gpa, &.{});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = RunService{ .svc = &base };

    // 用同一 key 构造加密的 stepInfoList JSON
    const key = [_]u8{ 0x2a, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const plain = "{\"stepInfoList\":[{\"timestamp\":100,\"step\":12},{\"timestamp\":200,\"step\":34}]}";
    const pad: u8 = @intCast(16 - plain.len % 16);
    const plen = plain.len + @as(usize, pad);
    var padded_buf: [128]u8 = undefined;
    @memcpy(padded_buf[0..plain.len], plain);
    @memset(padded_buf[plain.len..plen], pad);
    var cipher: [128]u8 = undefined;
    var ectx = std.crypto.core.aes.Aes128.initEnc(key);
    try @import("common").crypt.aes_mode.cbcEncrypt(&ectx, cipher[0..plen], padded_buf[0..plen], &iv);
    const cipher_len = plen;

    const key_b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(key.len));
    defer gpa.free(key_b64);
    _ = std.base64.standard.Encoder.encode(key_b64, &key);
    const iv_b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(iv.len));
    defer gpa.free(iv_b64);
    _ = std.base64.standard.Encoder.encode(iv_b64, &iv);
    const data_b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(cipher_len));
    defer gpa.free(data_b64);
    _ = std.base64.standard.Encoder.encode(data_b64, cipher[0..cipher_len]);

    var list = s.getRunStepInfo(key_b64, data_b64, iv_b64) catch return error.BadCipher;
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(i64, 12), list.items[0].step);
    try std.testing.expectEqual(@as(i64, 34), list.items[1].step);
}
