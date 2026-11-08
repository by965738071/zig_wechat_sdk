//! JSON 工具 —— 对应 Java `util/json` 包（GsonHelper / WxGsonBuilder / GsonParser）。
//!
//! Java 端用 Gson + 大量 TypeAdapter；Zig 端直接用 `std.json`：
//! - 解析微信响应优先用动态 `std.json.Value`（对应 Gson 的 JsonObject 取字段模式，
//!   即 `GsonHelper.getAsString` 一族）；
//! - 需要强类型时用 `std.json.parseFromSlice(MyStruct, ...)`（字段名与 JSON 不一致时
//!   靠 `std.json.fieldNameCase` 或手写适配，对应 Java 的 TypeAdapter 思路）；
//! - 序列化用 `std.json.Stringify`（对应 `WxGsonBuilder.create().toJson`）。
const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;

/// 对应 Java `GsonParser.parseString`。
pub fn parse(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, json, .{});
}

pub const ParseError = error{ ExpectedObject, ExpectedArray, BadType };

/// 对应 Java `GsonHelper.getAsJsonObject`。
pub fn object(v: Value) ?ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn objectOf(root: Value, key: []const u8) ?ObjectMap {
    const o = object(root) orelse return null;
    const child = o.get(key) orelse return null;
    return object(child);
}

/// 对应 `GsonHelper.getAsString(obj, key)`；非字符串返回 null。
pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const o = object(v) orelse return null;
    const c = o.get(key) orelse return null;
    return switch (c) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

/// 对应 `GsonHelper.getAsInteger`；缺失或非数值返回 null。
pub fn getInt(v: Value, key: []const u8) ?i64 {
    const o = object(v) orelse return null;
    const c = o.get(key) orelse return null;
    return switch (c) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn getBool(v: Value, key: []const u8) ?bool {
    const o = object(v) orelse return null;
    const c = o.get(key) orelse return null;
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getArray(v: Value, key: []const u8) ?std.ArrayList(Value) {
    const o = object(v) orelse return null;
    const c = o.get(key) orelse return null;
    return switch (c) {
        .array => |a| a,
        else => null,
    };
}

/// 对应 `GsonHelper.getAsString` 带默认值的变体。
pub fn getStrOr(v: Value, key: []const u8, default: []const u8) []const u8 {
    return getStr(v, key) orelse default;
}

pub fn getIntOr(v: Value, key: []const u8, default: i64) i64 {
    return getInt(v, key) orelse default;
}

/// 序列化任意可 JSON 化的值（结构体、json.Value 等）。
/// 对应 `WxGsonBuilder.create().toJson(obj)`。
pub fn stringify(allocator: std.mem.Allocator, v: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .escape_unicode = false } };
    try s.write(v);
    return out.toOwnedSlice();
}

/// 请求体构造器：有序对象 → JSON 字符串。
/// 对应 Java 里手工 new JsonObject 再 toJson 的模式。
pub const ObjectBuilder = struct {
    gpa: std.mem.Allocator,
    map: ObjectMap = .empty,
    array_map: ObjectMap = .empty, // 备用：如需先收集

    pub fn init(gpa: std.mem.Allocator) ObjectBuilder {
        return .{ .gpa = gpa };
    }

    pub fn putStr(self: *ObjectBuilder, key: []const u8, value: []const u8) !void {
        try self.map.put(self.gpa, key, .{ .string = value });
    }

    pub fn putInt(self: *ObjectBuilder, key: []const u8, value: i64) !void {
        try self.map.put(self.gpa, key, .{ .integer = value });
    }

    pub fn putBool(self: *ObjectBuilder, key: []const u8, value: bool) !void {
        try self.map.put(self.gpa, key, .{ .bool = value });
    }

    pub fn putValue(self: *ObjectBuilder, key: []const u8, value: Value) !void {
        try self.map.put(self.gpa, key, value);
    }

    pub fn deinit(self: *ObjectBuilder) void {
        self.map.deinit(self.gpa);
    }

    pub fn toJson(self: *ObjectBuilder) ![]u8 {
        return stringify(self.gpa, Value{ .object = self.map });
    }
};

test "json helpers" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "{\"a\":\"s\",\"n\":42,\"o\":{\"x\":true}}");
    defer p.deinit();
    try std.testing.expectEqualStrings("s", getStr(p.value, "a").?);
    try std.testing.expectEqual(@as(i64, 42), getInt(p.value, "n").?);
    try std.testing.expectEqual(@as(i64, 7), getIntOr(p.value, "missing", 7));
    const o = objectOf(p.value, "o").?;
    try std.testing.expectEqual(@as(?bool, true), objectToBool(o, "x"));
}

fn objectToBool(o: ObjectMap, key: []const u8) ?bool {
    const c = o.get(key) orelse return null;
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}
