//! 小程序交易组件-标准版-商品服务 —— 对应 Java `api.WxMaProductService` +
//! `api.impl.WxMaProductServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Product`(Spu/Sku/OTHER 三组):
//! - OTHER:`product/category/get`、`product/brand/get`、
//!   `product/delivery/get_freight_template`、`product/img/upload`;
//! - Spu:`product/spu/add|del|get|get_list|update|listing|delisting`;
//! - Sku:`product/sku/add|batch_add|del|update|update_price`,改库存走
//!   `product/stock/update`(与 Java 常量一致,不在 sku/ 前缀下)。
//!
//! 与 Java 的差异(均已在对应位置注释):
//! - errcode≠0 已由基座折叠为 `.err`;WxMinishopResult/WxMaShopBaseResponse 的
//!   errcode/errmsg 载荷字段不再保留;
//! - `uploadImg(File…)` multipart 版未实现(基座 http 层暂不支持 multipart,
//!   同 media 模块),提供 `uploadImgUrl` 对齐 Java `uploadImg(String,Integer)`
//!   的 upload_type=1 URL 形式;
//! - `MinishopShopCat` 在 Java 中 shopCatName/fShopCatId/catLevel 三个字段未标
//!   @SerializedName,Gson 会按驼峰原名序列化,与微信实际要求的 shop_cat_name/
//!   f_cat_id/level 不符(Java 侧潜在 bug);Zig 直接对齐 API 真实命名;
//! - `minishopGoodsDelSku` 的 outProductId 在 Java 里声明为 Long(同类参数在
//!   其他方法均为 String),Zig 统一为 ?[]const u8;
//! - Java 方法名 `minishiopGoodsAddSku` 为拼写笔误,Zig 命名为 `addSku`;
//! - Java 侧多处 `respObj.get("data")` 缺失时 NPE,Zig 归一化为 null 字段。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const IMG_UPLOAD_URL = "https://api.weixin.qq.com/product/img/upload";
const GET_CATEGORY_URL = "https://api.weixin.qq.com/product/category/get";
const GET_BRAND_URL = "https://api.weixin.qq.com/product/brand/get";
const GET_FREIGHT_TEMPLATE_URL = "https://api.weixin.qq.com/product/delivery/get_freight_template";
const SPU_ADD_URL = "https://api.weixin.qq.com/product/spu/add";
const SPU_DEL_URL = "https://api.weixin.qq.com/product/spu/del";
const SPU_GET_URL = "https://api.weixin.qq.com/product/spu/get";
const SPU_GET_LIST_URL = "https://api.weixin.qq.com/product/spu/get_list";
const SPU_UPDATE_URL = "https://api.weixin.qq.com/product/spu/update";
const SPU_LISTING_URL = "https://api.weixin.qq.com/product/spu/listing";
const SPU_DELISTING_URL = "https://api.weixin.qq.com/product/spu/delisting";
const SKU_ADD_URL = "https://api.weixin.qq.com/product/sku/add";
const SKU_BATCH_ADD_URL = "https://api.weixin.qq.com/product/sku/batch_add";
const SKU_DEL_URL = "https://api.weixin.qq.com/product/sku/del";
const SKU_UPDATE_URL = "https://api.weixin.qq.com/product/sku/update";
const SKU_UPDATE_PRICE_URL = "https://api.weixin.qq.com/product/sku/update_price";
const SKU_UPDATE_STOCK_URL = "https://api.weixin.qq.com/product/stock/update";
const SKU_LIST_URL = "https://api.weixin.qq.com/product/sku/get_list";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- 解析辅助 ---------------------------------------------------------------------

/// 宽容取字符串值(接受 .string/.number_string/.integer/.float,对应 Gson 对
/// String 字段的宽松转换)。返回 gpa 拥有的副本;类型不识别返回 null。
fn looseStrValue(gpa: std.mem.Allocator, c: std.json.Value) !?[]const u8 {
    return switch (c) {
        .string => |s| try gpa.dupe(u8, s),
        .number_string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
        else => null,
    };
}

/// 宽容取对象字符串字段;缺失/类型不识别返回 null。
fn looseStr(gpa: std.mem.Allocator, v: std.json.Value, key: []const u8) !?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const c = o.get(key) orelse return null;
    return looseStrValue(gpa, c);
}

/// 字符串数组:逐元素宽容字符串化(对齐 Gson 对 List<String> 的宽松转换),
/// 元素类型不识别时归一化为 "",保证填充数与分配长度一致。
fn dupStrArray(gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value)) ![][]const u8 {
    const list = try gpa.alloc([]const u8, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |s| gpa.free(@constCast(s));
        gpa.free(list);
    }
    for (arr.items) |item| {
        list[filled] = (try looseStrValue(gpa, item)) orelse try gpa.dupe(u8, "");
        filled += 1;
    }
    return list;
}

// --- bean(Spu/Sku 族,请求/响应双向)------------------------------------------------
//
// Spu/Sku 在 Java 中既作 addSpu/updateSpu 等的入参,又作 getSpu 等的回包载体。
// Zig 侧同为双向:`write_json`/`to_json` 负责序列化(与 Gson 一致跳过 null 字段),
// `parse` 族负责解析。`gpa` 仅为 parse 产生的实例设置;手工构造的请求实例
// gpa 为 null,此时 deinit/deinitConst 为 no-op(借用字符串不可 free)。

/// 对应 `WxMinishopGoodsSkuAttr`(attr_key/attr_value)。
pub const SkuAttr = struct {
    gpa: ?std.mem.Allocator = null,
    attr_key: ?[]const u8 = null,
    attr_value: ?[]const u8 = null,

    pub fn write_json(self: *const SkuAttr, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.attr_key) |v| {
            try w.writeAll("\"attr_key\":");
            try js(w, v);
            sep = true;
        }
        if (self.attr_value) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"attr_value\":");
            try js(w, v);
        }
        try w.writeAll("}");
    }

    pub fn deinit(self: *SkuAttr) void {
        if (self.gpa) |g| {
            if (self.attr_key) |s| g.free(@constCast(s));
            if (self.attr_value) |s| g.free(@constCast(s));
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const SkuAttr) void {
        if (self.gpa) |g| {
            if (self.attr_key) |s| g.free(s);
            if (self.attr_value) |s| g.free(s);
        }
    }
};

/// 解析 SkuAttr(pub:product_order 复用同一个共享类,对齐 Java 引用关系)。
pub fn parseSkuAttr(gpa: std.mem.Allocator, v: std.json.Value) !SkuAttr {
    return .{
        .gpa = gpa,
        .attr_key = try looseStr(gpa, v, "attr_key"),
        .attr_value = try looseStr(gpa, v, "attr_value"),
    };
}

/// 对应 `MinishopShopCat`(店铺的商品分类)。字段名对齐微信 API
/// (cat_id/shop_cat_name/f_cat_id/level),见文件头差异说明。
pub const ShopCat = struct {
    gpa: ?std.mem.Allocator = null,
    cat_id: ?i64 = null,
    shop_cat_name: ?[]const u8 = null,
    f_cat_id: ?i64 = null,
    level: ?i64 = null,

    pub fn write_json(self: *const ShopCat, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.cat_id) |v| {
            try w.print("\"cat_id\":{d}", .{v});
            sep = true;
        }
        if (self.shop_cat_name) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"shop_cat_name\":");
            try js(w, v);
            sep = true;
        }
        if (self.f_cat_id) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"f_cat_id\":{d}", .{v});
            sep = true;
        }
        if (self.level) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"level\":{d}", .{v});
        }
        try w.writeAll("}");
    }

    pub fn deinit(self: *ShopCat) void {
        if (self.gpa) |g| {
            if (self.shop_cat_name) |s| g.free(@constCast(s));
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const ShopCat) void {
        if (self.gpa) |g| {
            if (self.shop_cat_name) |s| g.free(s);
        }
    }
};

