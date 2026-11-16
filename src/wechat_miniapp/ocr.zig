//! OCR 服务 —— 对应 Java `api.impl.WxMaOcrServiceImpl`
//! (实现 `common.service.WxOcrService`)。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Ocr`(img_url 编码后拼入 URL,
//! body 为空串,与 Java post(url, null) 语义一致):
//! - idCard:POST /cv/ocr/idcard?img_url=;
//! - bankCard:POST /cv/ocr/bankcard?img_url=;
//! - driving:POST /cv/ocr/driving?img_url=;
//! - drivingLicense:POST /cv/ocr/drivinglicense?img_url=;
//! - bizLicense:POST /cv/ocr/bizlicense?img_url=;
//! - comm:POST /cv/ocr/comm?img_url=;
//! - menu:POST /cv/ocr/menu?img_url=。
//! 文件上传变体(xxx(File))依赖 multipart,基座 http 层暂不支持,未实现。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const IDCARD_URL = "https://api.weixin.qq.com/cv/ocr/idcard?img_url=";
const BANK_CARD_URL = "https://api.weixin.qq.com/cv/ocr/bankcard?img_url=";
const DRIVING_URL = "https://api.weixin.qq.com/cv/ocr/driving?img_url=";
const DRIVING_LICENSE_URL = "https://api.weixin.qq.com/cv/ocr/drivinglicense?img_url=";
const BIZ_LICENSE_URL = "https://api.weixin.qq.com/cv/ocr/bizlicense?img_url=";
const COMM_URL = "https://api.weixin.qq.com/cv/ocr/comm?img_url=";
const MENU_URL = "https://api.weixin.qq.com/cv/ocr/menu?img_url=";

// --- bean(与 imgproc.zig 各自本地定义,对应 Java common 包同一 bean) ---------

/// 对应 `common.bean.ocr.WxOcrImgSize`(w/h)。
pub const ImgSize = struct { w: i64, h: i64 };

/// 对应 `common.bean.ocr.WxOcrPos`(四角坐标)。
pub const Pos = struct {
    left_top: ?Coordinate = null,
    right_top: ?Coordinate = null,
    right_bottom: ?Coordinate = null,
    left_bottom: ?Coordinate = null,

    pub const Coordinate = struct { x: i64, y: i64 };
};

/// 对应 `common.bean.ocr.WxOcrIdCardResult`。gpa 拥有。
pub const IdCardResult = struct {
    gpa: std.mem.Allocator,
    type_: ?[]const u8,
    name: ?[]const u8,
    id: ?[]const u8,
    addr: ?[]const u8,
    gender: ?[]const u8,
    nationality: ?[]const u8,
    valid_date: ?[]const u8,

    pub fn deinit(self: *IdCardResult) void {
        const g = self.gpa;
        if (self.type_) |s| g.free(@constCast(s));
        if (self.name) |s| g.free(@constCast(s));
        if (self.id) |s| g.free(@constCast(s));
        if (self.addr) |s| g.free(@constCast(s));
        if (self.gender) |s| g.free(@constCast(s));
        if (self.nationality) |s| g.free(@constCast(s));
        if (self.valid_date) |s| g.free(@constCast(s));
    }

    pub fn deinitConst(self: *const IdCardResult) void {
        const g = self.gpa;
        if (self.type_) |s| g.free(s);
        if (self.name) |s| g.free(s);
        if (self.id) |s| g.free(s);
        if (self.addr) |s| g.free(s);
        if (self.gender) |s| g.free(s);
        if (self.nationality) |s| g.free(s);
        if (self.valid_date) |s| g.free(s);
    }
};

/// 对应 `common.bean.ocr.WxOcrBankCardResult`(number)。gpa 拥有。
pub const BankCardResult = struct {
    gpa: std.mem.Allocator,
    number: ?[]const u8,

    pub fn deinit(self: *BankCardResult) void {
        if (self.number) |s| self.gpa.free(@constCast(s));
    }

    pub fn deinitConst(self: *const BankCardResult) void {
        if (self.number) |s| self.gpa.free(s);
    }
};

