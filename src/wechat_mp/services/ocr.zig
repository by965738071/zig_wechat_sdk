//! 公众号 OCR 识别 —— 逐字对齐 Java `api.WxMpOcrService` +
//! `api.impl.WxMpOcrServiceImpl`,端点常量取自 `api_url.zig:Ocr`
//! (镜像 Java `enums.WxMpApiUrl.Ocr`,14 个常量,URL 变体带 `%s` 模板)。
//!
//! Java 接口 7 组方法(名称逐字对齐,impl:24-182;每组有 String img_url 与
//! File imgFile 两个重载):
//!   idCard / bankCard / driving / drivingLicense / bizLicense / comm / menu
//!   URL 变体:URLEncoder.encode(imgUrl, UTF-8) → String.format(...?img_url=%s)
//!             → mainService.post(url, null)(**空请求体 POST**)
//!             → bean.fromJson(result)
//!   文件变体:XFile(filename, content) —— OcrDiscernRequestExecutor:
//!     POST multipart/form-data 字段名 **file**(Apache addBinaryBody("file",file),
//!     RFC6532 模式),URL 无 query(对应 FILEIDCARD/FILE_BANK_CARD/...
//!     = "cv/ocr/X" 纯路径)。Zig 组包复用 `material.zig#buildMultipartBody`
//!     (field_name="file"),Content-Type 经 `Service.postWithHeaders` 发出。
//!
//! Java↔Zig 差异:
//!   - Java `post(url, null)` 的语义是"POST 但请求体为空"→ Zig 传 `""`
//!     (`Service.post(io, uri, &.{}, "")`;传 null 才是 GET);
//!   - bean 类名去 WxOcr 前缀(IdCardResult/BankCardResult/...),
//!     `CardPosition`/`CertPosition` 仅含 `pos` 一个字段 → Zig 坍缩为 `?Pos`,
//!     `WxOcrMenuResult` 与 `WxOcrCommResult` 字段完全同形 → `MenuResult = CommResult` 别名;
//!   - Java `URLEncoder.encode` 空格编码为 `+`,`service.zig:urlEncode` 同口径。
//!
//! 内存所有权:各 Result struct 持 gpa,`deinit` 释放全部字符串/条目;
//! `discern` 返回 `std.json.Parsed`,调用方 `defer parsed.deinit()`。
const std = @import("std");
const testing = std.testing;
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const random_mod = @import("common").random;
const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const material = @import("material.zig");
const h = @import("sub_util.zig");

pub const WxResult = result_mod.WxResult;
const WxError = result_mod.WxError;

fn oom(gpa: std.mem.Allocator) WxError {
    return WxError.internal(gpa, "oom", .{});
}

// ---------------------------------------------------------------------------
// 结果 bean(common/bean/ocr/*,字段名逐字对齐 @SerializedName)
// ---------------------------------------------------------------------------

/// Java `WxOcrImgSize`(w/h)。
pub const ImgSize = struct {
    w: i64 = 0,
    h: i64 = 0,
};

/// Java `WxOcrPos.Coordinate`(x/y)。
pub const Coordinate = struct {
    x: i64 = 0,
    y: i64 = 0,
};

/// Java `WxOcrPos`(left_top/right_top/right_bottom/left_bottom)。
pub const Pos = struct {
    left_top: Coordinate = .{},
    right_top: Coordinate = .{},
    right_bottom: Coordinate = .{},
    left_bottom: Coordinate = .{},
};

/// 文本条目(Java `WxOcrCommResult.Item`:text + pos;text 由 gpa 拥有)。
pub const OcrItem = struct {
    gpa: std.mem.Allocator,
    text: []u8,
    pos: Pos,

    pub fn deinit(self: *OcrItem) void {
        self.gpa.free(self.text);
        self.* = undefined;
    }
};