fn parseShopCat(gpa: std.mem.Allocator, v: std.json.Value) !ShopCat {
    return .{
        .gpa = gpa,
        .cat_id = json_util.getInt(v, "cat_id"),
        .shop_cat_name = try looseStr(gpa, v, "shop_cat_name"),
        .f_cat_id = json_util.getInt(v, "f_cat_id"),
        .level = json_util.getInt(v, "level"),
    };
}

/// 对应 `WxMinishopSpu.DescInfo`(imgs)。
pub const DescInfo = struct {
    gpa: ?std.mem.Allocator = null,
    imgs: []const []const u8 = &[_][]const u8{},

    pub fn write_json(self: *const DescInfo, w: *std.Io.Writer) !void {
        try w.writeAll("{\"imgs\":[");
        for (self.imgs, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            try js(w, s);
        }
        try w.writeAll("]}");
    }

    pub fn deinit(self: *DescInfo) void {
        if (self.gpa) |g| {
            for (self.imgs) |s| g.free(@constCast(s));
            g.free(self.imgs);
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const DescInfo) void {
        if (self.gpa) |g| {
            for (self.imgs) |s| g.free(s);
            g.free(self.imgs);
        }
    }
};

fn parseDescInfo(gpa: std.mem.Allocator, v: std.json.Value) !DescInfo {
    var out = DescInfo{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "imgs")) |arr| out.imgs = try dupStrArray(gpa, arr);
    return out;
}

/// 对应 `WxMinishopSpu.ExpressInfo`(template_id)。
pub const ExpressInfo = struct {
    template_id: ?i64 = null,

    pub fn write_json(self: *const ExpressInfo, w: *std.Io.Writer) !void {
        if (self.template_id) |v| {
            try w.print("{{\"template_id\":{d}}}", .{v});
        } else {
            try w.writeAll("{}");
        }
    }
};

fn parseExpressInfo(v: std.json.Value) ExpressInfo {
    return .{ .template_id = json_util.getInt(v, "template_id") };
}

