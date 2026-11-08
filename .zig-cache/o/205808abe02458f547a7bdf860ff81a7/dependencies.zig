pub const packages = struct {
    pub const @"vendor/zig-rsa" = struct {
        pub const build_root = "vendor/zig-rsa";
        pub const build_zig = @import("vendor/zig-rsa");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zig-rsa", "vendor/zig-rsa" },
};
