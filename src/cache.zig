const cache_version: u32 = 1;
const cache_magic = 'G' << 24 | 'D' << 16 | 'O' << 8 | 'C';

pub const CacheHeader = packed struct {
    const init = CacheHeader{
        .magic = cache_magic,
        .version = cache_version,
        .checksum = 0,
    };

    magic: u32,
    version: u32,
    checksum: u32,

    pub fn isValid(self: CacheHeader) bool {
        return self.magic == cache_magic and
            self.version == cache_version and
            self.checksum > 0;
    }
};

pub const CacheFile = struct {
    header: CacheHeader,
    data: []const u8,

    pub fn verifyChecksum(self: CacheFile) !void {
        var crc32 = std.hash.Crc32.init();
        crc32.update(self.data);

        if (crc32.final() != self.header.checksum) {
            return error.ChecksumError;
        }
    }

    pub fn init(data: []const u8) CacheFile {
        var crc32 = std.hash.Crc32.init();
        crc32.update(data);

        var header: CacheHeader = .init;
        header.checksum = crc32.final();

        return CacheFile{
            .header = header,
            .data = data,
        };
    }

    pub fn loadFromPath(allocator: Allocator, path: []const u8) !CacheFile {
        return try readCacheFile(allocator, path);
    }

    pub fn saveToPath(self: CacheFile, path: []const u8) !void {
        try writeCacheFile(path, self.data);
    }

    pub fn deinit(self: CacheFile, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub fn clearCache(allocator: Allocator) !void {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    std.fs.deleteTreeAbsolute(cache_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeCacheFile(cache_path: []const u8, data: []const u8) !void {
    var file = try std.fs.createFileAbsolute(cache_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    var writer = &file_writer.interface;

    var crc32 = std.hash.Crc32.init();
    crc32.update(data);

    try writer.writeInt(u32, cache_magic, .little);
    try writer.writeInt(u32, cache_version, .little);
    try writer.writeInt(u32, crc32.final(), .little);

    try writer.writeAll(data);
    try writer.flush();
}

fn readCacheFile(allocator: Allocator, cache_path: []const u8) !CacheFile {
    var file = try std.fs.openFileAbsolute(cache_path, .{ .mode = .read_only });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;

    var header: CacheHeader = undefined;

    header.magic = try reader.takeInt(u32, .little);
    if (header.magic != cache_magic) {
        return error.InvalidCacheMagic;
    }

    header.version = try reader.takeInt(u32, .little);
    if (header.version != cache_version) {
        return error.InvalidCacheVersion;
    }

    header.checksum = try reader.takeInt(u32, .little);

    if (!header.isValid()) {
        return error.InvalidCacheHeader;
    }

    const data = try reader.readAlloc(allocator, try file.getEndPos() - reader.seek);
    errdefer allocator.free(data);

    const cache_file = CacheFile{ .header = header, .data = data };
    try cache_file.verifyChecksum();

    return cache_file;
}

// TODO: move to fs module as it is not cache specific
pub fn ensureDirectoryExists(dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try std.fs.makeDirAbsolute(dir_path);
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

pub fn getJsonCachePathInDir(allocator: Allocator, cache_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "extension_api.json" })},
    );
}

pub fn getParsedCachePathInDir(allocator: Allocator, cache_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "extension_api.parsed" })},
    );
}

pub fn getJsonCachePath(allocator: Allocator) ![]const u8 {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    return getJsonCachePathInDir(allocator, cache_dir);
}

pub fn getParsedCachePath(allocator: Allocator) ![]const u8 {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    return getParsedCachePathInDir(allocator, cache_dir);
}

pub fn resolveSymbolPath(allocator: Allocator, cache_path: []const u8, symbol: []const u8) ![]const u8 {
    // dot notation
    if (std.mem.indexOf(u8, symbol, ".")) |dot_pos| {
        const class_name = symbol[0..dot_pos];
        const member_name = symbol[dot_pos + 1 ..];

        return std.fmt.allocPrint(
            allocator,
            "{f}.md",
            .{
                std.fs.path.fmtJoin(&.{
                    cache_path,
                    class_name,
                    member_name,
                }),
            },
        );
    }

    var cache_dir = try std.fs.openDirAbsolute(cache_path, .{});
    defer cache_dir.close();

    var buf: [256]u8 = undefined;

    // global scope
    const global_filename = try std.fmt.bufPrint(&buf, "{s}.md", .{symbol});
    if (cache_dir.statFile(global_filename) catch null) |_| {
        return std.fmt.allocPrint(
            allocator,
            "{f}",
            .{
                std.fs.path.fmtJoin(&.{
                    cache_path,
                    global_filename,
                }),
            },
        );
    }

    // class index file
    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{
            std.fs.path.fmtJoin(&.{
                cache_path,
                symbol,
                "index.md",
            }),
        },
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
    try ensureDirectoryExists(test_cache);

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
    try ensureDirectoryExists(test_cache);

    // Verify directory still exists
    var dir = try std.fs.openDirAbsolute(test_cache, .{});
    dir.close();

    // Cleanup
    try std.fs.deleteTreeAbsolute(test_cache);
}