/// 对应 `common.bean.ocr.WxOcrDrivingResult`。gpa 拥有。
pub const DrivingResult = struct {
    gpa: std.mem.Allocator,
    plate_num: ?[]const u8,
    vehicle_type: ?[]const u8,
    owner: ?[]const u8,
    addr: ?[]const u8,
    use_character: ?[]const u8,
    model: ?[]const u8,
    vin: ?[]const u8,
    engine_num: ?[]const u8,
    register_date: ?[]const u8,
    issue_date: ?[]const u8,
    plate_num_b: ?[]const u8,
    record: ?[]const u8,
    passengers_num: ?[]const u8,
    total_quality: ?[]const u8,
    prepare_quality: ?[]const u8,
    overall_size: ?[]const u8,
    card_position_front: ?Pos,
    card_position_back: ?Pos,
    img_size: ?ImgSize,

    pub fn deinit(self: *DrivingResult) void {
        const g = self.gpa;
        const info = @typeInfo(DrivingResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(@constCast(s));
            }
        }
    }

    pub fn deinitConst(self: *const DrivingResult) void {
        const g = self.gpa;
        const info = @typeInfo(DrivingResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(s);
            }
        }
    }
};

/// 对应 `common.bean.ocr.WxOcrDrivingLicenseResult`。gpa 拥有。
pub const DrivingLicenseResult = struct {
    gpa: std.mem.Allocator,
    id_num: ?[]const u8,
    name: ?[]const u8,
    sex: ?[]const u8,
    nationality: ?[]const u8,
    address: ?[]const u8,
    birth_date: ?[]const u8,
    issue_date: ?[]const u8,
    car_class: ?[]const u8,
    valid_from: ?[]const u8,
    valid_to: ?[]const u8,
    official_seal: ?[]const u8,

    pub fn deinit(self: *DrivingLicenseResult) void {
        const g = self.gpa;
        const info = @typeInfo(DrivingLicenseResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(@constCast(s));
            }
        }
    }

    pub fn deinitConst(self: *const DrivingLicenseResult) void {
        const g = self.gpa;
        const info = @typeInfo(DrivingLicenseResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(s);
            }
        }
    }
};

/// 对应 `common.bean.ocr.WxOcrBizLicenseResult`。gpa 拥有。
pub const BizLicenseResult = struct {
    gpa: std.mem.Allocator,
    reg_num: ?[]const u8,
    serial: ?[]const u8,
    legal_representative: ?[]const u8,
    enterprise_name: ?[]const u8,
    type_of_organization: ?[]const u8,
    address: ?[]const u8,
    type_of_enterprise: ?[]const u8,
    business_scope: ?[]const u8,
    registered_capital: ?[]const u8,
    paid_in_capital: ?[]const u8,
    valid_period: ?[]const u8,
    registered_date: ?[]const u8,
    cert_position: ?Pos,
    img_size: ?ImgSize,

    pub fn deinit(self: *BizLicenseResult) void {
        const g = self.gpa;
        const info = @typeInfo(BizLicenseResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(@constCast(s));
            }
        }
    }

    pub fn deinitConst(self: *const BizLicenseResult) void {
        const g = self.gpa;
        const info = @typeInfo(BizLicenseResult).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime ftype == ?[]const u8) {
                if (@field(self, fname)) |s| g.free(s);
            }
        }
    }
};

