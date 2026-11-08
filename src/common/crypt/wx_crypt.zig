//! 消息加解密 —— 对应 Java `util/crypto/WxCryptUtil`（公众号/企业号/开放平台加密消息）。
//!
//! 协议与 Java 实现逐条对齐：
//! - 密钥：`base64decode(EncodingAESKey + "=")` → 32 字节；AES-256-CBC，iv 取密钥前 16 字节；
//! - 明文包：`random16 || u32be(xml_len) || xml || appid`，再按自定义 PKCS7（block=32）填充；
//! - 签名：`SHA1(字典序排序(token, timestamp, nonce, encrypt) 直接拼接)` 小写 hex；
//! - 出站密文 xml 格式与 Java `generateXml` 完全一致。
//!
//! 这是骨架中**完整实现**的公共方法之一（加解密是所有后端都复用的底座）。
const std = @import("std");
const aes_mode = @import("aes_mode.zig");
const pkcs7 = @import("pkcs7.zig");
const sha1 = @import("sha1.zig");
const random = @import("../random.zig");
const xml = @import("../xml.zig");

pub const Error = error{
    InvalidAesKey, // EncodingAESKey 非法（长度/解码失败）
    InvalidRandomStr, // 随机串必须 16 字节
    EncryptFailed,
    DecryptFailed, // base64/长度/解密后结构非法
    SignatureMismatch, // 消息签名校验失败
    AppidMismatch, // 包内 appid 与配置不一致
    InvalidEncryptXml, // 提取不到 <Encrypt>
} || std.mem.Allocator.Error;