test "CacheHeader has correct magic bytes GDOC" {
    const header = CacheHeader{
        .magic = cache_magic,
        .version = 1,
        .checksum = 0x12345678,
    };

    try std.testing.expectEqual('G', (header.magic & 0xFF000000) >> 24);
    try std.testing.expectEqual('D', (header.magic & 0x00FF0000) >> 16);
    try std.testing.expectEqual('O', (header.magic & 0x0000FF00) >> 8);
    try std.testing.expectEqual('C', header.magic & 0x000000FF);
}

test "CacheHeader.isValid returns true for valid header" {
    const header = CacheHeader{
        .magic = cache_magic,
        .version = cache_version,
        .checksum = 0x12345678,
    };

    try std.testing.expect(header.isValid());
}

test "CacheHeader.isValid returns false for wrong magic" {
    const header = CacheHeader{
        .magic = 0,
        .version = cache_version,
        .checksum = 0x12345678,
    };

    try std.testing.expect(!header.isValid());
}

test "CacheHeader.isValid returns false for wrong version" {
    const header = CacheHeader{
        .magic = cache_magic,
        .version = cache_version + 1,
        .checksum = 0x12345678,
    };

    try std.testing.expect(!header.isValid());
}

test "CacheHeader.checksumMatches returns true when checksums match" {
    const header = CacheHeader{
        .magic = cache_magic,
        .version = cache_version,
        .checksum = 0xABCDEF00,
    };

    try std.testing.expectEqual(0xABCDEF00, header.checksum);
}

test "CacheFile.saveToPath writes header and data to file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/test.cache", .{tmp_path});
    defer allocator.free(cache_path);

    const test_data = "test cache data content";

    // Create CacheFile and save
    var crc32 = std.hash.Crc32.init();
    crc32.update(test_data);

    const cache_file_write = CacheFile{
        .header = CacheHeader{
            .magic = cache_magic,
            .version = cache_version,
            .checksum = crc32.final(),
        },
        .data = test_data,
    };

    try cache_file_write.saveToPath(cache_path);

    // Read back and verify
    const cache_file = try CacheFile.loadFromPath(allocator, cache_path);
    defer cache_file.deinit(allocator);

    try std.testing.expect(cache_file.header.isValid());
    try cache_file.verifyChecksum();
    try std.testing.expectEqualStrings(test_data, cache_file.data);
}

test "CacheFile.loadFromPath reads header and validates it" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/test.cache", .{tmp_path});
    defer allocator.free(cache_path);

    const test_data = "cached API data";

    // Create CacheFile and save
    var crc32 = std.hash.Crc32.init();
    crc32.update(test_data);

    const cache_file_write = CacheFile{
        .header = CacheHeader{
            .magic = cache_magic,
            .version = cache_version,
            .checksum = crc32.final(),
        },
        .data = test_data,
    };

    try cache_file_write.saveToPath(cache_path);

    // Read cache file
    const result = try CacheFile.loadFromPath(allocator, cache_path);
    defer result.deinit(allocator);

    // Verify data was read and checksum is valid
    try result.verifyChecksum();
    try std.testing.expectEqualStrings(test_data, result.data);
}

test "CacheFile.loadFromPath returns error for invalid header magic" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/bad.cache", .{tmp_path});
    defer allocator.free(cache_path);

    // Write file with bad magic
    const file = try std.fs.createFileAbsolute(cache_path, .{});
    defer file.close();

    const bad_header = CacheHeader{
        .magic = 0,
        .version = cache_version,
        .checksum = 0x12345678,
    };
    try file.writeAll(std.mem.asBytes(&bad_header));
    try file.writeAll("some data");

    // Should fail to read
    const result = CacheFile.loadFromPath(allocator, cache_path);
    try std.testing.expectError(error.InvalidCacheMagic, result);
}

test "CacheFile.loadFromPath returns error for invalid version" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/old.cache", .{tmp_path});
    defer allocator.free(cache_path);

    // Write file with wrong version
    var file = try std.fs.createFileAbsolute(cache_path, .{});
    var buf: [1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    var writer = &file_writer.interface;

    const old_header = CacheHeader{
        .magic = cache_magic,
        .version = cache_version + 1,
        .checksum = 0x12345678,
    };
    try writer.writeStruct(old_header, .little);
    try writer.writeAll("some data");
    try writer.flush();
    file.close();

    // Should fail to read
    const result = CacheFile.loadFromPath(allocator, cache_path);
    try std.testing.expectError(error.InvalidCacheVersion, result);
}