/// 对应 `WxMinishopSku`。字段序对齐 Java 声明序(product_id…sku_attrs)。
pub const Sku = struct {
    gpa: ?std.mem.Allocator = null,
    product_id: ?i64 = null,
    out_product_id: ?[]const u8 = null,
    out_sku_id: ?[]const u8 = null,
    sku_id: ?i64 = null,
    thumb_img: ?[]const u8 = null,
    sale_price: ?i64 = null,
    market_price: ?i64 = null,
    stock_num: ?i64 = null,
    sku_code: ?[]const u8 = null,
    barcode: ?[]const u8 = null,
    sku_attrs: []const SkuAttr = &[_]SkuAttr{},

    pub fn write_json(self: *const Sku, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.product_id) |v| {
            try w.print("\"product_id\":{d}", .{v});
            sep = true;
        }
        if (self.out_product_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"out_product_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.out_sku_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"out_sku_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.sku_id) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"sku_id\":{d}", .{v});
            sep = true;
        }
        if (self.thumb_img) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"thumb_img\":");
            try js(w, v);
            sep = true;
        }
        if (self.sale_price) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"sale_price\":{d}", .{v});
            sep = true;
        }
        if (self.market_price) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"market_price\":{d}", .{v});
            sep = true;
        }
        if (self.stock_num) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"stock_num\":{d}", .{v});
            sep = true;
        }
        if (self.sku_code) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"sku_code\":");
            try js(w, v);
            sep = true;
        }
        if (self.barcode) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"barcode\":");
            try js(w, v);
            sep = true;
        }
        if (self.sku_attrs.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"sku_attrs\":[");
            for (self.sku_attrs, 0..) |*a, i| {
                if (i > 0) try w.writeAll(",");
                try a.write_json(w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }

    pub fn to_json(self: *const Sku, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try self.write_json(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn deinit(self: *Sku) void {
        if (self.gpa) |g| {
            if (self.out_product_id) |s| g.free(@constCast(s));
            if (self.out_sku_id) |s| g.free(@constCast(s));
            if (self.thumb_img) |s| g.free(@constCast(s));
            if (self.sku_code) |s| g.free(@constCast(s));
            if (self.barcode) |s| g.free(@constCast(s));
            for (self.sku_attrs) |*a| a.deinitConst();
            g.free(self.sku_attrs);
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const Sku) void {
        if (self.gpa) |g| {
            if (self.out_product_id) |s| g.free(s);
            if (self.out_sku_id) |s| g.free(s);
            if (self.thumb_img) |s| g.free(s);
            if (self.sku_code) |s| g.free(s);
            if (self.barcode) |s| g.free(s);
            for (self.sku_attrs) |*a| a.deinitConst();
            g.free(self.sku_attrs);
        }
    }
};

fn parseSku(gpa: std.mem.Allocator, v: std.json.Value) !Sku {
    var out = Sku{ .gpa = gpa };
    errdefer out.deinit();
    out.product_id = json_util.getInt(v, "product_id");
    out.out_product_id = try looseStr(gpa, v, "out_product_id");
    out.out_sku_id = try looseStr(gpa, v, "out_sku_id");
    out.sku_id = json_util.getInt(v, "sku_id");
    out.thumb_img = try looseStr(gpa, v, "thumb_img");
    out.sale_price = json_util.getInt(v, "sale_price");
    out.market_price = json_util.getInt(v, "market_price");
    out.stock_num = json_util.getInt(v, "stock_num");
    out.sku_code = try looseStr(gpa, v, "sku_code");
    out.barcode = try looseStr(gpa, v, "barcode");
    if (json_util.getArray(v, "sku_attrs")) |arr| {
        const list = try gpa.alloc(SkuAttr, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*a| a.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseSkuAttr(gpa, item);
            filled += 1;
        }
        out.sku_attrs = list;
    }
    return out;
}

/// 对应 `WxMinishopSpu`。字段序对齐 Java 声明序(product_id…skus);
/// product_id 在 SPU bean 中是 String(与 Sku 的 Long 不同,Java 亦如此)。
pub const Spu = struct {
    gpa: ?std.mem.Allocator = null,
    product_id: ?[]const u8 = null,
    out_product_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    sub_title: ?[]const u8 = null,
    head_img: []const []const u8 = &[_][]const u8{},
    desc_info: ?DescInfo = null,
    brand_id: ?i64 = null,
    cats: []const ShopCat = &[_]ShopCat{},
    attrs: []const SkuAttr = &[_]SkuAttr{},
    model: ?[]const u8 = null,
    express_info: ?ExpressInfo = null,
    skus: []const Sku = &[_]Sku{},

    pub fn write_json(self: *const Spu, w: *std.Io.Writer) !void {
        try w.writeAll("{");
        var sep = false;
        if (self.product_id) |v| {
            try w.writeAll("\"product_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.out_product_id) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"out_product_id\":");
            try js(w, v);
            sep = true;
        }
        if (self.title) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"title\":");
            try js(w, v);
            sep = true;
        }
        if (self.sub_title) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"sub_title\":");
            try js(w, v);
            sep = true;
        }
        if (self.head_img.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"head_img\":[");
            for (self.head_img, 0..) |s, i| {
                if (i > 0) try w.writeAll(",");
                try js(w, s);
            }
            try w.writeAll("]");
            sep = true;
        }
        if (self.desc_info) |*d| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"desc_info\":");
            try d.write_json(w);
            sep = true;
        }
        if (self.brand_id) |v| {
            if (sep) try w.writeAll(",");
            try w.print("\"brand_id\":{d}", .{v});
            sep = true;
        }
        if (self.cats.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"cats\":[");
            for (self.cats, 0..) |*c, i| {
                if (i > 0) try w.writeAll(",");
                try c.write_json(w);
            }
            try w.writeAll("]");
            sep = true;
        }
        if (self.attrs.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"attrs\":[");
            for (self.attrs, 0..) |*a, i| {
                if (i > 0) try w.writeAll(",");
                try a.write_json(w);
            }
            try w.writeAll("]");
            sep = true;
        }
        if (self.model) |v| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"model\":");
            try js(w, v);
            sep = true;
        }
        if (self.express_info) |*e| {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"express_info\":");
            try e.write_json(w);
            sep = true;
        }
        if (self.skus.len > 0) {
            if (sep) try w.writeAll(",");
            try w.writeAll("\"skus\":[");
            for (self.skus, 0..) |*sk, i| {
                if (i > 0) try w.writeAll(",");
                try sk.write_json(w);
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }

    pub fn to_json(self: *const Spu, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try self.write_json(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn deinit(self: *Spu) void {
        if (self.gpa) |g| {
            if (self.product_id) |s| g.free(@constCast(s));
            if (self.out_product_id) |s| g.free(@constCast(s));
            if (self.title) |s| g.free(@constCast(s));
            if (self.sub_title) |s| g.free(@constCast(s));
            for (self.head_img) |s| g.free(@constCast(s));
            g.free(self.head_img);
            if (self.desc_info) |*d| d.deinit();
            for (self.cats) |*c| c.deinitConst();
            g.free(self.cats);
            for (self.attrs) |*a| a.deinitConst();
            g.free(self.attrs);
            if (self.model) |s| g.free(@constCast(s));
            for (self.skus) |*sk| sk.deinitConst();
            g.free(self.skus);
        }
        self.* = undefined;
    }

    pub fn deinitConst(self: *const Spu) void {
        if (self.gpa) |g| {
            if (self.product_id) |s| g.free(s);
            if (self.out_product_id) |s| g.free(s);
            if (self.title) |s| g.free(s);
            if (self.sub_title) |s| g.free(s);
            for (self.head_img) |s| g.free(s);
            g.free(self.head_img);
            if (self.desc_info) |*d| d.deinitConst();
            for (self.cats) |*c| c.deinitConst();
            g.free(self.cats);
            for (self.attrs) |*a| a.deinitConst();
            g.free(self.attrs);
            if (self.model) |s| g.free(s);
            for (self.skus) |*sk| sk.deinitConst();
            g.free(self.skus);
        }
    }
};

fn parseSpu(gpa: std.mem.Allocator, v: std.json.Value) !Spu {
    var out = Spu{ .gpa = gpa };
    errdefer out.deinit();
    out.product_id = try looseStr(gpa, v, "product_id");
    out.out_product_id = try looseStr(gpa, v, "out_product_id");
    out.title = try looseStr(gpa, v, "title");
    out.sub_title = try looseStr(gpa, v, "sub_title");
    if (json_util.getArray(v, "head_img")) |arr| out.head_img = try dupStrArray(gpa, arr);
    if (json_util.getObject(v, "desc_info")) |dv| out.desc_info = try parseDescInfo(gpa, dv);
    out.brand_id = json_util.getInt(v, "brand_id");
    if (json_util.getArray(v, "cats")) |arr| {
        const list = try gpa.alloc(ShopCat, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*c| c.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseShopCat(gpa, item);
            filled += 1;
        }
        out.cats = list;
    }
    if (json_util.getArray(v, "attrs")) |arr| {
        const list = try gpa.alloc(SkuAttr, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*a| a.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseSkuAttr(gpa, item);
            filled += 1;
        }
        out.attrs = list;
    }
    out.model = try looseStr(gpa, v, "model");
    if (json_util.getObject(v, "express_info")) |ev| out.express_info = parseExpressInfo(ev);
    if (json_util.getArray(v, "skus")) |arr| {
        const list = try gpa.alloc(Sku, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*sk| sk.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseSku(gpa, item);
            filled += 1;
        }
        out.skus = list;
    }
    return out;
}

/// 对应 `shop.request.WxMaShopSpuPageRequest`(spu 分页参数,全可选)。
pub const SpuPageRequest = struct {
    /// 商品状态
    status: ?i64 = null,
    /// 开始创建时间
    start_create_time: ?[]const u8 = null,
    /// 结束创建时间
    end_create_time: ?[]const u8 = null,
    /// 开始更新时间
    start_update_time: ?[]const u8 = null,
    /// 结束更新时间
    end_update_time: ?[]const u8 = null,
    /// 默认 0:获取线上数据,1:获取草稿数据
    need_edit_spu: ?i64 = null,
    /// 页号(最小填 1)
    page: ?i64 = null,
    /// 页面大小
    page_size: ?i64 = null,

    pub fn to_json(self: SpuPageRequest, gpa: std.mem.Allocator) ![]u8 {
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        if (self.status) |v| try ob.putInt("status", v);
        if (self.start_create_time) |v| try ob.putStr("start_create_time", v);
        if (self.end_create_time) |v| try ob.putStr("end_create_time", v);
        if (self.start_update_time) |v| try ob.putStr("start_update_time", v);
        if (self.end_update_time) |v| try ob.putStr("end_update_time", v);
        if (self.need_edit_spu) |v| try ob.putInt("need_edit_spu", v);
        if (self.page) |v| try ob.putInt("page", v);
        if (self.page_size) |v| try ob.putInt("page_size", v);
        return ob.toJson();
    }
};

// --- bean(回包)----------------------------------------------------------------------

/// 对应 `WxMinishopAddGoodsSpuData`(add 填 create_time,update 填 update_time)。
pub const AddSpuData = struct {
    gpa: std.mem.Allocator,
    product_id: ?i64 = null,
    out_product_id: ?[]const u8 = null,
    create_time: ?[]const u8 = null,
    update_time: ?[]const u8 = null,

    pub fn deinit(self: *AddSpuData) void {
        const g = self.gpa;
        if (self.out_product_id) |s| g.free(@constCast(s));
        if (self.create_time) |s| g.free(@constCast(s));
        if (self.update_time) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AddSpuData) void {
        const g = self.gpa;
        if (self.out_product_id) |s| g.free(s);
        if (self.create_time) |s| g.free(s);
        if (self.update_time) |s| g.free(s);
    }
};

/// 对应 `WxMinishopAddGoodsSkuData`(sku_id/out_sku_id/create_time)。
pub const AddSkuData = struct {
    gpa: std.mem.Allocator,
    sku_id: ?i64 = null,
    out_sku_id: ?[]const u8 = null,
    create_time: ?[]const u8 = null,

    pub fn deinit(self: *AddSkuData) void {
        const g = self.gpa;
        if (self.out_sku_id) |s| g.free(@constCast(s));
        if (self.create_time) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AddSkuData) void {
        const g = self.gpa;
        if (self.out_sku_id) |s| g.free(s);
        if (self.create_time) |s| g.free(s);
    }
};

/// 对应 `WxMinishopAddGoodsSkuData` 列表(batch_add 的 data 数组)。
pub const AddSkuListResult = struct {
    gpa: std.mem.Allocator,
    items: []AddSkuData = &[_]AddSkuData{},

    pub fn deinit(self: *AddSkuListResult) void {
        for (self.items) |*d| d.deinit();
        self.gpa.free(self.items);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const AddSkuListResult) void {
        for (self.items) |*d| d.deinitConst();
        self.gpa.free(self.items);
    }
};

/// 对应 `WxMinishopUpdateGoodsSkuData`(sku_id/out_sku_id/update_time)。
pub const UpdateSkuData = struct {
    gpa: std.mem.Allocator,
    sku_id: ?i64 = null,
    out_sku_id: ?[]const u8 = null,
    update_time: ?[]const u8 = null,

    pub fn deinit(self: *UpdateSkuData) void {
        const g = self.gpa;
        if (self.out_sku_id) |s| g.free(@constCast(s));
        if (self.update_time) |s| g.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const UpdateSkuData) void {
        const g = self.gpa;
        if (self.out_sku_id) |s| g.free(s);
        if (self.update_time) |s| g.free(s);
    }
};

/// 对应 `WxMinishopSpuGetResponse`(data.spu)。
pub const SpuGetResult = struct {
    gpa: std.mem.Allocator,
    spu: ?Spu = null,

    pub fn deinit(self: *SpuGetResult) void {
        if (self.spu) |*s| s.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const SpuGetResult) void {
        if (self.spu) |*s| s.deinitConst();
    }
};

/// 对应 `WxMinishopSpuListResponse`(顶层 total_num/spus)。
pub const SpuListResult = struct {
    gpa: std.mem.Allocator,
    total_num: ?i64 = null,
    spus: []const Spu = &[_]Spu{},

    pub fn deinit(self: *SpuListResult) void {
        for (self.spus) |*s| s.deinitConst();
        self.gpa.free(self.spus);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const SpuListResult) void {
        for (self.spus) |*s| s.deinitConst();
        self.gpa.free(self.spus);
    }
};

/// 对应 `WxMinishopSkuListResponse`(顶层 skus)。
pub const SkuListResult = struct {
    gpa: std.mem.Allocator,
    skus: []const Sku = &[_]Sku{},

    pub fn deinit(self: *SkuListResult) void {
        for (self.skus) |*s| s.deinitConst();
        self.gpa.free(self.skus);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const SkuListResult) void {
        for (self.skus) |*s| s.deinitConst();
        self.gpa.free(self.skus);
    }
};

/// 对应 `WxMinishopGetCategoryResponse.MinishopCatItem`。
pub const CategoryItem = struct {
    gpa: std.mem.Allocator,
    cat_id: ?i64 = null,
    f_cat_id: ?i64 = null,
    name: ?[]const u8 = null,

    pub fn deinit(self: *CategoryItem) void {
        if (self.name) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const CategoryItem) void {
        if (self.name) |s| self.gpa.free(s);
    }
};

/// 对应 `WxMinishopGetCategoryResponse`(顶层 cat_list)。
pub const CategoryResult = struct {
    gpa: std.mem.Allocator,
    cat_list: []CategoryItem = &[_]CategoryItem{},

    pub fn deinit(self: *CategoryResult) void {
        for (self.cat_list) |*c| c.deinit();
        self.gpa.free(self.cat_list);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const CategoryResult) void {
        for (self.cat_list) |*c| c.deinitConst();
        self.gpa.free(self.cat_list);
    }
};

/// 对应 `WxMinishopGetBrandResponse.MinishopBrandInfo`。
pub const BrandInfo = struct {
    gpa: std.mem.Allocator,
    brand_id: ?i64 = null,
    brand_name: ?[]const u8 = null,

    pub fn deinit(self: *BrandInfo) void {
        if (self.brand_name) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BrandInfo) void {
        if (self.brand_name) |s| self.gpa.free(s);
    }
};

/// 对应 `WxMinishopGetBrandResponse.MinishopBrandItem`。
pub const BrandItem = struct {
    gpa: std.mem.Allocator,
    first_cat_id: ?i64 = null,
    second_cat_id: ?i64 = null,
    third_cat_id: ?i64 = null,
    brand_info: ?BrandInfo = null,

    pub fn deinit(self: *BrandItem) void {
        if (self.brand_info) |*b| b.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BrandItem) void {
        if (self.brand_info) |*b| b.deinitConst();
    }
};

/// 对应 `WxMinishopGetBrandResponse`(顶层 brands)。
pub const BrandResult = struct {
    gpa: std.mem.Allocator,
    brands: []BrandItem = &[_]BrandItem{},

    pub fn deinit(self: *BrandResult) void {
        for (self.brands) |*b| b.deinit();
        self.gpa.free(self.brands);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const BrandResult) void {
        for (self.brands) |*b| b.deinitConst();
        self.gpa.free(self.brands);
    }
};

/// 对应 `WxMinishopGetFrightTemplateResponse.MinishopFeightTemplateItem`
/// (Java 类名 Fright/Feight 拼写如此)。
pub const FreightTemplateItem = struct {
    gpa: std.mem.Allocator,
    template_id: ?i64 = null,
    name: ?[]const u8 = null,
    valuation_type: ?i64 = null,

    pub fn deinit(self: *FreightTemplateItem) void {
        if (self.name) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const FreightTemplateItem) void {
        if (self.name) |s| self.gpa.free(s);
    }
};

/// 对应 `WxMinishopGetFrightTemplateResponse`(顶层 template_list)。
pub const FreightTemplateResult = struct {
    gpa: std.mem.Allocator,
    template_list: []FreightTemplateItem = &[_]FreightTemplateItem{},

    pub fn deinit(self: *FreightTemplateResult) void {
        for (self.template_list) |*t| t.deinit();
        self.gpa.free(self.template_list);
        self.* = undefined;
    }

    pub fn deinitConst(self: *const FreightTemplateResult) void {
        for (self.template_list) |*t| t.deinitConst();
        self.gpa.free(self.template_list);
    }
};

/// 对应 `WxMinishopPicFileResult`(media_id/pay_media_id/temp_img_url,
/// Java 对缺失字段填 "")。
pub const PicFile = struct {
    gpa: std.mem.Allocator,
    media_id: []const u8 = "",
    pay_media_id: []const u8 = "",
    temp_img_url: []const u8 = "",

    pub fn deinit(self: *PicFile) void {
        const g = self.gpa;
        if (self.media_id.len > 0) g.free(@constCast(self.media_id));
        if (self.pay_media_id.len > 0) g.free(@constCast(self.pay_media_id));
        if (self.temp_img_url.len > 0) g.free(@constCast(self.temp_img_url));
        self.* = undefined;
    }

    pub fn deinitConst(self: *const PicFile) void {
        const g = self.gpa;
        if (self.media_id.len > 0) g.free(self.media_id);
        if (self.pay_media_id.len > 0) g.free(self.pay_media_id);
        if (self.temp_img_url.len > 0) g.free(self.temp_img_url);
    }
};

/// 对应 `WxMinishopImageUploadResult`(errcode/errmsg 已由基座折叠,pic_file
/// 缺失时 Java NPE,Zig 归一化为 null)。
pub const ImageUploadResult = struct {
    gpa: std.mem.Allocator,
    pic_file: ?PicFile = null,

    pub fn deinit(self: *ImageUploadResult) void {
        if (self.pic_file) |*p| p.deinit();
        self.* = undefined;
    }

    pub fn deinitConst(self: *const ImageUploadResult) void {
        if (self.pic_file) |*p| p.deinitConst();
    }
};

// --- 回包解析 ----------------------------------------------------------------------

fn parseAddSpuData(gpa: std.mem.Allocator, v: std.json.Value) !AddSpuData {
    var out = AddSpuData{ .gpa = gpa };
    errdefer out.deinit();
    out.product_id = json_util.getInt(v, "product_id");
    out.out_product_id = try looseStr(gpa, v, "out_product_id");
    out.create_time = try looseStr(gpa, v, "create_time");
    out.update_time = try looseStr(gpa, v, "update_time");
    return out;
}

fn parseAddSkuData(gpa: std.mem.Allocator, v: std.json.Value) !AddSkuData {
    var out = AddSkuData{ .gpa = gpa };
    errdefer out.deinit();
    out.sku_id = json_util.getInt(v, "sku_id");
    out.out_sku_id = try looseStr(gpa, v, "out_sku_id");
    out.create_time = try looseStr(gpa, v, "create_time");
    return out;
}

fn parseUpdateSkuData(gpa: std.mem.Allocator, v: std.json.Value) !UpdateSkuData {
    var out = UpdateSkuData{ .gpa = gpa };
    errdefer out.deinit();
    out.sku_id = json_util.getInt(v, "sku_id");
    out.out_sku_id = try looseStr(gpa, v, "out_sku_id");
    out.update_time = try looseStr(gpa, v, "update_time");
    return out;
}

/// 取 errcode=0 回包的 `data` 对象;缺失时 Java 侧为 NPE,Zig 返回 null 由
/// 调用方归一化。
fn dataObj(v: std.json.Value) ?std.json.Value {
    return json_util.getObject(v, "data");
}

/// 同上,但 data 可能是数组(batch_add 的回包)。
fn dataValue(v: std.json.Value) ?std.json.Value {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return o.get("data");
}

fn parseSpuGetResult(gpa: std.mem.Allocator, v: std.json.Value) !SpuGetResult {
    var out = SpuGetResult{ .gpa = gpa };
    errdefer out.deinit();
    if (dataObj(v)) |d| {
        if (json_util.getObject(d, "spu")) |sv| out.spu = try parseSpu(gpa, sv);
    }
    return out;
}

fn parseSpuListResult(gpa: std.mem.Allocator, v: std.json.Value) !SpuListResult {
    var out = SpuListResult{ .gpa = gpa };
    errdefer out.deinit();
    out.total_num = json_util.getInt(v, "total_num");
    if (json_util.getArray(v, "spus")) |arr| {
        const list = try gpa.alloc(Spu, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*s| s.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseSpu(gpa, item);
            filled += 1;
        }
        out.spus = list;
    }
    return out;
}

fn parseSkuListResult(gpa: std.mem.Allocator, v: std.json.Value) !SkuListResult {
    var out = SkuListResult{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "skus")) |arr| {
        const list = try gpa.alloc(Sku, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*s| s.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = try parseSku(gpa, item);
            filled += 1;
        }
        out.skus = list;
    }
    return out;
}

fn parseCategoryResult(gpa: std.mem.Allocator, v: std.json.Value) !CategoryResult {
    var out = CategoryResult{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "cat_list")) |arr| {
        const list = try gpa.alloc(CategoryItem, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*c| c.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = .{
                .gpa = gpa,
                .cat_id = json_util.getInt(item, "cat_id"),
                .f_cat_id = json_util.getInt(item, "f_cat_id"),
                .name = try looseStr(gpa, item, "name"),
            };
            filled += 1;
        }
        out.cat_list = list;
    }
    return out;
}

