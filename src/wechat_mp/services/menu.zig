//! 自定义菜单服务 —— 对应 Java `api.WxMpMenuService` + `api.impl.WxMpMenuServiceImpl`。
//!
//! URL 对应 Java `enums.WxMpApiUrl.Menu`:
//! - MENU_CREATE      `/cgi-bin/menu/create`
//! - MENU_GET         `/cgi-bin/menu/get`
//! - MENU_DELETE      `/cgi-bin/menu/delete`
//! - MENU_ADDCONDITIONAL `/cgi-bin/menu/addconditional`(带 matchrule 时走这条,
//!   对应 Java `menuCreate(WxMenu)` 中 matchRule != null 的分支)
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const service_mod = @import("../service.zig");

pub const WxResult = result_mod.WxResult;

/// 菜单按钮(对应 Java `common.bean.menu.WxMenuButton`)。
/// 请求侧使用的借用规格:所有切片均为借用,调用方持有所有权。
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

pub const MenuService = struct {
    svc: *service_mod.Service,

    /// 把 `WxResult([]u8)` 折叠为 `WxResult(void)`(对应 Java 返回 void 的子服务方法,
    /// errcode!=0 已由服务层折叠成 .err,这里只需释放响应体)。
    fn discard(self: *MenuService, r: WxResult([]u8)) WxResult(void) {
        switch (r) {
            .ok => |b| {
                self.svc.gpa.free(b);
                return .{ .ok = {} };
            },
            .err => |e| return .{ .err = e },
        }
    }

    /// 对应 `WxMpMenuServiceImpl.menuCreate(WxMenu)`(无 matchrule 分支):
    /// POST `/cgi-bin/menu/create`,成功即 errcode==0(服务层已折叠 errcode!=0 为 .err)。
    pub fn create(self: *MenuService, io: std.Io, menu: MenuSpec) WxResult(void) {
        if (menu.match_rule != null) {
            // 与 Java 语义一致:带规则应走 createConditional。
            return .{ .err = error_mod.WxError.configError(self.svc.gpa, "带 matchrule 的菜单请用 createConditional", .{}) };
        }
        const gpa = self.svc.gpa;
        const body = menuToJson(gpa, menu) catch
            return .{ .err = error_mod.WxError.internal(gpa, "menu json: 序列化失败", .{}) };
        defer gpa.free(body);

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, "cgi-bin/menu/create" }) catch
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        return self.discard(self.svc.post(io, uri, &.{}, body));
    }

    /// 对应 `menuCreate` 的 matchRule != null 分支:POST addconditional。
    /// 成功返回 menuid(对应 Java 从响应取 `menuid` 字段;gpa 分配,调用方释放)。
    pub fn createConditional(self: *MenuService, io: std.Io, menu: MenuSpec) WxResult([]u8) {
        const gpa = self.svc.gpa;
        if (menu.match_rule == null) {
            return .{ .err = error_mod.WxError.configError(gpa, "createConditional 需要 match_rule", .{}) };
        }
        const body = menuToJson(gpa, menu) catch
            return .{ .err = error_mod.WxError.internal(gpa, "menu json: 序列化失败", .{}) };
        defer gpa.free(body);

        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, "cgi-bin/menu/addconditional" }) catch
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        const resp = switch (self.svc.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);

        const parsed = json_util.parse(gpa, resp) catch return .{
            .err = error_mod.WxError.transport(gpa, "addconditional 响应非 JSON", .{}),
        };
        defer parsed.deinit();
        const menuid = json_util.getStr(parsed.value, "menuid") orelse return .{
            .err = error_mod.WxError.transport(gpa, "响应缺少 menuid", .{}),
        };
        return .{ .ok = gpa.dupe(u8, menuid) catch
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `WxMpMenuServiceImpl.menuGet()`:GET `/cgi-bin/menu/get`。
    /// 特殊语义(与 Java 相同):errcode==46003(不存在的菜单数据)折叠为 `.ok(null)`;
    /// 成功时返回原始 JSON,用 `buttonsFromJson` 解析按钮。
    pub fn get(self: *MenuService, io: std.Io) WxResult(?MenuGet) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, service_mod.ApiUrl.menu_get.asUri() }) catch
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);

        switch (self.svc.get(io, uri, &.{})) {
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

    /// 对应 `WxMpMenuServiceImpl.menuDelete()`:GET `/cgi-bin/menu/delete`。
    pub fn delete(self: *MenuService, io: std.Io) WxResult(void) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}{s}", .{ service_mod.api_host_url, service_mod.ApiUrl.menu_delete.asUri() }) catch
            return .{ .err = error_mod.WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        return self.discard(self.svc.get(io, uri, &.{}));
    }
};

