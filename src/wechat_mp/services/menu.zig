//! 自定义菜单服务 —— 逐字对齐 Java `api.WxMpMenuService`(7 个方法 / 5 个方法名,
//! 其中 `menuCreate`、`menuDelete` 各含 2 个重载)+ `api.impl.WxMpMenuServiceImpl`。
//! 方法名沿用 Java 的 camelCase(rule 2)。
//!
//! Java 接口 7 个方法(rule 2 名称逐字对齐):
//!   menuCreate(WxMenu)   :26 / impl :31-48 —— matchRule!=null 走 addconditional 并返回 menuid
//!   menuCreate(String)   :40 / impl :51-64 —— JSON 串含顶层 matchrule 走 addconditional 并返回 menuid
//!   menuDelete()         :50 / impl :67-70 —— GET menu/delete
//!   menuDelete(menuId)   :61 / impl :73-78 —— POST menu/delconditional {"menuid":..}
//!   menuGet()            :72 / impl :81-92 —— GET menu/get,46003 → null
//!   menuTryMatch(userid) :84 / impl :95-109 —— POST menu/trymatch {"user_id":..},46003/46002 → null
//!   getSelfMenuInfo()    :104 / impl :112-115 —— GET get_current_selfmenu_info
//!
//! Java 重载 → Zig 惯用法(rule 1):
//!   - `menuCreate(WxMenu)` / `menuCreate(String)` → `menuCreate`(MenuSpec) / `menuCreateByJson`(raw JSON)
//!     (distinct names,对齐 phase-2 `user.zig:userInfoList/userInfoListByQuery`);
//!   - `menuDelete()` / `menuDelete(menuId)` → 单函数 `menuDelete(menu_id: ?[]const u8)`
//!     (one fn with optional param:null=GET delete,非 null=POST delconditional)。
//!   两种惯用法都保留 Java 两个重载的全部行为。
//!
//! 底座(rule 3):所有 URL 路径来自 `../api_url.zig:Menu`,经 `api()`(=
//! `api_url.url(Host.api, path)`)拼绝对 URL;移除旧 `service.zig:ApiUrl.*` 与本地
//! `Path` 字面量。本服务全部为「无 query 的 GET/POST」,不涉及手工 query 组包,
//! 故无需 `mp_helpers.buildUrl`(access_token 注入 / errcode→.err 折叠由
//! `Service.execute*` 统一完成,与 `user_tag.zig` 同)。
//!
//! Java↔Zig 差异(逐条按 Java 逻辑取舍):
//!   - `menuCreate(WxMenu)`:Java 内部分支处理 matchRule(选 addconditional + 取 menuid),
//!     旧 Zig 却在带 matchrule 时**报错**要求改用 createConditional。本轮改为忠实镜像
//!     Java —— 单个 `menuCreate` 同时覆盖普通/个性化两种菜单并返回 `?menuid`。
//!   - `menuGet`/`menuTryMatch`:Java 返回强类型 bean(`WxMpMenu`/`WxMenu`);Zig 保留
//!     骨架 `MenuGet`(原始响应 JSON),调用方用 `buttonsFromJson` 解析按钮 —— 保留旧契约。
//!   - `getSelfMenuInfo`:Java 返回 `WxMpGetSelfMenuInfoResult`(selfmenu_info/is_menu_open
//!     深层嵌套 bean);Zig 返回原始响应 JSON(`[]u8`),未逐字段建模该深层结构(见交付报告)。
//!   - `Boolean`/`void` 返回值 → `Done`(`.ok`=true、`.err`=抛出 WxError)。
//!
//! 内存所有权(全部 gpa 拥有,调用方负责):
//!   - `MenuGet`(raw `[]u8`)、`getSelfMenuInfo`(`[]u8`)、`menuCreate*`(`?[]u8` menuid):
//!     用毕 `gpa.free()` / `deinit()`;
//!   - `buttonsFromJson` 返回的 `[]Button`:逐元素递归 + 切片本身用 `deinitButtons` 释放;
//!   - `.err` 载荷为 `WxError`,用毕 `WxError.deinit()`。
const std = @import("std");
const testing = std.testing;

const json_util = @import("common").json_util;
const result_mod = @import("common").result;
pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = result_mod.WxError;

const api_url = @import("../api_url.zig");
const service_mod = @import("../service.zig");
const h = @import("sub_util.zig");