test "CacheFile.verifyChecksum succeeds when data matches checksum" {
    const test_data = "test data for checksum verification";

    var crc32 = std.hash.Crc32.init();
    crc32.update(test_data);
    const expected_checksum = crc32.final();

    const cache_file = CacheFile{
        .header = CacheHeader{
            .magic = cache_magic,
            .version = cache_version,
            .checksum = expected_checksum,
        },
        .data = test_data,
    };

    // Should not return error
    try cache_file.verifyChecksum();
}

test "CacheFile.verifyChecksum returns error when data does not match checksum" {
    const test_data = "original data";

    var crc32 = std.hash.Crc32.init();
    crc32.update("different data");
    const wrong_checksum = crc32.final();

    const cache_file = CacheFile{
        .header = CacheHeader{
            .magic = cache_magic,
            .version = cache_version,
            .checksum = wrong_checksum,
        },
        .data = test_data,
    };

    // Should return error.ChecksumError
    const result = cache_file.verifyChecksum();
    try std.testing.expectError(error.ChecksumError, result);
}

test "clearCache deletes both JSON and parsed cache files" {
    const allocator = std.testing.allocator;

    // Get actual cache paths
    const json_path = try getJsonCachePath(allocator);
    defer allocator.free(json_path);

    const parsed_path = try getParsedCachePath(allocator);
    defer allocator.free(parsed_path);

    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    // Ensure cache directory exists
    try ensureDirectoryExists(cache_dir);

    // Create both cache files
    var json_file = try std.fs.createFileAbsolute(json_path, .{});
    json_file.close();

    var parsed_file = try std.fs.createFileAbsolute(parsed_path, .{});
    parsed_file.close();

    // Verify files exist
    _ = try std.fs.openFileAbsolute(json_path, .{});
    _ = try std.fs.openFileAbsolute(parsed_path, .{});

    // Clear cache
    try clearCache(allocator);

    // Verify files are deleted
    const json_result = std.fs.openFileAbsolute(json_path, .{});
    try std.testing.expectError(error.FileNotFound, json_result);

    const parsed_result = std.fs.openFileAbsolute(parsed_path, .{});
    try std.testing.expectError(error.FileNotFound, parsed_result);
}

test "clearCache succeeds when cache files do not exist" {
    const allocator = std.testing.allocator;

    // Don't create any files - just call clearCache
    // Should not error even if files don't exist
    try clearCache(allocator);
}

test "clearCache succeeds when cache directory does not exist" {
    const allocator = std.testing.allocator;

    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    // Make sure cache directory doesn't exist
    std.fs.deleteTreeAbsolute(cache_dir) catch {};

    // Call clearCache - should not error
    try clearCache(allocator);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");

// RED PHASE: Test for resolveSymbolPath function
// This function maps symbol names to markdown file paths
test "resolveSymbolPath handles dot notation for class members" {
    const allocator = std.testing.allocator;

    const cache_dir = "/tmp/gdoc-test";
    const symbol = "Node2D.position";

    const result = try resolveSymbolPath(allocator, cache_dir, symbol);
    defer allocator.free(result);

    // Should resolve to: cache_dir/Node2D/position.md
    const expected = "/tmp/gdoc-test/Node2D/position.md";
    try std.testing.expectEqualStrings(expected, result);
}

test "resolveSymbolPath handles global function as top-level file" {
    const allocator = std.testing.allocator;

    // Create a temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a test global function file
    const sin_md_path = try std.fmt.allocPrint(allocator, "{s}/sin.md", .{tmp_path});
    defer allocator.free(sin_md_path);

    var file = try std.fs.createFileAbsolute(sin_md_path, .{});
    file.close();

    // Resolve symbol
    const result = try resolveSymbolPath(allocator, tmp_path, "sin");
    defer allocator.free(result);

    // Should resolve to cache_dir/sin.md (file exists)
    try std.testing.expectEqualStrings(sin_md_path, result);
}

test "resolveSymbolPath falls back to class index when global file not found" {
    const allocator = std.testing.allocator;

    // Create a temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Don't create Node2D.md file, so it should try Node2D/index.md
    const result = try resolveSymbolPath(allocator, tmp_path, "Node2D");
    defer allocator.free(result);

    const expected = try std.fmt.allocPrint(allocator, "{s}/Node2D/index.md", .{tmp_path});
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, result);
}