/// 对应 `common.bean.ocr.WxOcrCommResult`/`WxOcrMenuResult`(img_size/items)。
/// gpa 拥有。
pub const CommResult = struct {
    gpa: std.mem.Allocator,
    img_size: ?ImgSize,
    items: []Item,

    pub const Item = struct {
        text: ?[]const u8,
        pos: ?Pos,
    };

    pub fn deinit(self: *CommResult) void {
        const g = self.gpa;
        for (self.items) |*item| {
            if (item.text) |s| g.free(@constCast(s));
        }
        g.free(self.items);
    }

    pub fn deinitConst(self: *const CommResult) void {
        const g = self.gpa;
        for (self.items) |*item| {
            if (item.text) |s| g.free(s);
        }
        g.free(self.items);
    }
};

// --- service -------------------------------------------------------------------

pub const OcrService = struct {
    svc: *mp_service.Service,

    /// 对应 `idCard(imgUrl)`:POST /cv/ocr/idcard?img_url=编码后 → IdCardResult。
    pub fn idCard(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(IdCardResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, IDCARD_URL, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr idcard not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = IdCardResult{
            .gpa = gpa,
            .type_ = null,
            .name = null,
            .id = null,
            .addr = null,
            .gender = null,
            .nationality = null,
            .valid_date = null,
        };
        errdefer out.deinit();
        if (json_util.getStr(v, "type")) |s| out.type_ = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "name")) |s| out.name = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "id")) |s| out.id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "addr")) |s| out.addr = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "gender")) |s| out.gender = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "nationality")) |s| out.nationality = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(v, "valid_date")) |s| out.valid_date = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `bankCard(imgUrl)`:POST /cv/ocr/bankcard?img_url=编码后
    /// → BankCardResult{number}。
    pub fn bankCard(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(BankCardResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, BANK_CARD_URL, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr bankcard not json", .{}) };
        defer parsed.deinit();
        var out = BankCardResult{ .gpa = gpa, .number = null };
        errdefer out.deinit();
        if (json_util.getStr(parsed.value, "number")) |s| out.number = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `driving(imgUrl)`:POST /cv/ocr/driving?img_url=编码后
    /// → DrivingResult(行驶证 17 字段 + card_position_front/back + img_size)。
    pub fn driving(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(DrivingResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, DRIVING_URL, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr driving not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = DrivingResult{
            .gpa = gpa,
            .plate_num = null,
            .vehicle_type = null,
            .owner = null,
            .addr = null,
            .use_character = null,
            .model = null,
            .vin = null,
            .engine_num = null,
            .register_date = null,
            .issue_date = null,
            .plate_num_b = null,
            .record = null,
            .passengers_num = null,
            .total_quality = null,
            .prepare_quality = null,
            .overall_size = null,
            .card_position_front = null,
            .card_position_back = null,
            .img_size = null,
        };
        errdefer out.deinit();
        inline for ([_][]const u8{ "plate_num", "vehicle_type", "owner", "addr", "use_character", "model", "vin", "engine_num", "register_date", "issue_date", "plate_num_b", "record", "passengers_num", "total_quality", "prepare_quality", "overall_size" }) |fname| {
            if (json_util.getStr(v, fname)) |s| {
                @field(out, fname) = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        if (json_util.getObject(v, "card_position_front")) |obj| {
            if (json_util.getObject(obj, "pos")) |p| out.card_position_front = parsePos(p);
        }
        if (json_util.getObject(v, "card_position_back")) |obj| {
            if (json_util.getObject(obj, "pos")) |p| out.card_position_back = parsePos(p);
        }
        out.img_size = parseImgSize(v);
        return .{ .ok = out };
    }

    /// 对应 `drivingLicense(imgUrl)`:POST /cv/ocr/drivinglicense?img_url=编码后
    /// → DrivingLicenseResult(驾驶证 11 字段)。
    pub fn drivingLicense(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(DrivingLicenseResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, DRIVING_LICENSE_URL, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr drivinglicense not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = DrivingLicenseResult{
            .gpa = gpa,
            .id_num = null,
            .name = null,
            .sex = null,
            .nationality = null,
            .address = null,
            .birth_date = null,
            .issue_date = null,
            .car_class = null,
            .valid_from = null,
            .valid_to = null,
            .official_seal = null,
        };
        errdefer out.deinit();
        inline for ([_][]const u8{ "id_num", "name", "sex", "nationality", "address", "birth_date", "issue_date", "car_class", "valid_from", "valid_to", "official_seal" }) |fname| {
            if (json_util.getStr(v, fname)) |s| {
                @field(out, fname) = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        return .{ .ok = out };
    }

    /// 对应 `bizLicense(imgUrl)`:POST /cv/ocr/bizlicense?img_url=编码后
    /// → BizLicenseResult(营业执照 12 字段 + cert_position + img_size)。
    pub fn bizLicense(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(BizLicenseResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, BIZ_LICENSE_URL, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr bizlicense not json", .{}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = BizLicenseResult{
            .gpa = gpa,
            .reg_num = null,
            .serial = null,
            .legal_representative = null,
            .enterprise_name = null,
            .type_of_organization = null,
            .address = null,
            .type_of_enterprise = null,
            .business_scope = null,
            .registered_capital = null,
            .paid_in_capital = null,
            .valid_period = null,
            .registered_date = null,
            .cert_position = null,
            .img_size = null,
        };
        errdefer out.deinit();
        inline for ([_][]const u8{ "reg_num", "serial", "legal_representative", "enterprise_name", "type_of_organization", "address", "type_of_enterprise", "business_scope", "registered_capital", "paid_in_capital", "valid_period", "registered_date" }) |fname| {
            if (json_util.getStr(v, fname)) |s| {
                @field(out, fname) = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        if (json_util.getObject(v, "cert_position")) |obj| {
            if (json_util.getObject(obj, "pos")) |p| out.cert_position = parsePos(p);
        }
        out.img_size = parseImgSize(v);
        return .{ .ok = out };
    }

    /// 对应 `comm(imgUrl)`:POST /cv/ocr/comm?img_url=编码后
    /// → CommResult{img_size,items[{text,pos}]}。
    pub fn comm(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(CommResult) {
        return self.commOrMenu(io, COMM_URL, img_url, "comm");
    }

    /// 对应 `menu(imgUrl)`:POST /cv/ocr/menu?img_url=编码后
    /// → CommResult{img_size,items[{text,pos}]}。
    pub fn menu(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(CommResult) {
        return self.commOrMenu(io, MENU_URL, img_url, "menu");
    }

    // 文件上传变体(idCard(File) 等)依赖 multipart,基座 http 层暂不支持,未实现。

    // 内部:POST prefix ++ urlEncode(img_url),body 为空串(对应 Java post(url, null))。
    fn postImgUrl(self: *OcrService, io: std.Io, prefix: []const u8, img_url: []const u8) WxResult([]u8) {
        const gpa = self.svc.gpa;
        const encoded = mp_service.urlEncode(gpa, img_url) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(encoded);
        const url = std.mem.concat(gpa, u8, &.{ prefix, encoded }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(url);
        return self.svc.post(io, url, &.{}, "");
    }

    // 内部:comm/menu 共用(POST → 解析 img_size/items)。
    fn commOrMenu(self: *OcrService, io: std.Io, prefix: []const u8, img_url: []const u8, what: []const u8) WxResult(CommResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.postImgUrl(io, prefix, img_url)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr {s} not json", .{what}) };
        defer parsed.deinit();
        const v = parsed.value;
        var out = CommResult{ .gpa = gpa, .img_size = parseImgSize(v), .items = &[_]CommResult.Item{} };
        errdefer out.deinit();
        if (json_util.getArray(v, "items")) |arr| {
            const items = gpa.alloc(CommResult.Item, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*item| {
                    if (item.text) |s| gpa.free(@constCast(s));
                }
                gpa.free(items);
            }
            for (arr.items) |item| {
                var it = CommResult.Item{ .text = null, .pos = null };
                if (json_util.getStr(item, "text")) |s| it.text = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getObject(item, "pos")) |pos| it.pos = parsePos(pos);
                items[filled] = it;
                filled += 1;
            }
            out.items = items;
        }
        return .{ .ok = out };
    }
};

// 内部:解析 WxOcrImgSize。
fn parseImgSize(v: std.json.Value) ?ImgSize {
    const obj = json_util.getObject(v, "img_size") orelse return null;
    const w = json_util.getInt(obj, "w");
    const h = json_util.getInt(obj, "h");
    if (w == null or h == null) return null;
    return .{ .w = w.?, .h = h.? };
}

// 内部:解析 WxOcrPos(四角坐标,均可缺省)。
fn parsePos(pos: std.json.Value) ?Pos {
    var p = Pos{};
    var seen = false;
    if (json_util.getObject(pos, "left_top")) |c| {
        if (coord(c)) |cd| {
            p.left_top = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "right_top")) |c| {
        if (coord(c)) |cd| {
            p.right_top = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "right_bottom")) |c| {
        if (coord(c)) |cd| {
            p.right_bottom = cd;
            seen = true;
        }
    }
    if (json_util.getObject(pos, "left_bottom")) |c| {
        if (coord(c)) |cd| {
            p.left_bottom = cd;
            seen = true;
        }
    }
    return if (seen) p else null;
}

fn coord(c: std.json.Value) ?Pos.Coordinate {
    const x = json_util.getInt(c, "x");
    const y = json_util.getInt(c, "y");
    if (x == null or y == null) return null;
    return .{ .x = x.?, .y = y.? };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "ocr idCard + bankCard" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ocr/idcard", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"type\":\"IDCardFront\",\"name\":\"张三\",\"id\":\"110101199001011234\",\"addr\":\"北京市东城区\",\"gender\":\"男\",\"nationality\":\"汉\",\"valid_date\":\"20200101-20400101\"}" },
        .{ .match = "ocr/bankcard", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"number\":\"6222 0202 0000 1234\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OcrService{ .svc = &base };

    const id = switch (s.idCard(io, "https://img.example.com/id.jpg?a=1")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = id;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/idcard?img_url=https%3A%2F%2Fimg.example.com%2Fid.jpg%3Fa%3D1") != null);
    try std.testing.expectEqualStrings("", m.last_body);
    try std.testing.expectEqualStrings("张三", id.name.?);
    try std.testing.expectEqualStrings("110101199001011234", id.id.?);
    try std.testing.expectEqualStrings("男", id.gender.?);
    try std.testing.expectEqualStrings("汉", id.nationality.?);

    const bank = switch (s.bankCard(io, "https://img.example.com/bank.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = bank;
        r.deinit();
    }
    try std.testing.expectEqualStrings("6222 0202 0000 1234", bank.number.?);
}

test "ocr driving + drivingLicense + bizLicense" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ocr/drivinglicense", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"id_num\":\"110101199001011234\",\"name\":\"李四\",\"sex\":\"女\",\"nationality\":\"汉\",\"address\":\"北京市朝阳区\",\"birth_date\":\"1990-01-01\",\"issue_date\":\"2020-01-01\",\"car_class\":\"C1\",\"valid_from\":\"2020-01-01\",\"valid_to\":\"2030-01-01\",\"official_seal\":\"北京市公安局\"}" },
        .{ .match = "ocr/driving", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"plate_num\":\"京A12345\",\"vehicle_type\":\"小型轿车\",\"owner\":\"张三\",\"addr\":\"北京市\",\"use_character\":\"非营运\",\"model\":\"大众\",\"vin\":\"LFV2A21J8E4\",\"engine_num\":\"EA888\",\"register_date\":\"2020-01-01\",\"issue_date\":\"2020-01-02\",\"card_position_front\":{\"pos\":{\"left_top\":{\"x\":1,\"y\":2},\"right_top\":{\"x\":3,\"y\":2},\"right_bottom\":{\"x\":3,\"y\":4},\"left_bottom\":{\"x\":1,\"y\":4}}},\"img_size\":{\"w\":800,\"h\":600}}" },
        .{ .match = "ocr/bizlicense", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"reg_num\":\"91110000MA01\",\"serial\":\"1234567\",\"legal_representative\":\"王五\",\"enterprise_name\":\"某某科技有限公司\",\"type_of_organization\":\"有限责任公司\",\"address\":\"北京市海淀区\",\"type_of_enterprise\":\"有限责任公司\",\"business_scope\":\"技术开发\",\"registered_capital\":\"100万元\",\"paid_in_capital\":\"100万元\",\"valid_period\":\"长期\",\"registered_date\":\"2020-01-01\",\"cert_position\":{\"pos\":{\"left_top\":{\"x\":0,\"y\":0},\"right_top\":{\"x\":9,\"y\":0},\"right_bottom\":{\"x\":9,\"y\":9},\"left_bottom\":{\"x\":0,\"y\":9}}},\"img_size\":{\"w\":1024,\"h\":768}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OcrService{ .svc = &base };

    // drivingLicense(注意与 driving 匹配顺序:drivinglicense 放前面)
    const dl = switch (s.drivingLicense(io, "https://img.example.com/dl.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = dl;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/drivinglicense?img_url=") != null);
    try std.testing.expectEqualStrings("李四", dl.name.?);
    try std.testing.expectEqualStrings("C1", dl.car_class.?);
    try std.testing.expectEqualStrings("北京市公安局", dl.official_seal.?);

    // driving
    const dr = switch (s.driving(io, "https://img.example.com/dr.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = dr;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/driving?img_url=") != null);
    try std.testing.expectEqualStrings("京A12345", dr.plate_num.?);
    try std.testing.expectEqualStrings("EA888", dr.engine_num.?);
    const cp = dr.card_position_front.?;
    try std.testing.expectEqual(@as(i64, 1), cp.left_top.?.x);
    try std.testing.expectEqual(@as(i64, 800), dr.img_size.?.w);

    // bizLicense
    const biz = switch (s.bizLicense(io, "https://img.example.com/biz.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = biz;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/bizlicense?img_url=") != null);
    try std.testing.expectEqualStrings("某某科技有限公司", biz.enterprise_name.?);
    try std.testing.expectEqual(@as(i64, 9), biz.cert_position.?.right_bottom.?.x);
    try std.testing.expectEqual(@as(i64, 768), biz.img_size.?.h);
}

test "ocr comm + menu" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "ocr/comm", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"img_size\":{\"w\":300,\"h\":200},\"items\":[{\"text\":\"菜单项一\",\"pos\":{\"left_top\":{\"x\":0,\"y\":0},\"right_top\":{\"x\":50,\"y\":0},\"right_bottom\":{\"x\":50,\"y\":20},\"left_bottom\":{\"x\":0,\"y\":20}}},{\"text\":\"菜单项二\"}]}" },
        .{ .match = "ocr/menu", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"img_size\":{\"w\":100,\"h\":50},\"items\":[]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = OcrService{ .svc = &base };

    const c = switch (s.comm(io, "https://img.example.com/comm.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = c;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/comm?img_url=") != null);
    try std.testing.expectEqual(@as(i64, 300), c.img_size.?.w);
    try std.testing.expectEqual(@as(usize, 2), c.items.len);
    try std.testing.expectEqualStrings("菜单项一", c.items[0].text.?);
    try std.testing.expectEqual(@as(i64, 50), c.items[0].pos.?.right_top.?.x);
    try std.testing.expect(c.items[1].pos == null);

    const menu = switch (s.menu(io, "https://img.example.com/menu.jpg")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        var r = menu;
        r.deinit();
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "ocr/menu?img_url=") != null);
    try std.testing.expectEqual(@as(usize, 0), menu.items.len);
}