/// host+path 绝对 URL,路径全部取自 `api_url.zig:Menu`(comptime,无分配,无需 free)。
fn api(comptime path: []const u8) []const u8 {
    return api_url.url(api_url.Host.api, path);
}

// ---------------------------------------------------------------------------
// 请求侧规格 / JSON 组包(对应 Java `common.bean.menu.WxMenu` / `WxMenuButton`)
// —— 以下沿用旧版已验证的实现,保持其形状与所有权语义。
// ---------------------------------------------------------------------------

/// 菜单按钮(对应 Java `common.bean.menu.WxMenuButton`)。
/// 请求侧使用的借用规格:所有切片均为借用,调用方持有所有权。
/// 收录常用字段(type/name/key/url/media_id/appid/pagepath/sub_button);
/// Java bean 另有 `article_id`(article_view_limited 类型),本骨架未收录。
pub const ButtonSpec = struct {
    /// click / view / scancode_push / miniprogram ... 顶级父按钮(仅含子按钮)可为 null
    type: ?[]const u8 = null,
    name: []const u8,
    key: ?[]const u8 = null,
    url: ?[]const u8 = null,
    media_id: ?[]const u8 = null,
    appid: ?[]const u8 = null,
    pagepath: ?[]const u8 = null,
    sub_buttons: []const ButtonSpec = &.{},
};

/// 菜单规格(对应 Java `common.bean.menu.WxMenu`)。切片均为借用。
pub const MenuSpec = struct {
    buttons: []const ButtonSpec,
    /// 个性化菜单匹配规则,原始 JSON 对象串(对应 `WxMenuRule.toJson`);
    /// 非 null 时走 addconditional(对应 Java matchRule != null 分支)。
    match_rule: ?[]const u8 = null,
};

/// 把按钮规格序列化为 `std.json.Value`(字段缺省则不输出,对应 Gson 的 null 省略)。
/// 注意:返回的 Value 里的容器(ObjectMap/ArrayList)由 gpa 分配,字符串一律借用,
/// 释放需配合 `freeJsonContainers`(见 menuToJson)。
fn buttonValue(gpa: std.mem.Allocator, b: ButtonSpec) !json_util.Value {
    var map: json_util.ObjectMap = .empty;
    errdefer map.deinit(gpa);
    try map.put(gpa, "name", .{ .string = b.name });
    if (b.type) |v| try map.put(gpa, "type", .{ .string = v });
    if (b.key) |v| try map.put(gpa, "key", .{ .string = v });
    if (b.url) |v| try map.put(gpa, "url", .{ .string = v });
    if (b.media_id) |v| try map.put(gpa, "media_id", .{ .string = v });
    if (b.appid) |v| try map.put(gpa, "appid", .{ .string = v });
    if (b.pagepath) |v| try map.put(gpa, "pagepath", .{ .string = v });
    if (b.sub_buttons.len > 0) {
        var subs: std.ArrayList(json_util.Value) = .empty;
        errdefer subs.deinit(gpa);
        for (b.sub_buttons) |s| try subs.append(gpa, try buttonValue(gpa, s));
        try map.put(gpa, "sub_button", .{ .array = subs });
    }
    return .{ .object = map };
}

/// 递归释放 `buttonValue`/`menuToJson` 自建的 json 容器(ObjectMap / ArrayList)。
/// 字符串均借用自调用方的 MenuSpec,不能在这里释放;键由容器自己的 deinit 释放。
fn freeJsonContainers(gpa: std.mem.Allocator, v: json_util.Value) void {
    switch (v) {
        .object => |o_const| {
            var o = o_const;
            var it = o.iterator();
            while (it.next()) |kv| freeJsonContainers(gpa, kv.value_ptr.*);
            o.deinit(gpa);
        },
        .array => |a_const| {
            var a = a_const;
            for (a.items) |item| freeJsonContainers(gpa, item);
            a.deinit(gpa);
        },
        else => {},
    }
}