pub const WxCrypt = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// 平台上开发者配置的 token
    token: []u8,
    /// 公众号 appid / 企业号 corpid
    appid: []u8,
    /// EncodingAESKey base64 解码后的 32 字节密钥
    aes_key: [32]u8,

    /// 对应 Java 构造函数（token, encodingAesKey, appidOrCorpid）。
    pub fn init(gpa: std.mem.Allocator, io: std.Io, token: []const u8, encoding_aes_key: []const u8, appid: []const u8) Error!WxCrypt {
        const key_b64 = std.mem.trim(u8, encoding_aes_key, " \t\r\n");
        if (key_b64.len != 43) return error.InvalidAesKey;
        var b: [44]u8 = undefined;
        @memcpy(b[0..43], key_b64);
        b[43] = '=';
        var key: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(&key, &b) catch return error.InvalidAesKey;

        const tok = try gpa.dupe(u8, token);
        errdefer gpa.free(tok);
        const app = try gpa.dupe(u8, appid);
        errdefer gpa.free(app);
        return .{ .gpa = gpa, .io = io, .token = tok, .appid = app, .aes_key = key };
    }

    pub fn deinit(self: *WxCrypt) void {
        self.gpa.free(self.token);
        self.gpa.free(self.appid);
    }

    /// URL 校验（GET echostr 明文路径），对应 `checkSignature(timestamp, nonce, signature)`。
    pub fn checkUrlSignature(self: *const WxCrypt, timestamp: []const u8, nonce: []const u8, signature: []const u8) !bool {
        return sha1.checkSignature(self.gpa, self.token, timestamp, nonce, signature);
    }

    /// 加密并 base64（对应 `encrypt(randomStr, plainText)`）。返回 gpa 分配的 base64 串，调用方释放。
    pub fn encrypt(self: *const WxCrypt, random_str: []const u8, plain_text: []const u8) Error![]u8 {
        if (random_str.len != 16) return error.InvalidRandomStr;
        const total = 16 + 4 + plain_text.len + self.appid.len;
        const pad = pkcs7.padLen(total); // 1..32，总长补齐到 32 的倍数
        const buf = try self.gpa.alloc(u8, total + pad);
        errdefer self.gpa.free(buf);

        // random16 || u32be(len) || xml || appid || pad*
        @memcpy(buf[0..16], random_str);
        std.mem.writeInt(u32, buf[16..20], @intCast(plain_text.len), .big);
        @memcpy(buf[20..][0..plain_text.len], plain_text);
        @memcpy(buf[20 + plain_text.len ..][0..self.appid.len], self.appid);
        @memset(buf[total..], @intCast(pad));

        var ectx = std.crypto.core.aes.Aes256.initEnc(self.aes_key);
        const iv: [16]u8 = self.aes_key[0..16].*;
        aes_mode.cbcEncrypt(&ectx, buf, buf, &iv) catch return error.EncryptFailed; // 原地加密

        const b64 = try self.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(buf.len));
        errdefer self.gpa.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, buf);
        self.gpa.free(buf);
        return b64;
    }

    /// 加密待回复消息并生成签名（对应 `encryptContext(plainText)`）。
    /// 随机串/时间戳依赖 io，返回推断错误集。
    pub fn encryptMessage(self: *const WxCrypt, plain_text: []const u8) !EncryptContext {
        var rs: [16]u8 = undefined;
        try random.randomStr(self.io, &rs);
        const cipher = try self.encrypt(&rs, plain_text);
        errdefer self.gpa.free(cipher);

        var nonce: [16]u8 = undefined;
        try random.randomStr(self.io, &nonce);
        const nonce_str: []const u8 = &nonce;

        const secs = @divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, @as(i96, std.time.ns_per_s));
        const timestamp = try std.fmt.allocPrint(self.gpa, "{d}", .{secs});
        errdefer self.gpa.free(timestamp);

        const signature = try sha1.gen(self.gpa, &.{ self.token, timestamp, nonce_str, cipher });
        errdefer self.gpa.free(signature);

        return .{
            .encrypt = cipher,
            .msg_signature = signature,
            .timestamp = timestamp,
            .nonce = try self.gpa.dupe(u8, nonce_str),
        };
    }

    /// 验签 + 解密（对应 `decrypt(msgSignature, timeStamp, nonce, cipherText)`）。
    pub fn decryptContent(
        self: *const WxCrypt,
        msg_signature: []const u8,
        timestamp: []const u8,
        nonce: []const u8,
        cipher_b64: []const u8,
    ) Error![]u8 {
        const expect = try sha1.gen(self.gpa, &.{ self.token, timestamp, nonce, cipher_b64 });
        defer self.gpa.free(expect);
        if (!std.mem.eql(u8, expect, msg_signature)) return error.SignatureMismatch;
        return self.decryptImpl(cipher_b64);
    }

    /// 仅解密不验签（对应 `decrypt(base64Encrypted)`）。
    pub fn decrypt(self: *const WxCrypt, cipher_b64: []const u8) Error![]u8 {
        return self.decryptImpl(cipher_b64);
    }

    /// 从回调 xml 提取 `<Encrypt>` 后验签解密（对应 `decryptXml`）。
    pub fn decryptXml(
        self: *const WxCrypt,
        msg_signature: []const u8,
        timestamp: []const u8,
        nonce: []const u8,
        encrypted_xml: []const u8,
    ) Error![]u8 {
        const cipher = xml.extractTag(self.gpa, encrypted_xml, "Encrypt") orelse return error.InvalidEncryptXml;
        return self.decryptContent(msg_signature, timestamp, nonce, std.mem.trim(u8, cipher, " \t\r\n"));
    }

    /// 解密核心：base64 → AES-CBC → PKCS7 去填充 → 校验长度/appid → 返回 xml 原文副本。
    fn decryptImpl(self: *const WxCrypt, cipher_b64: []const u8) Error![]u8 {
        const n = std.base64.standard.Decoder.calcSizeForSlice(cipher_b64) catch return error.DecryptFailed;
        if (n < 32 or n % 16 != 0) return error.DecryptFailed;
        const buf = try self.gpa.alloc(u8, n);
        defer self.gpa.free(buf);
        std.base64.standard.Decoder.decode(buf, cipher_b64) catch return error.DecryptFailed;

        var dctx = std.crypto.core.aes.Aes256.initDec(self.aes_key);
        const iv: [16]u8 = self.aes_key[0..16].*;
        aes_mode.cbcDecrypt(&dctx, buf, buf, &iv) catch return error.DecryptFailed; // 原地解密

        const plain = pkcs7.decode(buf);
        if (plain.len < 20) return error.DecryptFailed;
        const msg_len = std.mem.readInt(u32, plain[16..20], .big);
        if (@as(usize, msg_len) + 20 > plain.len) return error.DecryptFailed;
        const appid = plain[20 + msg_len ..];
        if (!std.mem.eql(u8, appid, self.appid)) return error.AppidMismatch;
        return self.gpa.dupe(u8, plain[20..][0..msg_len]);
    }
};

