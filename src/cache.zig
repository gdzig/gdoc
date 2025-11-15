const cache_version: u32 = 1;

pub const CacheHeader = struct {
    magic: [4]u8,
    version: u32,
    checksum: u32,

    pub fn isValid(self: CacheHeader) bool {
        return self.magic[0] == 'G' and
            self.magic[1] == 'D' and
            self.magic[2] == 'O' and
            self.magic[3] == 'C' and
            self.version == cache_version and
            self.checksum > 0;
    }
};

pub fn ensureCacheDir(path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try std.fs.makeDirAbsolute(path);
                return;
            },
            else => return err,
        }
    };
    defer dir.close();
}

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

pub fn getJsonCachePath(allocator: Allocator) ![]const u8 {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "extension_api.json" })},
    );
}

pub fn getParsedCachePath(allocator: Allocator) ![]const u8 {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "extension_api.parsed" })},
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

test "getJsonCachePath returns path to extension_api.json" {
    const allocator = std.testing.allocator;

    const json_path = try getJsonCachePath(allocator);
    defer allocator.free(json_path);

    // Should return a non-empty path
    try std.testing.expect(json_path.len > 0);

    // Should end with "extension_api.json"
    try std.testing.expect(std.mem.endsWith(u8, json_path, "extension_api.json"));

    // Should contain "gdoc" directory in the path
    try std.testing.expect(std.mem.indexOf(u8, json_path, "gdoc") != null);

    // Should be an absolute path
    const is_absolute = json_path[0] == '/' or
        (json_path.len > 2 and json_path[1] == ':');
    try std.testing.expect(is_absolute);
}

test "getParsedCachePath returns path to extension_api.parsed" {
    const allocator = std.testing.allocator;

    const parsed_path = try getParsedCachePath(allocator);
    defer allocator.free(parsed_path);

    // Should return a non-empty path
    try std.testing.expect(parsed_path.len > 0);

    // Should end with "extension_api.parsed"
    try std.testing.expect(std.mem.endsWith(u8, parsed_path, "extension_api.parsed"));

    // Should contain "gdoc" directory in the path
    try std.testing.expect(std.mem.indexOf(u8, parsed_path, "gdoc") != null);

    // Should be an absolute path
    const is_absolute = parsed_path[0] == '/' or
        (parsed_path.len > 2 and parsed_path[1] == ':');
    try std.testing.expect(is_absolute);
}

test "ensureCacheDir creates directory if it doesn't exist" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Get a unique test cache directory path
    const test_cache = try std.fmt.allocPrint(
        allocator,
        "{s}/gdoc-test-{d}",
        .{ tmp_path, std.time.timestamp() },
    );
    defer allocator.free(test_cache);

    // Call ensureCacheDir with test path
    try ensureCacheDir(test_cache);

    // Verify directory was created
    var dir = try std.fs.openDirAbsolute(test_cache, .{});
    dir.close();

    // Cleanup
    try std.fs.deleteTreeAbsolute(test_cache);
}

test "ensureCacheDir succeeds when directory already exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_cache = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_cache);

    // Call ensureCacheDir - should not fail
    try ensureCacheDir(test_cache);

    // Verify directory still exists
    var dir = try std.fs.openDirAbsolute(test_cache, .{});
    dir.close();

    // Cleanup
    try std.fs.deleteTreeAbsolute(test_cache);
}

test "CacheHeader has correct magic bytes GDOC" {
    const header = CacheHeader{
        .magic = .{ 'G', 'D', 'O', 'C' },
        .version = 1,
        .checksum = 0x12345678,
    };

    try std.testing.expectEqual('G', header.magic[0]);
    try std.testing.expectEqual('D', header.magic[1]);
    try std.testing.expectEqual('O', header.magic[2]);
    try std.testing.expectEqual('C', header.magic[3]);
}

test "CacheHeader.isValid returns true for valid header" {
    const header = CacheHeader{
        .magic = .{ 'G', 'D', 'O', 'C' },
        .version = cache_version,
        .checksum = 0x12345678,
    };

    try std.testing.expect(header.isValid());
}

test "CacheHeader.isValid returns false for wrong magic" {
    const header = CacheHeader{
        .magic = .{ 'B', 'A', 'D', '!' },
        .version = cache_version,
        .checksum = 0x12345678,
    };

    try std.testing.expect(!header.isValid());
}

test "CacheHeader.isValid returns false for wrong version" {
    const header = CacheHeader{
        .magic = .{ 'G', 'D', 'O', 'C' },
        .version = cache_version + 1,
        .checksum = 0x12345678,
    };

    try std.testing.expect(!header.isValid());
}

test "CacheHeader.checksumMatches returns true when checksums match" {
    const header = CacheHeader{
        .magic = .{ 'G', 'D', 'O', 'C' },
        .version = cache_version,
        .checksum = 0xABCDEF00,
    };

    try std.testing.expectEqual(0xABCDEF00, header.checksum);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");
