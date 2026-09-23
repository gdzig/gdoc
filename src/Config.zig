const Config = @This();

cache_dir: []const u8,

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Config {
    const cache_dir = environ.getAlloc(allocator, "GDOC_CACHE_DIR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => blk: {
            var environ_map = try environ.createMap(allocator);
            defer environ_map.deinit();

            const base = try known_folders.getPath(io, allocator, &environ_map, .cache);
            defer if (base) |b| allocator.free(b);
            break :blk try std.fmt.allocPrint(allocator, "{f}", .{
                std.fs.path.fmtJoin(&[_][]const u8{ base orelse "/tmp", "gdoc" }),
            });
        },
        else => return err,
    };

    return .{
        .cache_dir = cache_dir,
    };
}

pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
    allocator.free(self.cache_dir);
}

pub const testing: Config = .{
    .cache_dir = "/tmp/gdoc-test-cache",
};

test "init" {
    const config = try Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(config.cache_dir.len > 0);
}

test "testing config" {
    try std.testing.expectEqualStrings("/tmp/gdoc-test-cache", Config.testing.cache_dir);
}

const std = @import("std");
const known_folders = @import("known-folders");