/// 出站加密消息值对象（对应 Java `EncryptContext`）。字段均 gpa 分配。
pub const EncryptContext = struct {
    encrypt: []u8,
    msg_signature: []u8,
    timestamp: []u8,
    nonce: []u8,

    pub fn deinit(self: *EncryptContext, gpa: std.mem.Allocator) void {
        gpa.free(self.encrypt);
        gpa.free(self.msg_signature);
        gpa.free(self.timestamp);
        gpa.free(self.nonce);
    }

    /// 打包为可直接回复微信服务器的 xml（与 Java `generateXml` 逐字节一致）。
    pub fn toXml(self: *const EncryptContext, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "<xml>\n<Encrypt><![CDATA[{s}]]></Encrypt>\n<MsgSignature><![CDATA[{s}]]></MsgSignature>\n<TimeStamp>{s}</TimeStamp>\n<Nonce><![CDATA[{s}]]></Nonce>\n</xml>",
            .{ self.encrypt, self.msg_signature, self.timestamp, self.nonce },
        );
    }
};

// ---------------------------------------------------------------------------
// 测试向量取自 Java `WxCryptUtilTest`，保证协议逐字节兼容。
// ---------------------------------------------------------------------------

const k_aes_key = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFE";
const k_token = "pamtest";
const k_appid = "wxb11529c136998cb6";

fn crypt(comptime appid: []const u8) !struct { c: WxCrypt, t: std.Io.Threaded } {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    errdefer t.deinit();
    const c = try WxCrypt.init(std.testing.allocator, t.io(), k_token, k_aes_key, appid);
    return .{ .c = c, .t = t };
}

test "wx_crypt aes vector matches java testAesEncrypt" {
    const gpa = std.testing.allocator;
    var wrapped = try crypt(k_appid);
    defer wrapped.t.deinit();
    defer wrapped.c.deinit();

    const got = try wrapped.c.encrypt("aaaabbbbccccdddd", "我是中文abcd123");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "jn1L23DB+6ELqJ+6bruv21Y6MD7KeIfP82D6gU39rmkgczbWwt5+3bnyg5K55bgVtVzd832WzZGMhkP72vVOfg==",
        got,
    );
}