/// 菜单按钮数组 → JSON body(对应 Java `WxMenu.toJson`,外层包 `{"button":[...]}`)。
/// `match_rule` 非 null 时解析并入 `matchrule` 字段。返回串由 gpa 分配,调用方释放。
pub fn menuToJson(gpa: std.mem.Allocator, menu: MenuSpec) ![]u8 {
    var arr: std.ArrayList(json_util.Value) = .empty;
    // 容器树(button map / sub_button 数组)自建于本函数,序列化完成后统一释放。
    defer {
        for (arr.items) |item| freeJsonContainers(gpa, item);
        arr.deinit(gpa);
    }
    for (menu.buttons) |b| try arr.append(gpa, try buttonValue(gpa, b));

    var builder = json_util.ObjectBuilder.init(gpa);
    defer builder.deinit();
    try builder.putValue("button", .{ .array = arr });

    // matchrule 的解析结果必须活到 toJson 之后(putValue 只是浅拷贝 Value,
    // 字符串仍归 parsed 所有;若先 deinit 再序列化会读到悬垂内存)。
    var rule_parsed: ?std.json.Parsed(json_util.Value) = null;
    defer if (rule_parsed) |*p| p.deinit();
    if (menu.match_rule) |rule_src| {
        const rule = try json_util.parse(gpa, rule_src);
        try builder.putValue("matchrule", rule.value);
        rule_parsed = rule;
    }
    return builder.toJson();
}

/// 解析后的菜单按钮(全部字段 gpa 拥有,用 `deinitButtons` 释放)。
pub const Button = struct {
    type: ?[]const u8 = null,
    name: []const u8 = "",
    key: ?[]const u8 = null,
    url: ?[]const u8 = null,
    media_id: ?[]const u8 = null,
    sub_buttons: []Button = &.{},
};

fn dupeField(gpa: std.mem.Allocator, v: json_util.Value, key: []const u8) !?[]const u8 {
    const s = json_util.getStr(v, key) orelse return null;
    return try gpa.dupe(u8, s);
}

fn parseButton(gpa: std.mem.Allocator, v: json_util.Value) !Button {
    var btn = Button{
        .type = try dupeField(gpa, v, "type"),
        .name = (try dupeField(gpa, v, "name")) orelse "",
        .key = try dupeField(gpa, v, "key"),
        .url = try dupeField(gpa, v, "url"),
        .media_id = try dupeField(gpa, v, "media_id"),
    };
    if (json_util.getArray(v, "sub_button")) |subs| {
        var list: std.ArrayList(Button) = .empty;
        errdefer {
            for (list.items) |*s| deinitButton(gpa, s);
            list.deinit(gpa);
        }
        for (subs.items) |s| try list.append(gpa, try parseButton(gpa, s));
        btn.sub_buttons = try list.toOwnedSlice(gpa);
    }
    return btn;
}

fn deinitButton(gpa: std.mem.Allocator, b: *Button) void {
    for ([_]?[]const u8{ b.type, b.key, b.url, b.media_id }) |s| {
        if (s) |v| gpa.free(@constCast(v));
    }
    if (b.name.len > 0) gpa.free(@constCast(b.name));
    for (b.sub_buttons) |*s| deinitButton(gpa, s);
    if (b.sub_buttons.len > 0) gpa.free(b.sub_buttons);
    b.* = undefined;
}

/// 释放 `buttonsFromJson` 的结果(递归释放嵌套子按钮)。
pub fn deinitButtons(gpa: std.mem.Allocator, buttons: []Button) void {
    for (buttons) |*b| deinitButton(gpa, b);
    gpa.free(buttons);
}

/// 从菜单 JSON 解析按钮数组(对应 Java `WxMpMenu.fromJson` 的 button 提取)。
/// 兼容两种形态:普通菜单 `{"menu":{"button":[...]}}` 与个性化菜单顶层 `{"button":[...]}`。
pub fn buttonsFromJson(gpa: std.mem.Allocator, raw: []const u8) ![]Button {
    const parsed = try json_util.parse(gpa, raw);
    defer parsed.deinit();

    var arr_src: ?std.ArrayList(json_util.Value) = json_util.getArray(parsed.value, "button");
    if (arr_src == null) {
        if (json_util.objectOf(parsed.value, "menu")) |menu_obj| {
            if (menu_obj.get("button")) |bv| {
                if (bv == .array) arr_src = bv.array;
            }
        }
    }
    var list: std.ArrayList(Button) = .empty;
    errdefer deinitButtons(gpa, list.items);
    if (arr_src) |arr| {
        for (arr.items) |bv| try list.append(gpa, try parseButton(gpa, bv));
    }
    return list.toOwnedSlice(gpa);
}