// ---------------------------------------------------------------------------
// 测试:mock executor 记录 method/uri/body,断言请求与响应解析。
// ---------------------------------------------------------------------------

/// 记录型 mock(照 `user.zig` 的 StubExecutor vtable 方式,额外捕获请求)。
const MockExec = struct {
    gpa: std.mem.Allocator,
    resp: []const u8,
    calls: usize = 0,
    last_method: http_mod.RequestExecutor.Method = .get,
    last_uri: []u8 = &.{},
    last_body: []u8 = &.{},

    fn executor(self: *MockExec) http_mod.RequestExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &.{ .execute = execImpl } };
    }

    fn deinit(self: *MockExec) void {
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
    }

    fn execImpl(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, method: http_mod.RequestExecutor.Method, uri: []const u8, body: ?[]const u8) WxResult([]u8) {
        _ = io;
        const self: *MockExec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_method = method;
        if (self.last_uri.len > 0) self.gpa.free(self.last_uri);
        if (self.last_body.len > 0) self.gpa.free(self.last_body);
        self.last_uri = gpa.dupe(u8, uri) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        self.last_body = gpa.dupe(u8, body orelse "") catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) };
        return .{ .ok = gpa.dupe(u8, self.resp) catch return .{ .err = error_mod.WxError.transport(gpa, "oom", .{}) } };
    }
};

/// 测试公共脚手架:假 token 的 config(对应 user.zig 测试样板)。
/// 注意:`service()` 必须在 TestCtx 定址稳定(调用方栈上)后调用,
/// 因为 ConfigStorage 持有指向 cfg 的指针。
const TestCtx = struct {
    threaded: std.Io.Threaded,
    cfg: config_mod.InMemoryConfigStorage,

    const FakeFetch = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator, i: std.Io) token_mod.FetchOutcome {
            _ = c;
            _ = i;
            const t = g.dupe(u8, "TOK") catch return .{ .err = error_mod.WxError.transport(g, "oom", .{}) };
            return .{ .ok = .{ .token = t, .expires_in = 7200 } };
        }
    };

    fn init(gpa: std.mem.Allocator) !TestCtx {
        const threaded = std.Io.Threaded.init(gpa, .{});
        const cfg = try config_mod.InMemoryConfigStorage.init(gpa, .{ .ptr = undefined, .vtable = &.{ .fetch = FakeFetch.f } }, .{ .appid = "A", .secret = "S" });
        return .{ .threaded = threaded, .cfg = cfg };
    }

    fn deinit(self: *TestCtx) void {
        self.cfg.deinit();
        self.threaded.deinit();
    }

    fn io(self: *TestCtx) std.Io {
        return self.threaded.io();
    }

    fn service(self: *TestCtx, exec: http_mod.RequestExecutor) service_mod.Service {
        return service_mod.Service.init(self.cfg.gpa, self.cfg.config(), exec);
    }
};

const http_mod = @import("../http.zig");
const token_mod = @import("common").token;
const config_mod = @import("../config.zig");

test "menu create posts button json" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var menu_svc = MenuService{ .svc = &svc };
    const menu = MenuSpec{ .buttons = &.{
        .{ .type = "click", .name = "今日指南", .key = "V1001_TODAY" },
        .{ .name = "操作指南", .sub_buttons = &.{
            .{ .type = "view", .name = "微官网", .url = "http://weixin.qq.com/" },
        } },
    } };
    const r = menu_svc.create(ctx.io(), menu);
    switch (r) {
        .ok => {},
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    try std.testing.expectEqual(http_mod.RequestExecutor.Method.post, mock.last_method);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "cgi-bin/menu/create") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "access_token=TOK") != null);

    // 断言请求 body 字段
    var body = try json_util.parse(gpa, mock.last_body);
    defer body.deinit();
    const buttons = json_util.getArray(body.value, "button").?;
    try std.testing.expectEqual(@as(usize, 2), buttons.items.len);
    try std.testing.expectEqualStrings("click", json_util.getStr(buttons.items[0], "type").?);
    try std.testing.expectEqualStrings("今日指南", json_util.getStr(buttons.items[0], "name").?);
    try std.testing.expectEqualStrings("V1001_TODAY", json_util.getStr(buttons.items[0], "key").?);
    const subs = json_util.getArray(buttons.items[1], "sub_button").?;
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqualStrings("http://weixin.qq.com/", json_util.getStr(subs.items[0], "url").?);
}