test "wx_crypt aes vector 2 (xml reply)" {
    const gpa = std.testing.allocator;
    var wrapped = try crypt(k_appid);
    defer wrapped.t.deinit();
    defer wrapped.c.deinit();

    const reply2 = "<xml><ToUserName><![CDATA[oia2Tj我是中文jewbmiOUlr6X-1crbLOvLw]]></ToUserName><FromUserName><![CDATA[gh_7f083739789a]]></FromUserName><CreateTime>1407743423</CreateTime><MsgType><![CDATA[video]]></MsgType><Video><MediaId><![CDATA[eYJ1MbwPRJtOvIEabaxHs7TX2D-HV71s79GUxqdUkjm6Gs2Ed1KF3ulAOA9H1xG0]]></MediaId><Title><![CDATA[testCallBackReplyVideo]]></Title><Description><![CDATA[testCallBackReplyVideo]]></Description></Video></xml>";
    const got = try wrapped.c.encrypt("aaaabbbbccccdddd", reply2);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "jn1L23DB+6ELqJ+6bruv23M2GmYfkv0xBh2h+XTBOKVKcgDFHle6gqcZ1cZrk3e1qjPQ1F4RsLWzQRG9udbKWesxlkupqcEcW7ZQweImX9+wLMa0GaUzpkycA8+IamDBxn5loLgZpnS7fVAbExOkK5DYHBmv5tptA9tklE/fTIILHR8HLXa5nQvFb3tYPKAlHF3rtTeayNf0QuM+UW/wM9enGIDIJHF7CLHiDNAYxr+r+OrJCmPQyTy8cVWlu9iSvOHPT/77bZqJucQHQ04sq7KZI27OcqpQNSto2OdHCoTccjggX5Z9Mma0nMJBU+jLKJ38YB1fBIz+vBzsYjrTmFQ44YfeEuZ+xRTQwr92vhA9OxchWVINGC50qE/6lmkwWTwGX9wtQpsJKhP+oS7rvTY8+VdzETdfakjkwQ5/Xka042OlUb1/slTwo4RscuQ+RdxSGvDahxAJ6+EAjLt9d8igHngxIbf6YyqqROxuxqIeIch3CssH/LqRs+iAcILvApYZckqmA7FNERspKA5f8GoJ9sv8xmGvZ9Yrf57cExWtnX8aCMMaBropU/1k+hKP5LVdzbWCG0hGwx/dQudYR/eXp3P0XxjlFiy+9DMlaFExWUZQDajPkdPrEeOwofJb",
        got,
    );
}

test "wx_crypt roundtrip: encryptMessage → toXml → decryptXml" {
    const gpa = std.testing.allocator;
    var wrapped = try crypt(k_appid);
    defer wrapped.t.deinit();
    defer wrapped.c.deinit();

    const reply = "我是中文abcd123";
    var ctx = try wrapped.c.encryptMessage(reply);
    defer ctx.deinit(gpa);

    // 出站 xml 可被再次解析（结构完整性）
    const out_xml = try ctx.toXml(gpa);
    defer gpa.free(out_xml);
    try std.testing.expect(std.mem.startsWith(u8, out_xml, "<xml>\n<Encrypt><![CDATA["));

    // 模拟微信下发的回调消息 xml
    const msg_xml = try std.fmt.allocPrint(
        gpa,
        "<xml><ToUserName><![CDATA[toUser]]></ToUserName><Encrypt><![CDATA[{s}]]></Encrypt></xml>",
        .{ctx.encrypt},
    );
    defer gpa.free(msg_xml);

    const plain = try wrapped.c.decryptXml(ctx.msg_signature, ctx.timestamp, ctx.nonce, msg_xml);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(reply, plain);
}

test "wx_crypt wrong signature and wrong appid" {
    const gpa = std.testing.allocator;
    var wrapped = try crypt(k_appid);
    defer wrapped.t.deinit();
    defer wrapped.c.deinit();

    const cipher = try wrapped.c.encrypt("aaaabbbbccccdddd", "hello");
    defer gpa.free(cipher);

    const sig = try sha1.gen(gpa, &.{ k_token, "1409304348", "xxxxxx", cipher });
    defer gpa.free(sig);

    // 错误签名 → SignatureMismatch
    try std.testing.expectError(error.SignatureMismatch, wrapped.c.decryptContent("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", "1409304348", "xxxxxx", cipher));

    // 相同密文、不同 appid → AppidMismatch（对齐 Java 校验 appid 归属）
    var other = try crypt("wxb11529c136998cb7");
    defer other.t.deinit();
    defer other.c.deinit();
    try std.testing.expectError(error.AppidMismatch, other.c.decryptContent(sig, "1409304348", "xxxxxx", cipher));
}

test "wx_crypt decrypt without signature" {
    const gpa = std.testing.allocator;
    var wrapped = try crypt(k_appid);
    defer wrapped.t.deinit();
    defer wrapped.c.deinit();

    const cipher = try wrapped.c.encrypt("aaaabbbbccccdddd", "plain-text-中文");
    defer gpa.free(cipher);
    const plain = try wrapped.c.decrypt(cipher);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("plain-text-中文", plain);
}