/// 菜单查询结果(对应 Java `bean.menu.WxMpMenu`,骨架保留原始 JSON)。
pub const MenuGet = struct {
    gpa: std.mem.Allocator,
    /// 原始响应 JSON(gpa 拥有);可用 `buttonsFromJson` 进一步解析。
    raw: []u8,

    pub fn deinit(self: *MenuGet) void {
        self.gpa.free(self.raw);
    }
};

// ---------------------------------------------------------------------------
// MenuService —— 对应 Java `WxMpMenuService`(7 方法) + `WxMpMenuServiceImpl`
// ---------------------------------------------------------------------------

pub const MenuService = struct {
    svc: *service_mod.Service,

    /// 把 `WxResult([]u8)` 折叠为 `Done`(对应 Java 返回 void 的方法,errcode!=0
    /// 已由服务层折叠成 .err,这里只需释放响应体)。
    fn discard(self: *MenuService, r: WxResult([]u8)) Done {
        switch (r) {
            .ok => |b| {
                self.svc.gpa.free(b);
                return .{ .ok = {} };
            },
            .err => |e| return .{ .err = e },
        }
    }

    /// POST 创建菜单并按 Java 语义抽取 menuid(impl :40-47 / :58-63):
    /// `conditional` 为真(含 matchrule)时 POST addconditional 并返回响应 `menuid`;
    /// 否则 POST create 并返回 null。`body` 为借用切片,调用方持有。
    fn createWithBody(self: *MenuService, io: std.Io, conditional: bool, body: []const u8) WxResult(?[]u8) {
        const gpa = self.svc.gpa;
        const resp = if (conditional)
            self.svc.post(io, api(api_url.Menu.menu_addconditional), &.{}, body)
        else
            self.svc.post(io, api(api_url.Menu.menu_create), &.{}, body);
        const b = switch (resp) {
            .ok => |x| x,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(b);
        if (!conditional) return .{ .ok = null };

        const parsed = json_util.parse(gpa, b) catch return .{
            .err = WxError.transport(gpa, "addconditional 响应非 JSON", .{}),
        };
        defer parsed.deinit();
        const menuid = json_util.getStr(parsed.value, "menuid") orelse return .{
            .err = WxError.transport(gpa, "响应缺少 menuid", .{}),
        };
        const dup = gpa.dupe(u8, menuid) catch return .{
            .err = WxError.internal(gpa, "oom", .{}),
        };
        return .{ .ok = dup };
    }

    /// `WxMpMenuService.menuCreate(WxMenu)` (接口 :26 / impl :31-48)。
    /// `menuJson = menu.toJson()`(本轮 `menuToJson`),`matchRule != null` →
    /// MENU_ADDCONDITIONAL 否则 MENU_CREATE;POST 后个性化菜单返回 `menuid`、
    /// 普通菜单返回 null(Java `GsonParser.parse(result).get("menuid")`)。
    /// 所有权:`.ok` 非 null 的 `[]u8` 由 gpa 拥有,调用方 `gpa.free()`。
    pub fn menuCreate(self: *MenuService, io: std.Io, menu: MenuSpec) WxResult(?[]u8) {
        const gpa = self.svc.gpa;
        const conditional = menu.match_rule != null;
        const body = menuToJson(gpa, menu) catch
            return .{ .err = WxError.internal(gpa, "menu json: 序列化失败", .{}) };
        defer gpa.free(body);
        return self.createWithBody(io, conditional, body);
    }

    /// `WxMpMenuService.menuCreate(String json)` (接口 :40 / impl :51-64)。
    /// 先 `GsonParser.parse(json)` 检查**顶层** `matchrule` 键是否存在以选路,
    /// 再 POST **原始 json 串**(不重新序列化);含 matchrule 时返回响应 `menuid`。
    /// `json` 为借用切片;所有权:`.ok` 非 null 的 `[]u8` 调用方 `gpa.free()`。
    pub fn menuCreateByJson(self: *MenuService, io: std.Io, json: []const u8) WxResult(?[]u8) {
        const gpa = self.svc.gpa;
        const parsed = json_util.parse(gpa, json) catch return .{
            .err = WxError.transport(gpa, "menu json 非法", .{}),
        };
        defer parsed.deinit();
        var conditional = false;
        if (json_util.object(parsed.value)) |o| {
            conditional = o.get("matchrule") != null;
        }
        return self.createWithBody(io, conditional, json);
    }

    /// `WxMpMenuService.menuGet()` (接口 :72 / impl :81-92)。
    /// GET MENU_GET → `WxMpMenu.fromJson`;特殊语义:errcode==46003(不存在的菜单数据)
    /// 折叠为 `.ok(null)`;成功时返回原始 JSON(`MenuGet`),用 `buttonsFromJson` 解析按钮。
    pub fn menuGet(self: *MenuService, io: std.Io) WxResult(?MenuGet) {
        const gpa = self.svc.gpa;
        switch (self.svc.get(io, api(api_url.Menu.menu_get), &.{})) {
            .ok => |b| return .{ .ok = .{ .gpa = gpa, .raw = b } },
            .err => |e| {
                if (e.error_code == 46003) {
                    var err = e;
                    err.deinit();
                    return .{ .ok = null };
                }
                return .{ .err = e };
            },
        }
    }

    /// `WxMpMenuService.menuTryMatch(userid)` (接口 :84 / impl :95-109)。
    /// POST MENU_TRYMATCH,body `{"user_id":userid}` → `WxMenu.fromJson`;
    /// errcode==46003(菜单数据不存在)或 46002(菜单版本不存在)折叠为 `.ok(null)`。
    /// 返回原始响应 JSON(`MenuGet`,用 `buttonsFromJson` 解析)。
    pub fn menuTryMatch(self: *MenuService, io: std.Io, userid: []const u8) WxResult(?MenuGet) {
        const gpa = self.svc.gpa;
        var ob = json_util.ObjectBuilder.init(gpa);
        defer ob.deinit();
        ob.putStr("user_id", userid) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = ob.toJson() catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        switch (self.svc.post(io, api(api_url.Menu.menu_trymatch), &.{}, body)) {
            .ok => |b| return .{ .ok = .{ .gpa = gpa, .raw = b } },
            .err => |e| {
                if (e.error_code == 46003 or e.error_code == 46002) {
                    var err = e;
                    err.deinit();
                    return .{ .ok = null };
                }
                return .{ .err = e };
            },
        }
    }

    /// `WxMpMenuService.getSelfMenuInfo()` (接口 :104 / impl :112-115)。
    /// GET GET_CURRENT_SELFMENU_INFO → `WxMpGetSelfMenuInfoResult.fromJson`。
    /// 本轮返回原始响应 JSON(`[]u8`,gpa 拥有,调用方 `gpa.free()`);
    /// Java bean 的 selfmenu_info / is_menu_open 深层嵌套结构未逐字段建模。
    pub fn getSelfMenuInfo(self: *MenuService, io: std.Io) WxResult([]u8) {
        return self.svc.get(io, api(api_url.Menu.get_current_selfmenu_info), &.{});
    }

    /// `WxMpMenuService.menuDelete()` (:50) / `menuDelete(String menuId)` (:61)。
    /// 合并为单函数 + 可选参数:
    ///   - `menu_id == null` → GET MENU_DELETE(impl :67-70,void);
    ///   - `menu_id != null` → POST MENU_DELCONDITIONAL,body `{"menuid":menuId}`
    ///     (impl :73-78,void)。
    /// 返回 Done(`.ok`=true、`.err`=抛出)。
    pub fn menuDelete(self: *MenuService, io: std.Io, menu_id: ?[]const u8) Done {
        const gpa = self.svc.gpa;
        if (menu_id) |mid| {
            var ob = json_util.ObjectBuilder.init(gpa);
            defer ob.deinit();
            ob.putStr("menuid", mid) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            const body = ob.toJson() catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            defer gpa.free(body);
            return self.discard(self.svc.post(io, api(api_url.Menu.menu_delconditional), &.{}, body));
        }
        return self.discard(self.svc.get(io, api(api_url.Menu.menu_delete), &.{}));
    }
};

// ---------------------------------------------------------------------------
// 离线契约测试(URL / method / 请求体 / 响应字段 / 所有权)
// 脚手架复用 `sub_util.zig` 的 Recorder/Fixture(phase-2 约定),全离线。
// ---------------------------------------------------------------------------

test "menuCreate(WxMenu): POST menu/create + button JSON + 返回 null" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/create", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    const menu = MenuSpec{ .buttons = &.{
        .{ .type = "click", .name = "今日指南", .key = "V1001_TODAY" },
        .{ .name = "操作指南", .sub_buttons = &.{
            .{ .type = "view", .name = "微官网", .url = "http://weixin.qq.com/" },
        } },
    } };
    switch (menu_svc.menuCreate(io, menu)) {
        .ok => |maybe_id| {
            if (maybe_id) |id| gpa.free(id);
            try testing.expect(maybe_id == null); // 普通菜单 Java 返回 null
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/create") != null);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "access_token=TOK") != null);
    // 未走个性化菜单分支
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "addconditional") == null);

    // 断言请求 body 字段(对应 WxMenu.toJson 的 {"button":[...]})
    var body = try json_util.parse(gpa, mock.body());
    defer body.deinit();
    const buttons = json_util.getArray(body.value, "button").?;
    try testing.expectEqual(@as(usize, 2), buttons.items.len);
    try testing.expectEqualStrings("click", json_util.getStr(buttons.items[0], "type").?);
    try testing.expectEqualStrings("今日指南", json_util.getStr(buttons.items[0], "name").?);
    try testing.expectEqualStrings("V1001_TODAY", json_util.getStr(buttons.items[0], "key").?);
    const subs = json_util.getArray(buttons.items[1], "sub_button").?;
    try testing.expectEqual(@as(usize, 1), subs.items.len);
    try testing.expectEqualStrings("http://weixin.qq.com/", json_util.getStr(subs.items[0], "url").?);
}