fn coordOf(v: json_util.Value, key: []const u8) Coordinate {
    const c = json_util.getObject(v, key) orelse return .{};
    return .{
        .x = json_util.getIntOr(c, "x", 0),
        .y = json_util.getIntOr(c, "y", 0),
    };
}

pub fn posOf(v: json_util.Value) Pos {
    return .{
        .left_top = coordOf(v, "left_top"),
        .right_top = coordOf(v, "right_top"),
        .right_bottom = coordOf(v, "right_bottom"),
        .left_bottom = coordOf(v, "left_bottom"),
    };
}

/// 读 v[key] 直接挂的 WxOcrPos(如 item 的 {"text":..,"pos":{left_top..}})。
pub fn posOfField(v: json_util.Value, key: []const u8) Pos {
    const pv = json_util.getObject(v, key) orelse return .{};
    return posOf(pv);
}

/// 读子对象 key 的 pos(Java CardPosition/CertPosition 形态:
/// v[key] = {"pos": WxOcrPos},仅含 pos 一个字段 → ?Pos)。
fn posField(v: json_util.Value, key: []const u8) ?Pos {
    const child = json_util.getObject(v, key) orelse return null;
    const pv = json_util.getObject(child, "pos") orelse return null;
    return posOf(pv);
}

fn sizeOf(v: json_util.Value) ImgSize {
    const s = json_util.getObject(v, "img_size") orelse return .{};
    return .{
        .w = json_util.getIntOr(s, "w", 0),
        .h = json_util.getIntOr(s, "h", 0),
    };
}

fn strOf(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) ![]u8 {
    return gpa.dupe(u8, json_util.getStrOr(v, key, ""));
}