fn parseBrandResult(gpa: std.mem.Allocator, v: std.json.Value) !BrandResult {
    var out = BrandResult{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "brands")) |arr| {
        const list = try gpa.alloc(BrandItem, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*b| b.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            var bi = BrandItem{ .gpa = gpa };
            bi.first_cat_id = json_util.getInt(item, "first_cat_id");
            bi.second_cat_id = json_util.getInt(item, "second_cat_id");
            bi.third_cat_id = json_util.getInt(item, "third_cat_id");
            if (json_util.getObject(item, "brand_info")) |bv| {
                bi.brand_info = .{
                    .gpa = gpa,
                    .brand_id = json_util.getInt(bv, "brand_id"),
                    .brand_name = try looseStr(gpa, bv, "brand_name"),
                };
            }
            list[filled] = bi;
            filled += 1;
        }
        out.brands = list;
    }
    return out;
}

fn parseFreightTemplateResult(gpa: std.mem.Allocator, v: std.json.Value) !FreightTemplateResult {
    var out = FreightTemplateResult{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getArray(v, "template_list")) |arr| {
        const list = try gpa.alloc(FreightTemplateItem, arr.items.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*t| t.deinit();
            gpa.free(list);
        }
        for (arr.items) |item| {
            list[filled] = .{
                .gpa = gpa,
                .template_id = json_util.getInt(item, "template_id"),
                .name = try looseStr(gpa, item, "name"),
                .valuation_type = json_util.getInt(item, "valuation_type"),
            };
            filled += 1;
        }
        out.template_list = list;
    }
    return out;
}