test "menuCreate: errcode 折叠为 .err(Service 层)" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/create", .response = "{\"errcode\":40018,\"errmsg\":\"invalid button name size\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };

    switch (menu_svc.menuCreate(fx.threaded.io(), .{ .buttons = &.{.{ .name = "x" }} })) {
        .ok => return error.ExpectedError,
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            try testing.expectEqual(@as(i64, 40018), err.error_code);
        },
    }
}

test "menuCreate 带 matchrule → POST addconditional + 返回 menuid" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/addconditional", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"menuid\":\"1234\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };

    const menu = MenuSpec{
        .buttons = &.{.{ .type = "view", .name = "v", .url = "http://a" }},
        .match_rule = "{\"tag_id\":\"100\"}",
    };
    switch (menu_svc.menuCreate(fx.threaded.io(), menu)) {
        .ok => |maybe_id| {
            const id = maybe_id orelse return error.ExpectedMenuid;
            defer gpa.free(id);
            try testing.expectEqualStrings("1234", id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/addconditional") != null);
    var body = try json_util.parse(gpa, mock.body());
    defer body.deinit();
    try testing.expect(json_util.objectOf(body.value, "matchrule") != null);
}

test "menuCreateByJson: 原样 POST + 按顶层 matchrule 选路 / 返回 menuid" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/addconditional", .response = "{\"menuid\":\"M-9\"}" },
        .{ .match = "cgi-bin/menu/create", .response = "{\"errcode\":0}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 无 matchrule → POST create,原样透传 json 串,返回 null
    const plain = "{\"button\":[{\"name\":\"n\",\"type\":\"click\",\"key\":\"K\"}]}";
    switch (menu_svc.menuCreateByJson(io, plain)) {
        .ok => |maybe_id| {
            if (maybe_id) |id| gpa.free(id);
            try testing.expect(maybe_id == null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/create") != null);
    try testing.expectEqualStrings(plain, mock.body()); // Java 不重新序列化,原样 POST

    // 含顶层 matchrule → POST addconditional 并返回 menuid
    const conditional = "{\"button\":[{\"name\":\"n\"}],\"matchrule\":{\"tag_id\":\"1\"}}";
    switch (menu_svc.menuCreateByJson(io, conditional)) {
        .ok => |maybe_id| {
            const id = maybe_id orelse return error.ExpectedMenuid;
            defer gpa.free(id);
            try testing.expectEqualStrings("M-9", id);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/addconditional") != null);
    try testing.expectEqualStrings(conditional, mock.body());
}

test "menuGet: GET menu/get + buttonsFromJson + 46003 折叠为 null" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/get", .response =
        \\{"menu":{"button":[{"type":"click","name":"a","key":"K"},{"name":"g","sub_button":[{"type":"view","name":"v","url":"http://x"}]}]}}
        },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    switch (menu_svc.menuGet(io)) {
        .ok => |maybe| {
            var mg = maybe.?;
            defer mg.deinit();
            try testing.expectEqualStrings("get", mock.last_method);
            try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/get") != null);

            const buttons = try buttonsFromJson(gpa, mg.raw);
            defer deinitButtons(gpa, buttons);
            try testing.expectEqual(@as(usize, 2), buttons.len);
            try testing.expectEqualStrings("click", buttons[0].type.?);
            try testing.expectEqualStrings("K", buttons[0].key.?);
            try testing.expectEqual(@as(usize, 1), buttons[1].sub_buttons.len);
            try testing.expectEqualStrings("http://x", buttons[1].sub_buttons[0].url.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // 46003 → null(对应 Java menuGet 捕获 46003 返回 null)
    mock.entries = &.{
        .{ .match = "cgi-bin/menu/get", .response = "{\"errcode\":46003,\"errmsg\":\"menu not exist\"}" },
    };
    switch (menu_svc.menuGet(io)) {
        .ok => |maybe| try testing.expect(maybe == null),
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "menuDelete(null): GET menu/delete void" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/delete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };

    switch (menu_svc.menuDelete(fx.threaded.io(), null)) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/delete") != null);
}

test "menuDelete(menuId): POST menu/delconditional {\"menuid\":..}" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/delconditional", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };

    switch (menu_svc.menuDelete(fx.threaded.io(), "M-9")) {
        .ok => {},
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/delconditional") != null);
    try testing.expectEqualStrings("{\"menuid\":\"M-9\"}", mock.body());
}

test "menuTryMatch: POST menu/trymatch {\"user_id\":..} + 46003/46002 → null" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/menu/trymatch", .response =
        \\{"button":[{"type":"click","name":"m","key":"KM"}]}
        },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };
    const io = fx.threaded.io();

    // 成功:顶层 {"button":[...]} → MenuGet,可经 buttonsFromJson 解析
    switch (menu_svc.menuTryMatch(io, "oUSER")) {
        .ok => |maybe| {
            var mg = maybe.?;
            defer mg.deinit();
            const buttons = try buttonsFromJson(gpa, mg.raw);
            defer deinitButtons(gpa, buttons);
            try testing.expectEqual(@as(usize, 1), buttons.len);
            try testing.expectEqualStrings("KM", buttons[0].key.?);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("post", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/menu/trymatch") != null);
    try testing.expectEqualStrings("{\"user_id\":\"oUSER\"}", mock.body());

    // 46003 / 46002 折叠为 null(Java impl :101-107)
    for ([_][]const u8{
        "{\"errcode\":46003,\"errmsg\":\"menu no\"}",
        "{\"errcode\":46002,\"errmsg\":\"version no\"}",
    }) |resp| {
        mock.entries = &.{.{ .match = "cgi-bin/menu/trymatch", .response = resp }};
        switch (menu_svc.menuTryMatch(io, "oUSER")) {
            .ok => |maybe| try testing.expect(maybe == null),
            .err => |*e| {
                var err = e.*;
                defer err.deinit();
                return error.Unexpected;
            },
        }
    }
}

test "getSelfMenuInfo: GET get_current_selfmenu_info + 原样返回 body" {
    const gpa = testing.allocator;
    var mock = h.Recorder{ .gpa = gpa, .entries = &.{
        .{ .match = "cgi-bin/get_current_selfmenu_info", .response =
        \\{"is_menu_open":1,"selfmenu_info":{"button":[]}}
        },
    } };
    var fx: h.Fixture = undefined;
    try h.setup(gpa, &mock, &fx);
    defer h.teardown(&fx);
    var menu_svc = MenuService{ .svc = &fx.svc };

    switch (menu_svc.getSelfMenuInfo(fx.threaded.io())) {
        .ok => |b| {
            defer gpa.free(b); // []u8 结果 gpa 拥有,调用方 free
            try testing.expect(std.mem.indexOf(u8, b, "selfmenu_info") != null);
            try testing.expect(std.mem.indexOf(u8, b, "is_menu_open") != null);
        },
        .err => |*e| {
            var err = e.*;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try testing.expectEqualStrings("get", mock.last_method);
    try testing.expect(std.mem.indexOf(u8, mock.uri(), "cgi-bin/get_current_selfmenu_info") != null);
}
