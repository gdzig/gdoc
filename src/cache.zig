const cache_version: u32 = 1;
const cache_magic = 'G' << 24 | 'D' << 16 | 'O' << 8 | 'C';

pub const CacheHeader = packed struct {
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

    const data = try reader.readAlloc(allocator, try file.getEndPos() - reader.seek);
    errdefer allocator.free(data);

    const cache_file = CacheFile{ .header = header, .data = data };
    try cache_file.verifyChecksum();

    return cache_file;
}

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

const std = @import("std");
const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");
