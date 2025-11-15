pub const DocDatabase = @import("DocDatabase.zig");

pub fn getCacheDir(allocator: Allocator) ![]const u8 {
    const cache_dir = try known_folders.getPath(allocator, .cache);
    defer if (cache_dir) |cd| allocator.free(cd);

    std.debug.assert(cache_dir != null);

    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir.?, "gdoc" })},
    );
}

test "getCacheDir returns cache directory path" {
    const allocator = std.testing.allocator;

    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    // Should return a non-empty path
    try std.testing.expect(cache_dir.len > 0);

    // Should end with "gdoc"
    try std.testing.expect(std.mem.endsWith(u8, cache_dir, "gdoc"));

    // Should be an absolute path (starts with / on Unix or contains : on Windows)
    const is_absolute = cache_dir[0] == '/' or
        (cache_dir.len > 2 and cache_dir[1] == ':');
    try std.testing.expect(is_absolute);
}

// Import tests from other modules
comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");