/// Java `WxOcrIdCardResult`(type/name/id/addr/gender/nationality/valid_date)。
pub const IdCardResult = struct {
    gpa: std.mem.Allocator,
    /// "type" 是 Zig 关键字,逐字保留 JSON 字段名。
    type: []u8,
    name: []u8,
    id: []u8,
    addr: []u8,
    gender: []u8,
    nationality: []u8,
    valid_date: []u8,

    pub fn deinit(self: *IdCardResult) void {
        inline for (.{ "type", "name", "id", "addr", "gender", "nationality", "valid_date" }) |f| {
            self.gpa.free(@field(self, f));
        }
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !IdCardResult {
        return .{
            .gpa = gpa,
            .type = try strOf(gpa, v, "type"),
            .name = try strOf(gpa, v, "name"),
            .id = try strOf(gpa, v, "id"),
            .addr = try strOf(gpa, v, "addr"),
            .gender = try strOf(gpa, v, "gender"),
            .nationality = try strOf(gpa, v, "nationality"),
            .valid_date = try strOf(gpa, v, "valid_date"),
        };
    }
};

/// Java `WxOcrBankCardResult`(number)。
pub const BankCardResult = struct {
    gpa: std.mem.Allocator,
    number: []u8,

    pub fn deinit(self: *BankCardResult) void {
        self.gpa.free(self.number);
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !BankCardResult {
        return .{ .gpa = gpa, .number = try strOf(gpa, v, "number") };
    }
};

/// Java `WxOcrDrivingResult`(行驶证:16 个字符串字段 + 卡片正/反面位置 + 图片大小)。
pub const DrivingResult = struct {
    gpa: std.mem.Allocator,
    plate_num: []u8,
    vehicle_type: []u8,
    owner: []u8,
    addr: []u8,
    use_character: []u8,
    model: []u8,
    vin: []u8,
    engine_num: []u8,
    register_date: []u8,
    issue_date: []u8,
    plate_num_b: []u8,
    record: []u8,
    passengers_num: []u8,
    total_quality: []u8,
    prepare_quality: []u8,
    overall_size: []u8,
    /// Java `CardPosition`(仅 pos 字段)→ ?Pos。
    card_position_front: ?Pos,
    card_position_back: ?Pos,
    img_size: ImgSize,

    pub fn deinit(self: *DrivingResult) void {
        inline for (.{ "plate_num", "vehicle_type", "owner", "addr", "use_character", "model", "vin", "engine_num", "register_date", "issue_date", "plate_num_b", "record", "passengers_num", "total_quality", "prepare_quality", "overall_size" }) |f| {
            self.gpa.free(@field(self, f));
        }
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !DrivingResult {
        return .{
            .gpa = gpa,
            .plate_num = try strOf(gpa, v, "plate_num"),
            .vehicle_type = try strOf(gpa, v, "vehicle_type"),
            .owner = try strOf(gpa, v, "owner"),
            .addr = try strOf(gpa, v, "addr"),
            .use_character = try strOf(gpa, v, "use_character"),
            .model = try strOf(gpa, v, "model"),
            .vin = try strOf(gpa, v, "vin"),
            .engine_num = try strOf(gpa, v, "engine_num"),
            .register_date = try strOf(gpa, v, "register_date"),
            .issue_date = try strOf(gpa, v, "issue_date"),
            .plate_num_b = try strOf(gpa, v, "plate_num_b"),
            .record = try strOf(gpa, v, "record"),
            .passengers_num = try strOf(gpa, v, "passengers_num"),
            .total_quality = try strOf(gpa, v, "total_quality"),
            .prepare_quality = try strOf(gpa, v, "prepare_quality"),
            .overall_size = try strOf(gpa, v, "overall_size"),
            .card_position_front = posField(v, "card_position_front"),
            .card_position_back = posField(v, "card_position_back"),
            .img_size = sizeOf(v),
        };
    }
};

/// Java `WxOcrDrivingLicenseResult`(驾驶证:11 个字符串字段)。
pub const DrivingLicenseResult = struct {
    gpa: std.mem.Allocator,
    id_num: []u8,
    name: []u8,
    sex: []u8,
    nationality: []u8,
    address: []u8,
    birth_date: []u8,
    issue_date: []u8,
    car_class: []u8,
    valid_from: []u8,
    valid_to: []u8,
    official_seal: []u8,

    pub fn deinit(self: *DrivingLicenseResult) void {
        inline for (.{ "id_num", "name", "sex", "nationality", "address", "birth_date", "issue_date", "car_class", "valid_from", "valid_to", "official_seal" }) |f| {
            self.gpa.free(@field(self, f));
        }
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !DrivingLicenseResult {
        return .{
            .gpa = gpa,
            .id_num = try strOf(gpa, v, "id_num"),
            .name = try strOf(gpa, v, "name"),
            .sex = try strOf(gpa, v, "sex"),
            .nationality = try strOf(gpa, v, "nationality"),
            .address = try strOf(gpa, v, "address"),
            .birth_date = try strOf(gpa, v, "birth_date"),
            .issue_date = try strOf(gpa, v, "issue_date"),
            .car_class = try strOf(gpa, v, "car_class"),
            .valid_from = try strOf(gpa, v, "valid_from"),
            .valid_to = try strOf(gpa, v, "valid_to"),
            .official_seal = try strOf(gpa, v, "official_seal"),
        };
    }
};

/// Java `WxOcrBizLicenseResult`(营业执照:12 个字符串字段 + 证书位置 + 图片大小)。
pub const BizLicenseResult = struct {
    gpa: std.mem.Allocator,
    reg_num: []u8,
    serial: []u8,
    legal_representative: []u8,
    enterprise_name: []u8,
    type_of_organization: []u8,
    address: []u8,
    type_of_enterprise: []u8,
    business_scope: []u8,
    registered_capital: []u8,
    paid_in_capital: []u8,
    valid_period: []u8,
    registered_date: []u8,
    /// Java `CertPosition`(仅 pos 字段)→ ?Pos。
    cert_position: ?Pos,
    img_size: ImgSize,

    pub fn deinit(self: *BizLicenseResult) void {
        inline for (.{ "reg_num", "serial", "legal_representative", "enterprise_name", "type_of_organization", "address", "type_of_enterprise", "business_scope", "registered_capital", "paid_in_capital", "valid_period", "registered_date" }) |f| {
            self.gpa.free(@field(self, f));
        }
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !BizLicenseResult {
        return .{
            .gpa = gpa,
            .reg_num = try strOf(gpa, v, "reg_num"),
            .serial = try strOf(gpa, v, "serial"),
            .legal_representative = try strOf(gpa, v, "legal_representative"),
            .enterprise_name = try strOf(gpa, v, "enterprise_name"),
            .type_of_organization = try strOf(gpa, v, "type_of_organization"),
            .address = try strOf(gpa, v, "address"),
            .type_of_enterprise = try strOf(gpa, v, "type_of_enterprise"),
            .business_scope = try strOf(gpa, v, "business_scope"),
            .registered_capital = try strOf(gpa, v, "registered_capital"),
            .paid_in_capital = try strOf(gpa, v, "paid_in_capital"),
            .valid_period = try strOf(gpa, v, "valid_period"),
            .registered_date = try strOf(gpa, v, "registered_date"),
            .cert_position = posField(v, "cert_position"),
            .img_size = sizeOf(v),
        };
    }
};

/// Java `WxOcrCommResult`(通用印刷体:img_size + items[{text,pos}])。
pub const CommResult = struct {
    gpa: std.mem.Allocator,
    img_size: ImgSize,
    items: []OcrItem = &.{},

    pub fn deinit(self: *CommResult) void {
        for (self.items) |*it| it.deinit();
        if (self.items.len != 0) self.gpa.free(self.items);
        self.* = undefined;
    }

    pub fn fromJson(gpa: std.mem.Allocator, v: json_util.Value) !CommResult {
        var items: std.ArrayList(OcrItem) = .empty;
        if (json_util.getArray(v, "items")) |arr| {
            for (arr.items) |el| {
                const o = json_util.object(el) orelse continue;
                const ov = json_util.Value{ .object = o };
                try items.append(gpa, .{
                    .gpa = gpa,
                    .text = try strOf(gpa, ov, "text"),
                    .pos = posOfField(ov, "pos"),
                });
            }
        }
        return .{
            .gpa = gpa,
            .img_size = sizeOf(v),
            .items = try items.toOwnedSlice(gpa),
        };
    }
};

/// Java `WxOcrMenuResult` 与 `WxOcrCommResult` 字段完全同形(菜单识别),Zig 侧用别名。
pub const MenuResult = CommResult;

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

/// 通用识别 —— 对应 Java 各 URL 变体方法共用通路:
/// `URLEncoder.encode(imgUrl)` → `String.format(path)` → `post(url, null)`
/// (POST 空请求体)→ bean.fromJson(result)。
fn discern(self: *OcrService, io: std.Io, comptime path: []const u8, img_url: []const u8) WxResult(std.json.Parsed(json_util.Value)) {
    const gpa = self.svc.gpa;
    const enc = service_mod.urlEncode(gpa, img_url) catch
        return .{ .err = oom(gpa) };
    defer gpa.free(enc);
    const filled = h.fillPath(gpa, path, &.{enc}) catch
        return .{ .err = oom(gpa) };
    defer gpa.free(filled);
    const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, filled }) catch
        return .{ .err = oom(gpa) };
    defer gpa.free(uri);
    const resp = switch (self.svc.post(io, uri, &.{}, "")) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    defer gpa.free(resp);
    const parsed = json_util.parse(gpa, resp) catch
        return .{ .err = WxError.transport(gpa, "ocr response not json", .{}) };
    return .{ .ok = parsed };
}

pub const OcrService = struct {
    svc: *service_mod.Service,

    /// 对应 `#idCard(String)`(impl:24-34):POST cv/ocr/idcard?img_url=%s → IdCardResult。
    pub fn idCard(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(IdCardResult) {
        return discernThen(self, io, api_url.Ocr.idcard, img_url, IdCardResult);
    }

    /// 对应 `#bankCard(String)`(impl:48-58):POST cv/ocr/bankcard?img_url=%s。
    pub fn bankCard(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(BankCardResult) {
        return discernThen(self, io, api_url.Ocr.bank_card, img_url, BankCardResult);
    }

    /// 对应 `#driving(String)`(impl:72-82):POST cv/ocr/driving?img_url=%s。
    pub fn driving(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(DrivingResult) {
        return discernThen(self, io, api_url.Ocr.driving, img_url, DrivingResult);
    }

    /// 对应 `#drivingLicense(String)`(impl:96-106):POST cv/ocr/drivinglicense?img_url=%s。
    pub fn drivingLicense(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(DrivingLicenseResult) {
        return discernThen(self, io, api_url.Ocr.driving_license, img_url, DrivingLicenseResult);
    }

    /// 对应 `#bizLicense(String)`(impl:120-130):POST cv/ocr/bizlicense?img_url=%s。
    pub fn bizLicense(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(BizLicenseResult) {
        return discernThen(self, io, api_url.Ocr.biz_license, img_url, BizLicenseResult);
    }

    /// 对应 `#comm(String)`(impl:135-145):POST cv/ocr/comm?img_url=%s → CommResult。
    pub fn comm(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(CommResult) {
        return discernThen(self, io, api_url.Ocr.comm, img_url, CommResult);
    }

    /// 对应 `#menu(String)`(impl:149-159):POST cv/ocr/menu?img_url=%s → MenuResult。
    pub fn menu(self: *OcrService, io: std.Io, img_url: []const u8) WxResult(MenuResult) {
        return discernThen(self, io, api_url.Ocr.menu, img_url, MenuResult);
    }

    // ------------------ 文件变体(impl 各 File 重载) ------------------

    /// 对应 `#idCard(File)`(impl:36-41):POST multipart 字段 file → IdCardResult。
    pub fn idCardFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(IdCardResult) {
        return discernFileThen(self, io, api_url.Ocr.fileidcard, filename, content, IdCardResult);
    }

    /// 对应 `#bankCard(File)`(impl:60-65):POST multipart 字段 file → BankCardResult。
    pub fn bankCardFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(BankCardResult) {
        return discernFileThen(self, io, api_url.Ocr.file_bank_card, filename, content, BankCardResult);
    }

    /// 对应 `#driving(File)`(impl:84-89):POST multipart 字段 file → DrivingResult。
    pub fn drivingFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(DrivingResult) {
        return discernFileThen(self, io, api_url.Ocr.file_driving, filename, content, DrivingResult);
    }

    /// 对应 `#drivingLicense(File)`(impl:108-113):multipart → DrivingLicenseResult。
    pub fn drivingLicenseFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(DrivingLicenseResult) {
        return discernFileThen(self, io, api_url.Ocr.file_driving_license, filename, content, DrivingLicenseResult);
    }

    /// 对应 `#bizLicense(File)`(impl:132-137):multipart → BizLicenseResult。
    pub fn bizLicenseFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(BizLicenseResult) {
        return discernFileThen(self, io, api_url.Ocr.file_biz_license, filename, content, BizLicenseResult);
    }

    /// 对应 `#comm(File)`(impl:140-145):multipart → CommResult。
    pub fn commFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(CommResult) {
        return discernFileThen(self, io, api_url.Ocr.file_comm, filename, content, CommResult);
    }

    /// 对应 `#menu(File)`(impl:161-166):multipart → MenuResult。
    pub fn menuFile(self: *OcrService, io: std.Io, filename: []const u8, content: []const u8) WxResult(MenuResult) {
        return discernFileThen(self, io, api_url.Ocr.file_menu, filename, content, MenuResult);
    }

    /// discern → T.fromJson 的公共折叠;JSON 解析失败按 transport 上抛
    /// (与 Java fromJson 抛 WxErrorException 同口径)。
    fn discernThen(self: *OcrService, io: std.Io, comptime path: []const u8, img_url: []const u8, comptime T: type) WxResult(T) {
        const gpa = self.svc.gpa;
        const parsed = switch (discern(self, io, path, img_url)) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        defer parsed.deinit();
        return .{ .ok = T.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "ocr response parse failed", .{}) } };
    }

    /// 文件变体共用通路(对应 OcrDiscernRequestExecutor):
    /// POST multipart/form-data(字段名 file,RFC6532)→ T.fromJson。
    /// Content-Type 头经 `Service.postWithHeaders` 的 execute_with_headers 槽发出
    /// (mock 回退时忽略,离线单测照常)。
    fn discernFileThen(self: *OcrService, io: std.Io, path: []const u8, filename: []const u8, content: []const u8, comptime T: type) WxResult(T) {
        const gpa = self.svc.gpa;
        var bbuf: [24]u8 = undefined;
        random_mod.randomStr(io, &bbuf) catch |e|
            return .{ .err = WxError.transport(gpa, "boundary: {s}", .{@errorName(e)}) };
        const boundary = std.fmt.allocPrint(gpa, "WxZig{s}", .{&bbuf}) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(boundary);
        const body = material.buildMultipartBody(gpa, boundary, "file", filename, content, null) catch |e|
            return .{ .err = WxError.internal(gpa, "multipart body: {s}", .{@errorName(e)}) };
        defer gpa.free(body);
        const ct = material.multipartContentType(gpa, boundary) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(ct);
        const req_headers = [_]result_mod.Header{
            .{ .name = "Content-Type", .value = ct },
        };
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, path }) catch
            return .{ .err = oom(gpa) };
        defer gpa.free(uri);
        const resp = switch (self.svc.postWithHeaders(io, uri, &.{}, body, &req_headers)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "ocr response not json", .{}) };
        defer parsed.deinit();
        return .{ .ok = T.fromJson(gpa, parsed.value) catch
            return .{ .err = WxError.transport(gpa, "ocr response parse failed", .{}) } };
    }
};

// ---------------------------------------------------------------------------
// 契约测试:7 端点 URL/method/请求体(URL 编码)+ 各 bean 字段
// (逐字对照 WxMpApiUrl.Ocr + WxMpOcrServiceImpl)
// ---------------------------------------------------------------------------

test "Ocr 契约: 7 端点 URL/method/空请求体 + bean 字段 (WxMpApiUrl.Ocr)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cv/ocr/idcard", .response = "{\"errcode\":0,\"type\":\"Back\",\"name\":\"张三\",\"id\":\"110101199001010011\",\"addr\":\"北京市东城区\",\"gender\":\"男\",\"nationality\":\"汉\",\"valid_date\":\"2010-2030\"}" },
        .{ .match = "cv/ocr/bankcard", .response = "{\"errcode\":0,\"number\":\"6222000000000000\"}" },
        .{ .match = "cv/ocr/drivinglicense", .response = "{\"errcode\":0,\"id_num\":\"110101199001010011\",\"name\":\"张三\",\"sex\":\"男\",\"nationality\":\"中国\",\"address\":\"北京市东城区\",\"birth_date\":\"1990-01-01\",\"issue_date\":\"2015-06-01\",\"car_class\":\"C1\",\"valid_from\":\"2015-06-01\",\"valid_to\":\"2021-06-01\",\"official_seal\":\"北京市交管局\"}" },
        .{ .match = "cv/ocr/driving", .response = "{\"errcode\":0,\"plate_num\":\"京A12345\",\"vehicle_type\":\"小型轿车\",\"owner\":\"张三\",\"addr\":\"北京市东城区\",\"use_character\":\"非营运\",\"model\":\"大众\",\"vin\":\"LSV123\",\"engine_num\":\"EA888\",\"register_date\":\"2020-01-01\",\"issue_date\":\"2020-01-01\",\"plate_num_b\":\"\",\"record\":\"\",\"passengers_num\":\"5\",\"total_quality\":\"2000\",\"prepare_quality\":\"1800\",\"overall_size\":\"4600x1700x1400\",\"card_position_front\":{\"pos\":{\"left_top\":{\"x\":1,\"y\":2},\"right_top\":{\"x\":3,\"y\":2},\"right_bottom\":{\"x\":3,\"y\":4},\"left_bottom\":{\"x\":1,\"y\":4}}},\"img_size\":{\"w\":800,\"h\":600}}" },
        .{ .match = "cv/ocr/bizlicense", .response = "{\"errcode\":0,\"reg_num\":\"110000000000000\",\"serial\":\"1234\",\"legal_representative\":\"李四\",\"enterprise_name\":\"某某科技有限公司\",\"type_of_organization\":\"有限责任公司\",\"address\":\"北京市海淀区\",\"type_of_enterprise\":\"企业法人\",\"business_scope\":\"软件开发\",\"registered_capital\":\"100万元\",\"paid_in_capital\":\"100万元\",\"valid_period\":\"长期\",\"registered_date\":\"2018-05-20\",\"img_size\":{\"w\":640,\"h\":480}}" },
        .{ .match = "cv/ocr/comm", .response = "{\"errcode\":0,\"img_size\":{\"w\":300,\"h\":200},\"items\":[{\"text\":\"第一行\",\"pos\":{\"left_top\":{\"x\":5,\"y\":6}}},{\"text\":\"第二行\"}]}" },
        .{ .match = "cv/ocr/menu", .response = "{\"errcode\":0,\"img_size\":{\"w\":400,\"h\":300},\"items\":[{\"text\":\"宫保鸡丁 32元\"}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = OcrService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 传含空格/特殊字符的 URL,断言 URLEncoder.encode 形态(空格 → '+')。
    const img = "https://example.com/a b.jpg?x=1";

    var id = switch (svc.idCard(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer id.deinit();
    try std.testing.expectEqualStrings("Back", id.type);
    try std.testing.expectEqualStrings("张三", id.name);
    try std.testing.expectEqualStrings("110101199001010011", id.id);

    var bank = switch (svc.bankCard(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer bank.deinit();
    try std.testing.expectEqualStrings("6222000000000000", bank.number);

    var drv = switch (svc.driving(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer drv.deinit();
    try std.testing.expectEqualStrings("京A12345", drv.plate_num);
    try std.testing.expectEqualStrings("小型轿车", drv.vehicle_type);
    try std.testing.expectEqualStrings("大众", drv.model);
    const fp = drv.card_position_front.?;
    try std.testing.expectEqual(@as(i64, 1), fp.left_top.x);
    try std.testing.expectEqual(@as(i64, 4), fp.right_bottom.y);
    try std.testing.expect(drv.card_position_back == null);
    try std.testing.expectEqual(@as(i64, 800), drv.img_size.w);

    var lic = switch (svc.drivingLicense(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer lic.deinit();
    try std.testing.expectEqualStrings("110101199001010011", lic.id_num);
    try std.testing.expectEqualStrings("C1", lic.car_class);
    try std.testing.expectEqualStrings("北京市交管局", lic.official_seal);

    var biz = switch (svc.bizLicense(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer biz.deinit();
    try std.testing.expectEqualStrings("某某科技有限公司", biz.enterprise_name);
    try std.testing.expectEqualStrings("软件开发", biz.business_scope);
    try std.testing.expectEqual(@as(i64, 640), biz.img_size.w);

    var cm = switch (svc.comm(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer cm.deinit();
    try std.testing.expectEqual(@as(usize, 2), cm.items.len);
    try std.testing.expectEqualStrings("第一行", cm.items[0].text);
    try std.testing.expectEqual(@as(i64, 5), cm.items[0].pos.left_top.x);
    try std.testing.expectEqual(@as(i64, 6), cm.items[0].pos.left_top.y);
    try std.testing.expectEqualStrings("第二行", cm.items[1].text);
    try std.testing.expectEqual(@as(i64, 300), cm.img_size.w);
    try std.testing.expectEqual(@as(i64, 200), cm.img_size.h);

    var mu: MenuResult = switch (svc.menu(io, img)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer mu.deinit();
    try std.testing.expectEqual(@as(usize, 1), mu.items.len);
    try std.testing.expectEqualStrings("宫保鸡丁 32元", mu.items[0].text);

    // 7 次 POST;URL 形态:host + cv/ocr/X?img_url=<encoded> + access_token。
    try std.testing.expectEqual(@as(usize, 7), mock.calls);
    try std.testing.expectEqualStrings("post", mock.last_method);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "cv/ocr/menu?img_url=") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "https%3A%2F%2Fexample.com%2Fa+b.jpg%3Fx%3D1") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    try std.testing.expectEqualStrings("", mock.body());
}

test "Ocr 文件变体: 7 端点 multipart(字段名 file)+ bean 字段 (WxMpApiUrl.Ocr.File*)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cv/ocr/idcard", .response = "{\"errcode\":0,\"type\":\"Front\",\"name\":\"李四\"}" },
        .{ .match = "cv/ocr/bankcard", .response = "{\"errcode\":0,\"number\":\"6222\"}" },
        .{ .match = "cv/ocr/drivinglicense", .response = "{\"errcode\":0,\"id_num\":\"ID1\",\"name\":\"李四\",\"car_class\":\"C2\"}" },
        .{ .match = "cv/ocr/driving", .response = "{\"errcode\":0,\"plate_num\":\"京B88888\"}" },
        .{ .match = "cv/ocr/bizlicense", .response = "{\"errcode\":0,\"enterprise_name\":\"某某公司\"}" },
        .{ .match = "cv/ocr/comm", .response = "{\"errcode\":0,\"items\":[{\"text\":\"A\"}]}" },
        .{ .match = "cv/ocr/menu", .response = "{\"errcode\":0,\"items\":[{\"text\":\"B\"}]}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var svc = OcrService{ .svc = &fx.svc };
    const io = fx.threaded.io();
    const fname = "card.jpg";
    const bytes = "\x89PNG_FAKE";

    var id = switch (svc.idCardFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer id.deinit();
    try std.testing.expectEqualStrings("Front", id.type);
    try std.testing.expectEqualStrings("李四", id.name);

    var bank = switch (svc.bankCardFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer bank.deinit();
    try std.testing.expectEqualStrings("6222", bank.number);

    var lic = switch (svc.drivingLicenseFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer lic.deinit();
    try std.testing.expectEqualStrings("C2", lic.car_class);

    var drv = switch (svc.drivingFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer drv.deinit();
    try std.testing.expectEqualStrings("京B88888", drv.plate_num);

    var biz = switch (svc.bizLicenseFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer biz.deinit();
    try std.testing.expectEqualStrings("某某公司", biz.enterprise_name);

    var cm = switch (svc.commFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer cm.deinit();
    try std.testing.expectEqual(@as(usize, 1), cm.items.len);

    var mu = switch (svc.menuFile(io, fname, bytes)) {
        .ok => |r| r,
        .err => return error.Unexpected,
    };
    defer mu.deinit();
    try std.testing.expectEqualStrings("B", mu.items[0].text);

    // 7 次 POST;URL 为纯路径(无 img_url query);multipart 字段名 file。
    try std.testing.expectEqual(@as(usize, 7), mock.calls);
    try std.testing.expectEqualStrings("post", mock.last_method);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "cv/ocr/menu") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "img_url=") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    const body = mock.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"file\"; filename=\"card.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x89PNG_FAKE") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--WxZig") != null);
}