fn parseImageUploadResult(gpa: std.mem.Allocator, v: std.json.Value) !ImageUploadResult {
    var out = ImageUploadResult{ .gpa = gpa };
    errdefer out.deinit();
    if (json_util.getObject(v, "pic_file")) |pv| {
        // Java 对缺失字段填 ""(非 null)
        out.pic_file = .{
            .gpa = gpa,
            .media_id = (try looseStr(gpa, pv, "media_id")) orelse "",
            .pay_media_id = (try looseStr(gpa, pv, "pay_media_id")) orelse "",
            .temp_img_url = (try looseStr(gpa, pv, "temp_img_url")) orelse "",
        };
    }
    return out;
}

// --- service -----------------------------------------------------------------------

/// 对应 `WxMaProductServiceImpl`。所有方法 errcode≠0 时返回 `.err`。
pub const ProductService = struct {
    svc: *mp_service.Service,

    /// 对应 `uploadImg(File,Integer,Integer,Integer)`:multipart 版本未实现
    /// (基座 http 层暂不支持 multipart,同 media 模块)。
    /// 对应 `uploadImg(String imgUrl,Integer respType)`:POST img/upload
    /// `?upload_type=1&resp_type=N`,body {"img_url":…}。
    pub fn uploadImgUrl(self: *ProductService, io: std.Io, img_url: []const u8, resp_type: i64) WxResult(ImageUploadResult) {
        const gpa = self.svc.gpa;
        var rt_buf: [24]u8 = undefined;
        const rt = std.fmt.bufPrint(&rt_buf, "{d}", .{resp_type}) catch "0";
        const queries = [_]mp_service.Query{
            .{ .key = "upload_type", .value = "1" },
            .{ .key = "resp_type", .value = rt },
        };
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"img_url\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, img_url) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, IMG_UPLOAD_URL, queries[0..], body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "img upload not json", .{}) };
        defer parsed.deinit();
        const out_r = parseImageUploadResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "img upload parse fail", .{}) };
        return .{ .ok = out_r };
    }

    /// 对应 `getCategory(Integer fCatId)`:POST category/get {"f_cat_id":N}。
    pub fn getCategory(self: *ProductService, io: std.Io, f_cat_id: ?i64) WxResult(CategoryResult) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        if (f_cat_id) |v| ob.putInt("f_cat_id", v) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_CATEGORY_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "category get not json", .{}) };
        defer parsed.deinit();
        const out = parseCategoryResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "category parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getBrand()`:POST brand/get(空请求体 {})。
    pub fn getBrand(self: *ProductService, io: std.Io) WxResult(BrandResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_BRAND_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "brand get not json", .{}) };
        defer parsed.deinit();
        const out = parseBrandResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "brand parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getFreightTemplate()`:POST delivery/get_freight_template(空请求体 {})。
    pub fn getFreightTemplate(self: *ProductService, io: std.Io) WxResult(FreightTemplateResult) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, GET_FREIGHT_TEMPLATE_URL, &.{}, "{}")) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "freight template not json", .{}) };
        defer parsed.deinit();
        const out = parseFreightTemplateResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "freight template parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `addSpu(WxMinishopSpu)`:POST spu/add → data{product_id,out_product_id,
    /// create_time}。
    pub fn addSpu(self: *ProductService, io: std.Io, spu: Spu) WxResult(AddSpuData) {
        return self.postSpu(io, SPU_ADD_URL, spu);
    }

    /// 对应 `updateSpu(WxMinishopSpu)`:POST spu/update → data{product_id,
    /// out_product_id,update_time}。
    pub fn updateSpu(self: *ProductService, io: std.Io, spu: Spu) WxResult(AddSpuData) {
        return self.postSpu(io, SPU_UPDATE_URL, spu);
    }

    fn postSpu(self: *ProductService, io: std.Io, url: []const u8, spu: Spu) WxResult(AddSpuData) {
        const gpa = self.svc.gpa;
        const body = spu.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "spu post not json", .{}) };
        defer parsed.deinit();
        const d = dataObj(parsed.value) orelse
            return .{ .ok = AddSpuData{ .gpa = gpa } };
        const out = parseAddSpuData(gpa, d) catch
            return .{ .err = WxError.internal(gpa, "spu data parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `deleteSpu(Integer,String)`:POST spu/del。
    pub fn deleteSpu(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8) Done {
        return self.postIdDone(io, SPU_DEL_URL, product_id, out_product_id);
    }

    /// 对应 `listingSpu(Integer,String)`:POST spu/listing(上架)。
    pub fn listingSpu(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8) Done {
        return self.postIdDone(io, SPU_LISTING_URL, product_id, out_product_id);
    }

    /// 对应 `delistingSpu(Integer,String)`:POST spu/delisting(下架)。
    pub fn delistingSpu(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8) Done {
        return self.postIdDone(io, SPU_DELISTING_URL, product_id, out_product_id);
    }

    fn postIdDone(self: *ProductService, io: std.Io, url: []const u8, product_id: ?i64, out_product_id: ?[]const u8) Done {
        const gpa = self.svc.gpa;
        const body = idBody(gpa, product_id, out_product_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `getSpu(Integer,String,Integer)`:POST spu/get。data/spu 缺失时
    /// Java 为 NPE,Zig 归一化为 `spu = null`。
    pub fn getSpu(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8, need_edit_spu: ?i64) WxResult(SpuGetResult) {
        const gpa = self.svc.gpa;
        const body = spuGetBody(gpa, product_id, out_product_id, need_edit_spu) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SPU_GET_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "spu get not json", .{}) };
        defer parsed.deinit();
        const out = parseSpuGetResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "spu get parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getSpuList(WxMaShopSpuPageRequest)`:POST spu/get_list。
    pub fn getSpuList(self: *ProductService, io: std.Io, req: SpuPageRequest) WxResult(SpuListResult) {
        const gpa = self.svc.gpa;
        const body = req.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SPU_GET_LIST_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "spu list not json", .{}) };
        defer parsed.deinit();
        const out = parseSpuListResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "spu list parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `getSkuList(Long,Integer,Integer)`:POST sku/get_list
    /// {"product_id":N,"need_edit_sku":N,"need_real_stock":N}。
    pub fn getSkuList(self: *ProductService, io: std.Io, product_id: ?i64, need_real_stock: ?i64, need_edit_sku: ?i64) WxResult(SkuListResult) {
        const gpa = self.svc.gpa;
        const body = skuListBody(gpa, product_id, need_real_stock, need_edit_sku) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_LIST_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku list not json", .{}) };
        defer parsed.deinit();
        const out = parseSkuListResult(gpa, parsed.value) catch
            return .{ .err = WxError.internal(gpa, "sku list parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `minishiopGoodsAddSku(WxMinishopSku)`(Java 方法名拼写如此):
    /// POST sku/add → data{sku_id,create_time}。
    pub fn addSku(self: *ProductService, io: std.Io, sku: Sku) WxResult(AddSkuData) {
        const gpa = self.svc.gpa;
        const body = sku.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_ADD_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku add not json", .{}) };
        defer parsed.deinit();
        const d = dataObj(parsed.value) orelse
            return .{ .ok = AddSkuData{ .gpa = gpa } };
        const out = parseAddSkuData(gpa, d) catch
            return .{ .err = WxError.internal(gpa, "sku add parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `minishopGoodsBatchAddSku(List<WxMinishopSku>)`:POST sku/batch_add
    /// {"skus":[…]} → data 为数组(sku_id/out_sku_id/create_time)。
    pub fn batchAddSku(self: *ProductService, io: std.Io, skus: []const Sku) WxResult(AddSkuListResult) {
        const gpa = self.svc.gpa;
        var out_w: std.Io.Writer.Allocating = .init(gpa);
        defer out_w.deinit();
        const w = &out_w.writer;
        w.writeAll("{\"skus\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (skus, 0..) |*sk, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            sk.write_json(w) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out_w.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_BATCH_ADD_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku batch add not json", .{}) };
        defer parsed.deinit();
        var out = AddSkuListResult{ .gpa = gpa };
        if (dataValue(parsed.value)) |d| {
            // data 是数组(Java getAsJsonArray)
            switch (d) {
                .array => |arr| {
                    const list = gpa.alloc(AddSkuData, arr.items.len) catch
                        return .{ .err = WxError.internal(gpa, "oom", .{}) };
                    var filled: usize = 0;
                    // 失败时显式清理(errdefer 不捕获 return .err)
                    for (arr.items) |item| {
                        list[filled] = parseAddSkuData(gpa, item) catch {
                            for (list[0..filled]) |*x| x.deinit();
                            gpa.free(list);
                            return .{ .err = WxError.internal(gpa, "sku batch add parse fail", .{}) };
                        };
                        filled += 1;
                    }
                    out.items = list;
                },
                else => {},
            }
        }
        return .{ .ok = out };
    }

    /// 对应 `minishopGoodsDelSku(Long,Long,String,Long)`:POST sku/del。
    /// 注意 Java 的 outProductId 形参是 Long,Zig 统一为字符串(见文件头差异说明)。
    pub fn delSku(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64) Done {
        const gpa = self.svc.gpa;
        const body = delSkuBody(gpa, product_id, out_product_id, out_sku_id, sku_id) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_DEL_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    /// 对应 `minishopGoodsUpdateSku(WxMinishopSku)`:POST sku/update →
    /// data{update_time}。
    pub fn updateSku(self: *ProductService, io: std.Io, sku: Sku) WxResult(UpdateSkuData) {
        const gpa = self.svc.gpa;
        const body = sku.to_json(gpa) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_UPDATE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku update not json", .{}) };
        defer parsed.deinit();
        const d = dataObj(parsed.value) orelse
            return .{ .ok = UpdateSkuData{ .gpa = gpa } };
        const out = parseUpdateSkuData(gpa, d) catch
            return .{ .err = WxError.internal(gpa, "sku update parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `minishopGoodsUpdateSkuPrice(...)`:POST sku/update_price
    /// {"product_id","out_product_id","sku_id","out_sku_id","sale_price",
    /// "market_price"}(键序对齐 Java)→ data{update_time}。
    pub fn updateSkuPrice(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64, sale_price: ?i64, market_price: ?i64) WxResult(UpdateSkuData) {
        const gpa = self.svc.gpa;
        const body = updateSkuPriceBody(gpa, product_id, out_product_id, out_sku_id, sku_id, sale_price, market_price) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_UPDATE_PRICE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku price not json", .{}) };
        defer parsed.deinit();
        const d = dataObj(parsed.value) orelse
            return .{ .ok = UpdateSkuData{ .gpa = gpa } };
        const out = parseUpdateSkuData(gpa, d) catch
            return .{ .err = WxError.internal(gpa, "sku price parse fail", .{}) };
        return .{ .ok = out };
    }

    /// 对应 `minishopGoodsUpdateSkuStock(...)`:POST stock/update(注意 URL 不在
    /// sku/ 前缀下){"product_id","out_product_id","sku_id","out_sku_id","type",
    /// "stock_num"}(键序对齐 Java)→ data{update_time}。
    pub fn updateSkuStock(self: *ProductService, io: std.Io, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64, type_: ?i64, stock_num: ?i64) WxResult(UpdateSkuData) {
        const gpa = self.svc.gpa;
        const body = updateSkuStockBody(gpa, product_id, out_product_id, out_sku_id, sku_id, type_, stock_num) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, SKU_UPDATE_STOCK_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "sku stock not json", .{}) };
        defer parsed.deinit();
        const d = dataObj(parsed.value) orelse
            return .{ .ok = UpdateSkuData{ .gpa = gpa } };
        const out = parseUpdateSkuData(gpa, d) catch
            return .{ .err = WxError.internal(gpa, "sku stock parse fail", .{}) };
        return .{ .ok = out };
    }
};

// --- 请求体构建 ------------------------------------------------------------------

/// {"product_id":N,"out_product_id":"…"}(null 跳过,对齐 GsonHelper.buildJsonObject)。
fn idBody(gpa: std.mem.Allocator, product_id: ?i64, out_product_id: ?[]const u8) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (out_product_id) |v| try ob.putStr("out_product_id", v);
    return ob.toJson();
}

fn spuGetBody(gpa: std.mem.Allocator, product_id: ?i64, out_product_id: ?[]const u8, need_edit_spu: ?i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (out_product_id) |v| try ob.putStr("out_product_id", v);
    if (need_edit_spu) |v| try ob.putInt("need_edit_spu", v);
    return ob.toJson();
}

fn skuListBody(gpa: std.mem.Allocator, product_id: ?i64, need_real_stock: ?i64, need_edit_sku: ?i64) ![]u8 {
    // 键序对齐 Java:product_id, need_edit_sku, need_real_stock
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (need_edit_sku) |v| try ob.putInt("need_edit_sku", v);
    if (need_real_stock) |v| try ob.putInt("need_real_stock", v);
    return ob.toJson();
}

fn delSkuBody(gpa: std.mem.Allocator, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (out_product_id) |v| try ob.putStr("out_product_id", v);
    if (out_sku_id) |v| try ob.putStr("out_sku_id", v);
    if (sku_id) |v| try ob.putInt("sku_id", v);
    return ob.toJson();
}

fn updateSkuPriceBody(gpa: std.mem.Allocator, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64, sale_price: ?i64, market_price: ?i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (out_product_id) |v| try ob.putStr("out_product_id", v);
    if (sku_id) |v| try ob.putInt("sku_id", v);
    if (out_sku_id) |v| try ob.putStr("out_sku_id", v);
    if (sale_price) |v| try ob.putInt("sale_price", v);
    if (market_price) |v| try ob.putInt("market_price", v);
    return ob.toJson();
}

fn updateSkuStockBody(gpa: std.mem.Allocator, product_id: ?i64, out_product_id: ?[]const u8, out_sku_id: ?[]const u8, sku_id: ?i64, type_: ?i64, stock_num: ?i64) ![]u8 {
    var ob = json_util.ObjectBuilder.init(gpa);
    defer ob.deinit();
    if (product_id) |v| try ob.putInt("product_id", v);
    if (out_product_id) |v| try ob.putStr("out_product_id", v);
    if (sku_id) |v| try ob.putInt("sku_id", v);
    if (out_sku_id) |v| try ob.putStr("out_sku_id", v);
    if (type_) |v| try ob.putInt("type", v);
    if (stock_num) |v| try ob.putInt("stock_num", v);
    return ob.toJson();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "spu add/update: 完整 bean 序列化 + data 解析" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "spu/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"product_id\":123,\"out_product_id\":\"op-1\",\"create_time\":\"2021-03-23 12:00:00\"}}" },
        .{ .match = "spu/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"product_id\":123,\"out_product_id\":\"op-1\",\"update_time\":\"2021-03-24 12:00:00\"}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    const spu = Spu{
        .out_product_id = "op-1",
        .title = "拉杆箱",
        .sub_title = "大容量",
        .head_img = &[_][]const u8{ "https://img/1.png", "https://img/2.png" },
        .desc_info = .{ .imgs = &[_][]const u8{"https://img/desc.png"} },
        .brand_id = 2100000000,
        .cats = &[_]ShopCat{.{ .cat_id = 20000, .shop_cat_name = "箱包", .f_cat_id = 1, .level = 1 }},
        .attrs = &[_]SkuAttr{.{ .attr_key = "颜色", .attr_value = "绿" }},
        .model = "M1",
        .express_info = .{ .template_id = 1 },
        .skus = &[_]Sku{.{ .out_sku_id = "sku-1", .thumb_img = "t.png", .sale_price = 99800, .market_price = 999800, .stock_num = 100, .sku_code = "C1", .barcode = "B1", .sku_attrs = &[_]SkuAttr{.{ .attr_key = "颜色", .attr_value = "绿" }} }},
    };

    var added = switch (s.addSpu(io, spu)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer added.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "product/spu/add") != null);
    try std.testing.expectEqualStrings(
        "{\"out_product_id\":\"op-1\",\"title\":\"拉杆箱\",\"sub_title\":\"大容量\",\"head_img\":[\"https://img/1.png\",\"https://img/2.png\"],\"desc_info\":{\"imgs\":[\"https://img/desc.png\"]},\"brand_id\":2100000000,\"cats\":[{\"cat_id\":20000,\"shop_cat_name\":\"箱包\",\"f_cat_id\":1,\"level\":1}],\"attrs\":[{\"attr_key\":\"颜色\",\"attr_value\":\"绿\"}],\"model\":\"M1\",\"express_info\":{\"template_id\":1},\"skus\":[{\"out_sku_id\":\"sku-1\",\"thumb_img\":\"t.png\",\"sale_price\":99800,\"market_price\":999800,\"stock_num\":100,\"sku_code\":\"C1\",\"barcode\":\"B1\",\"sku_attrs\":[{\"attr_key\":\"颜色\",\"attr_value\":\"绿\"}]}]}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(i64, 123), added.product_id.?);
    try std.testing.expectEqualStrings("op-1", added.out_product_id.?);
    try std.testing.expectEqualStrings("2021-03-23 12:00:00", added.create_time.?);
    try std.testing.expect(added.update_time == null);

    var updated = switch (s.updateSpu(io, spu)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "product/spu/update") != null);
    try std.testing.expectEqualStrings("2021-03-24 12:00:00", updated.update_time.?);
}

test "spu get/list: 嵌套树解析 + 分页请求" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 注意 get_list 必须排在 get 之前(前缀包含)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "spu/get_list", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"total_num\":1,\"spus\":[{\"product_id\":123,\"title\":\"箱\",\"skus\":[{\"sku_id\":55}]}]}" },
        .{ .match = "spu/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"spu\":{\"product_id\":123,\"out_product_id\":\"op-1\",\"title\":\"拉杆箱\",\"head_img\":[\"a.png\"],\"desc_info\":{\"imgs\":[\"d.png\"]},\"brand_id\":9,\"cats\":[{\"cat_id\":1,\"shop_cat_name\":\"c\",\"f_cat_id\":0,\"level\":2}],\"attrs\":[{\"attr_key\":\"k\",\"attr_value\":\"v\"}],\"model\":\"M1\",\"express_info\":{\"template_id\":3},\"skus\":[{\"product_id\":123,\"out_product_id\":\"op-1\",\"out_sku_id\":\"sku-1\",\"sku_id\":55,\"thumb_img\":\"t\",\"sale_price\":99800,\"market_price\":999800,\"stock_num\":100,\"sku_code\":\"C\",\"barcode\":\"B\",\"sku_attrs\":[{\"attr_key\":\"颜色\",\"attr_value\":\"绿\"}]}]}}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    var got = switch (s.getSpu(io, 123, "op-1", 0)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer got.deinit();
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_product_id\":\"op-1\",\"need_edit_spu\":0}", m.last_body);
    const spu = got.spu.?;
    // Java 的 Spu.productId 是 String;微信回数字,Gson 宽容转字符串
    try std.testing.expectEqualStrings("123", spu.product_id.?);
    try std.testing.expectEqualStrings("拉杆箱", spu.title.?);
    try std.testing.expectEqual(@as(i64, 9), spu.brand_id.?);
    try std.testing.expectEqual(@as(usize, 1), spu.head_img.len);
    try std.testing.expectEqualStrings("a.png", spu.head_img[0]);
    try std.testing.expectEqual(@as(usize, 1), spu.desc_info.?.imgs.len);
    try std.testing.expectEqualStrings("d.png", spu.desc_info.?.imgs[0]);
    try std.testing.expectEqual(@as(i64, 1), spu.cats[0].cat_id.?);
    try std.testing.expectEqualStrings("c", spu.cats[0].shop_cat_name.?);
    try std.testing.expectEqual(@as(i64, 2), spu.cats[0].level.?);
    try std.testing.expectEqualStrings("k", spu.attrs[0].attr_key.?);
    try std.testing.expectEqual(@as(i64, 3), spu.express_info.?.template_id.?);
    try std.testing.expectEqual(@as(usize, 1), spu.skus.len);
    try std.testing.expectEqual(@as(i64, 55), spu.skus[0].sku_id.?);
    try std.testing.expectEqual(@as(i64, 99800), spu.skus[0].sale_price.?);
    try std.testing.expectEqualStrings("绿", spu.skus[0].sku_attrs[0].attr_value.?);

    var list = switch (s.getSpuList(io, .{ .status = 5, .page = 1, .page_size = 10, .need_edit_spu = 0 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer list.deinit();
    try std.testing.expectEqualStrings("{\"status\":5,\"need_edit_spu\":0,\"page\":1,\"page_size\":10}", m.last_body);
    try std.testing.expectEqual(@as(i64, 1), list.total_num.?);
    try std.testing.expectEqual(@as(usize, 1), list.spus.len);
    try std.testing.expectEqualStrings("箱", list.spus[0].title.?);
    try std.testing.expectEqual(@as(i64, 55), list.spus[0].skus[0].sku_id.?);
}

test "spu del/listing/delisting: 请求体与 Done" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // delisting 必须排在 del 之前(前缀包含)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "spu/delisting", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "spu/listing", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "spu/del", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    switch (s.deleteSpu(io, 123, "op-1")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_product_id\":\"op-1\"}", m.last_body);

    switch (s.listingSpu(io, 123, "op-1")) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "spu/listing") != null);

    switch (s.delistingSpu(io, 123, null)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"product_id\":123}", m.last_body);
}

test "sku add/batch/del/update/price/stock" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // update_price/update_stock 必须排在 update 之前(前缀包含)
    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "sku/batch_add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":[{\"sku_id\":11,\"out_sku_id\":\"s1\",\"create_time\":\"t1\"},{\"sku_id\":12,\"out_sku_id\":\"s2\",\"create_time\":\"t2\"}]}" },
        .{ .match = "sku/add", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"sku_id\":11,\"create_time\":\"t1\"}}" },
        .{ .match = "sku/update_price", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"update_time\":\"tp\"}}" },
        .{ .match = "stock/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"update_time\":\"ts\"}}" },
        .{ .match = "sku/update", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"update_time\":\"tu\"}}" },
        .{ .match = "sku/del", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "sku/get_list", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"skus\":[{\"sku_id\":11,\"out_sku_id\":\"s1\",\"sale_price\":1},{\"sku_id\":12}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    var added = switch (s.addSku(io, .{ .product_id = 123, .out_sku_id = "s1", .sale_price = 99800, .stock_num = 100 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer added.deinit();
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_sku_id\":\"s1\",\"sale_price\":99800,\"stock_num\":100}", m.last_body);
    try std.testing.expectEqual(@as(i64, 11), added.sku_id.?);
    try std.testing.expectEqualStrings("t1", added.create_time.?);

    const skus = [_]Sku{
        .{ .out_sku_id = "s1", .sale_price = 1 },
        .{ .out_sku_id = "s2", .sale_price = 2 },
    };
    var batch = switch (s.batchAddSku(io, skus[0..])) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer batch.deinit();
    try std.testing.expectEqualStrings("{\"skus\":[{\"out_sku_id\":\"s1\",\"sale_price\":1},{\"out_sku_id\":\"s2\",\"sale_price\":2}]}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@as(i64, 12), batch.items[1].sku_id.?);
    try std.testing.expectEqualStrings("s2", batch.items[1].out_sku_id.?);

    switch (s.delSku(io, 123, "op-1", "s1", 11)) {
        .ok => {},
        .err => return error.Unexpected,
    }
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_product_id\":\"op-1\",\"out_sku_id\":\"s1\",\"sku_id\":11}", m.last_body);

    var updated = switch (s.updateSku(io, .{ .product_id = 123, .sku_id = 11, .stock_num = 50 })) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer updated.deinit();
    try std.testing.expectEqualStrings("tu", updated.update_time.?);

    var priced = switch (s.updateSkuPrice(io, 123, "op-1", "s1", 11, 9900, 19900)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer priced.deinit();
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_product_id\":\"op-1\",\"sku_id\":11,\"out_sku_id\":\"s1\",\"sale_price\":9900,\"market_price\":19900}", m.last_body);
    try std.testing.expectEqualStrings("tp", priced.update_time.?);

    var stocked = switch (s.updateSkuStock(io, 123, "op-1", "s1", 11, 1, 50)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer stocked.deinit();
    try std.testing.expectEqualStrings("{\"product_id\":123,\"out_product_id\":\"op-1\",\"sku_id\":11,\"out_sku_id\":\"s1\",\"type\":1,\"stock_num\":50}", m.last_body);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "product/stock/update") != null);
    try std.testing.expectEqualStrings("ts", stocked.update_time.?);

    var list = switch (s.getSkuList(io, 123, 0, 1)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer list.deinit();
    try std.testing.expectEqualStrings("{\"product_id\":123,\"need_edit_sku\":1,\"need_real_stock\":0}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), list.skus.len);
    try std.testing.expectEqual(@as(i64, 11), list.skus[0].sku_id.?);
    try std.testing.expectEqual(@as(i64, 1), list.skus[0].sale_price.?);
    try std.testing.expect(list.skus[1].sale_price == null);
}

test "category/brand/freight + uploadImgUrl" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "category/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"cat_list\":[{\"cat_id\":1,\"f_cat_id\":0,\"name\":\"食品\"},{\"cat_id\":2,\"name\":\"饮料\"}]}" },
        .{ .match = "brand/get", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"brands\":[{\"first_cat_id\":1,\"second_cat_id\":2,\"third_cat_id\":3,\"brand_info\":{\"brand_id\":9,\"brand_name\":\"可口可乐\"}}]}" },
        .{ .match = "get_freight_template", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"template_list\":[{\"template_id\":7,\"name\":\"包邮\",\"valuation_type\":0}]}" },
        .{ .match = "img/upload", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"pic_file\":{\"media_id\":\"M1\",\"pay_media_id\":\"P1\",\"temp_img_url\":\"https://t/1.png\"}}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    var cats = switch (s.getCategory(io, 0)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer cats.deinit();
    try std.testing.expectEqualStrings("{\"f_cat_id\":0}", m.last_body);
    try std.testing.expectEqual(@as(usize, 2), cats.cat_list.len);
    try std.testing.expectEqualStrings("食品", cats.cat_list[0].name.?);
    try std.testing.expect(cats.cat_list[1].f_cat_id == null);

    var brands = switch (s.getBrand(io)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer brands.deinit();
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expectEqual(@as(i64, 9), brands.brands[0].brand_info.?.brand_id.?);
    try std.testing.expectEqualStrings("可口可乐", brands.brands[0].brand_info.?.brand_name.?);

    var tpls = switch (s.getFreightTemplate(io)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer tpls.deinit();
    try std.testing.expectEqualStrings("{}", m.last_body);
    try std.testing.expectEqual(@as(i64, 7), tpls.template_list[0].template_id.?);
    try std.testing.expectEqual(@as(i64, 0), tpls.template_list[0].valuation_type.?);

    var up = switch (s.uploadImgUrl(io, "https://example.com/a.png", 1)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer up.deinit();
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "img/upload?upload_type=1&resp_type=1") != null);
    try std.testing.expectEqualStrings("{\"img_url\":\"https://example.com/a.png\"}", m.last_body);
    try std.testing.expectEqualStrings("M1", up.pic_file.?.media_id);
    try std.testing.expectEqualStrings("P1", up.pic_file.?.pay_media_id);
    try std.testing.expectEqualStrings("https://t/1.png", up.pic_file.?.temp_img_url);

    // 缺失 pic_file 字段时归一化为 null(Java 侧 NPE)
    var m2 = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "img/upload", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m2.deinit();
    var base2 = mp_service.Service.init(gpa, cfg.config(), m2.executor());
    var s2 = ProductService{ .svc = &base2 };
    var up2 = switch (s2.uploadImgUrl(io, "https://example.com/a.png", 0)) {
        .ok => |b| b,
        .err => return error.Unexpected,
    };
    defer up2.deinit();
    try std.testing.expect(up2.pic_file == null);
}

test "product: errcode≠0 折叠为 .err + 双向 bean 的 deinit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "spu/add", .response = "{\"errcode\":104001,\"errmsg\":\"spu not exist\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = ProductService{ .svc = &base };

    switch (s.addSpu(io, .{ .title = "x" })) {
        .ok => return error.Unexpected,
        .err => |e| {
            try std.testing.expectEqual(@as(i64, 104001), e.error_code);
            var err = e;
            err.deinit();
        },
    }

    // parse 产生的 Spu:gpa 已设置,deinit 应释放全部嵌套内存(测试分配器兜底)
    var parsed_spu = Spu{ .gpa = gpa };
    defer parsed_spu.deinit();
    var p = try json_util.parse(gpa, "{\"title\":\"t\",\"head_img\":[\"a\"],\"cats\":[{\"cat_id\":1}],\"skus\":[{\"out_sku_id\":\"s\",\"sku_attrs\":[{\"attr_key\":\"k\"}]}]}");
    defer p.deinit();
    parsed_spu = try parseSpu(gpa, p.value);
}
