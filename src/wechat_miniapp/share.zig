//! 分享服务 —— 对应 Java `api.WxMaShareService` + `api.impl.WxMaShareServiceImpl`。
//!
//! 不联网:`getShareInfo` / `getGroupEnterInfo` 均 = AES 解密后本地解析
//! (对应 Java `WxMaShareInfo.fromJson(WxMaCryptUtils.decrypt(...))`)。
const std = @import("std");
const json_util = @import("common").json_util;
const crypt_mod = @import("crypt.zig");
const mp_service = @import("wechat_mp").service;

/// 对应 `WxMaShareInfo`(openGId)。gpa 拥有。
pub const ShareInfo = struct {
    gpa: std.mem.Allocator,
    open_gid: []const u8,

    pub fn deinit(self: *ShareInfo) void {
        self.gpa.free(@constCast(self.open_gid));
    }
};

/// 对应 `WxMaGroupEnterInfo`(opengid/open_single_roomid/group_openid/chat_type)。
pub const GroupEnterInfo = struct {
    gpa: std.mem.Allocator,
    opengid: []const u8,
    open_single_roomid: []const u8,
    group_openid: []const u8,
    chat_type: ?i64,

    pub fn deinit(self: *GroupEnterInfo) void {
        self.gpa.free(@constCast(self.opengid));
        self.gpa.free(@constCast(self.open_single_roomid));
        self.gpa.free(@constCast(self.group_openid));
    }
};

pub const ShareService = struct {
    svc: *mp_service.Service,

    /// 对应 `getShareInfo(sessionKey, encryptedData, ivStr)`。
    pub fn getShareInfo(self: *ShareService, session_key: []const u8, encrypted_data: []const u8, iv: []const u8) (crypt_mod.Error || error{BadJson})!ShareInfo {
        const gpa = self.svc.gpa;
        const plain = try crypt_mod.decrypt(gpa, session_key, encrypted_data, iv);
        defer gpa.free(plain);
        const parsed = json_util.parse(gpa, plain) catch return error.BadJson;
        defer parsed.deinit();
        const obj = json_util.object(parsed.value) orelse return error.BadJson;
        const open_gid = try gpa.dupe(u8, json_util.getStr(.{ .object = obj }, "openGId") orelse "");
        return .{ .gpa = gpa, .open_gid = open_gid };
    }

    /// 对应 `getGroupEnterInfo(sessionKey, encryptedData, ivStr)`。
    pub fn getGroupEnterInfo(self: *ShareService, session_key: []const u8, encrypted_data: []const u8, iv: []const u8) (crypt_mod.Error || error{BadJson})!GroupEnterInfo {
        const gpa = self.svc.gpa;
        const plain = try crypt_mod.decrypt(gpa, session_key, encrypted_data, iv);
        defer gpa.free(plain);
        const parsed = json_util.parse(gpa, plain) catch return error.BadJson;
        defer parsed.deinit();
        const v = parsed.value;
        const out = GroupEnterInfo{
            .gpa = gpa,
            .opengid = try gpa.dupe(u8, json_util.getStr(v, "opengid") orelse ""),
            .open_single_roomid = try gpa.dupe(u8, json_util.getStr(v, "open_single_roomid") orelse ""),
            .group_openid = try gpa.dupe(u8, json_util.getStr(v, "group_openid") orelse ""),
            .chat_type = json_util.getInt(v, "chat_type"),
        };
        errdefer out.deinit();
        return out;
    }
};

// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

fn enc(gpa: std.mem.Allocator, plain: []const u8, key: *const [16]u8, iv: *const [16]u8) ![]u8 {
    const pad: u8 = @intCast(16 - plain.len % 16);
    const plen = plain.len + @as(usize, pad);
    const padded = try gpa.alloc(u8, plen);
    defer gpa.free(padded);
    @memcpy(padded[0..plain.len], plain);
    @memset(padded[plain.len..], pad);
    const cipher = try gpa.alloc(u8, plen);
    var ectx = std.crypto.core.aes.Aes128.initEnc(key.*);
    try @import("common").crypt.aes_mode.cbcEncrypt(&ectx, cipher, padded, iv);
    return cipher;
}

fn b64enc(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

test "share getShareInfo + getGroupEnterInfo: decrypt + parse" {
    const gpa = std.testing.allocator;
    var m = mock_mod.MockExecutor.init(gpa, &.{});
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ShareService{ .svc = &base };

    const key = [_]u8{ 0x2a, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };

    const cipher1 = enc(gpa, "{\"openGId\":\"gid1\"}", &key, &iv) catch return error.oom;
    defer gpa.free(cipher1);
    const kb = b64enc(gpa, &key) catch return error.oom;
    defer gpa.free(kb);
    const ib = b64enc(gpa, &iv) catch return error.oom;
    defer gpa.free(ib);
    const db = b64enc(gpa, cipher1) catch return error.oom;
    defer gpa.free(db);
    var si = s.getShareInfo(kb, db, ib) catch return error.BadCipher;
    defer si.deinit();
    try std.testing.expectEqualStrings("gid1", si.open_gid);

    const cipher2 = enc(gpa, "{\"opengid\":\"g1\",\"open_single_roomid\":\"r1\",\"group_openid\":\"go\",\"chat_type\":2}", &key, &iv) catch return error.oom;
    defer gpa.free(cipher2);
    const db2 = b64enc(gpa, cipher2) catch return error.oom;
    defer gpa.free(db2);
    var gi = s.getGroupEnterInfo(kb, db2, ib) catch return error.BadCipher;
    defer gi.deinit();
    try std.testing.expectEqualStrings("g1", gi.opengid);
    try std.testing.expectEqualStrings("go", gi.group_openid);
    try std.testing.expectEqual(@as(?i64, 2), gi.chat_type);
}
