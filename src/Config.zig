const std = @import("std");
const known_folders = @import("known-folders");

const Config = @This();

no_xml: bool,
cache_dir: []const u8,

pub fn init(allocator: std.mem.Allocator) !Config {
    const cache_dir = if (std.process.getEnvVarOwned(allocator, "GDOC_CACHE_DIR") catch null) |dir|
        dir
    else blk: {
        const base = try known_folders.getPath(allocator, .cache);
        defer if (base) |b| allocator.free(b);
        break :blk try std.fmt.allocPrint(allocator, "{f}", .{
            std.fs.path.fmtJoin(&[_][]const u8{ base orelse "/tmp", "gdoc" }),
        });
    };

    return .{
        .no_xml = hasEnv("GDOC_NO_XML"),
        .cache_dir = cache_dir,
    };
}

pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
    allocator.free(self.cache_dir);
}

pub const testing: Config = .{
    .no_xml = true,
    .cache_dir = "/tmp/gdoc-test-cache",
};

fn hasEnv(key: []const u8) bool {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return std.process.hasEnvVar(fba.allocator(), key) catch false;
}

test "init" {
    const config = try Config.init(std.testing.allocator);
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(config.cache_dir.len > 0);
}

test "testing config" {
    try std.testing.expect(Config.testing.no_xml);
    try std.testing.expectEqualStrings("/tmp/gdoc-test-cache", Config.testing.cache_dir);
}