test "menu create error code surfaces WxError" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":40018,\"errmsg\":\"invalid button name size\"}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var menu_svc = MenuService{ .svc = &svc };
    const r = menu_svc.create(ctx.io(), .{ .buttons = &.{.{ .name = "x" }} });
    switch (r) {
        .ok => return error.ExpectedError,
        .err => |e| {
            var err = e;
            defer err.deinit();
            try std.testing.expectEqual(@as(i64, 40018), err.error_code);
        },
    }
}

test "menu get parses buttons; 46003 folds to null" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp =
        \\{"menu":{"button":[{"type":"click","name":"a","key":"K"},{"name":"g","sub_button":[{"type":"view","name":"v","url":"http://x"}]}]}}
    };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var menu_svc = MenuService{ .svc = &svc };
    const r = menu_svc.get(ctx.io());
    switch (r) {
        .ok => |maybe| {
            var mg = maybe.?;
            defer mg.deinit();
            try std.testing.expectEqual(http_mod.RequestExecutor.Method.get, mock.last_method);
            try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "cgi-bin/menu/get") != null);

            const buttons = try buttonsFromJson(gpa, mg.raw);
            defer deinitButtons(gpa, buttons);
            try std.testing.expectEqual(@as(usize, 2), buttons.len);
            try std.testing.expectEqualStrings("click", buttons[0].type.?);
            try std.testing.expectEqualStrings("K", buttons[0].key.?);
            try std.testing.expectEqual(@as(usize, 1), buttons[1].sub_buttons.len);
            try std.testing.expectEqualStrings("http://x", buttons[1].sub_buttons[0].url.?);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }

    // 46003 → null(对应 Java menuGet 捕获 46003 返回 null)
    mock.resp = "{\"errcode\":46003,\"errmsg\":\"menu not exist\"}";
    const r2 = menu_svc.get(ctx.io());
    switch (r2) {
        .ok => |maybe| try std.testing.expectEqual(@as(?MenuGet, null), maybe),
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
}

test "menu delete uses GET menu/delete" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var menu_svc = MenuService{ .svc = &svc };
    const r = menu_svc.delete(ctx.io());
    try std.testing.expect(!r.failed());
    try std.testing.expectEqual(http_mod.RequestExecutor.Method.get, mock.last_method);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "cgi-bin/menu/delete") != null);
}

test "menu create conditional returns menuid" {
    const gpa = std.testing.allocator;
    var mock = MockExec{ .gpa = gpa, .resp = "{\"errcode\":0,\"errmsg\":\"ok\",\"menuid\":\"1234\"}" };
    defer mock.deinit();
    var ctx = try TestCtx.init(gpa);
    defer ctx.deinit();
    var svc = ctx.service(mock.executor());

    var menu_svc = MenuService{ .svc = &svc };
    const menu = MenuSpec{
        .buttons = &.{.{ .type = "view", .name = "v", .url = "http://a" }},
        .match_rule = "{\"tag_id\":\"100\"}",
    };
    const r = menu_svc.createConditional(ctx.io(), menu);
    switch (r) {
        .ok => |menuid| {
            defer gpa.free(menuid);
            try std.testing.expectEqualStrings("1234", menuid);
        },
        .err => |e| {
            var err = e;
            defer err.deinit();
            return error.Unexpected;
        },
    }
    try std.testing.expect(std.mem.indexOf(u8, mock.last_uri, "cgi-bin/menu/addconditional") != null);
    var body = try json_util.parse(gpa, mock.last_body);
    defer body.deinit();
    try std.testing.expect(json_util.objectOf(body.value, "matchrule") != null);
}
