pub fn loadOrGenerateCache(allocator: Allocator, godot_path: []const u8, cache_dir: []const u8) !CacheFile {
    try cache.ensureDirectoryExists(cache_dir);

    const parsed_path = try cache.getParsedCachePathInDir(allocator, cache_dir);
    defer allocator.free(parsed_path);

    const json_path = try cache.getJsonCachePathInDir(allocator, cache_dir);
    defer allocator.free(json_path);

    return CacheFile.loadFromPath(allocator, parsed_path) catch |err| switch (err) {
        error.FileNotFound => try generateCache(allocator, godot_path, json_path, parsed_path),
        else => err,
    };
}

fn generateCache(allocator: Allocator, godot_path: []const u8, json_path: []const u8, destination_path: []const u8) !CacheFile {
    _ = godot_path; // autofix

    if (std.fs.path.dirname(destination_path)) |dir| {
        try cache.ensureDirectoryExists(dir);
    }

    var json_file = try std.fs.openFileAbsolute(json_path, .{});
    defer json_file.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // const db = try DocDatabase.loadFromJsonFileLeaky(arena.allocator(), json_file);
    // const data = try db.toBytesAlloc(allocator);

    return CacheFile.init(&.{});
}

pub fn generateApiJson(allocator: Allocator, godot_path: []const u8, destination_dir: []const u8) !void {
    const result = try Child.run(.{
        .cwd = destination_dir,
        .argv = &[_][]const u8{ godot_path, "--dump-extension-api-with-docs" },
        .allocator = allocator,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                return error.GodotExecutionFailed;
            }
        },
        else => return error.GodotExecutionFailed,
    }
}

// Tests for generateApiJson function

test "generateApiJson executes godot and creates extension_api.json in cache" {
    const allocator = std.testing.allocator;

    // Create a fake godot script that creates extension_api.json
    // We'll use a shell script to simulate godot's behavior
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const fake_godot = try std.fmt.allocPrint(allocator, "{s}/fake-godot.sh", .{tmp_path});
    defer allocator.free(fake_godot);

    // Create fake godot script that writes extension_api.json
    const script_content =
        \\#!/bin/sh
        \\echo '{"version": "test"}' > extension_api.json
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "fake-godot.sh", .data = script_content });

    // Make it executable
    var file = try tmp_dir.dir.openFile("fake-godot.sh", .{});
    try file.chmod(0o755);
    file.close();

    // Generate the API JSON
    try generateApiJson(allocator, fake_godot, tmp_path);

    // Verify the JSON file was created in cache directory
    const json_path = try std.fmt.allocPrint(allocator, "{s}/extension_api.json", .{tmp_path});
    defer allocator.free(json_path);

    const json_data = try std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 1024);
    defer allocator.free(json_data);

    // Should contain the test JSON
    try std.testing.expect(std.mem.indexOf(u8, json_data, "test") != null);
}

test "generateApiJson returns error when godot executable not found" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const non_existant_godot = try std.fmt.allocPrint(allocator, "{s}/godot", .{tmp_path});
    defer allocator.free(non_existant_godot);

    const result = generateApiJson(allocator, non_existant_godot, "");

    try std.testing.expectError(error.FileNotFound, result);
}

test "generateApiJson returns error on non-zero exit code" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Use 'false' command which always exits with code 1
    const result = generateApiJson(allocator, "false", tmp_path);

    try std.testing.expectError(error.GodotExecutionFailed, result);
}

test "loadOrGenerateCache loads existing parsed cache" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a valid parsed cache file
    const test_data = "cached API data";
    var crc32 = std.hash.Crc32.init();
    crc32.update(test_data);

    const cache_file = cache.CacheFile{
        .header = cache.CacheHeader{
            .magic = 'G' << 24 | 'D' << 16 | 'O' << 8 | 'C',
            .version = 1,
            .checksum = crc32.final(),
        },
        .data = test_data,
    };

    const parsed_path = try std.fmt.allocPrint(allocator, "{s}/extension_api.parsed", .{tmp_path});
    defer allocator.free(parsed_path);

    try cache_file.saveToPath(parsed_path);

    // Call loadOrGenerateCache - should load the parsed cache
    const fake_godot = "/nonexistent/godot";
    const result = try loadOrGenerateCache(allocator, fake_godot, tmp_path);
    defer result.deinit(allocator);

    // Should have loaded the cached data
    try std.testing.expectEqualStrings(test_data, result.data);
}

// test "loadOrGenerateCache falls back to JSON when parsed cache missing" {
//     const allocator = std.testing.allocator;

//     var tmp_dir = std.testing.tmpDir(.{});
//     defer tmp_dir.cleanup();

//     const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
//     defer allocator.free(tmp_path);

//     // Create JSON cache file (but no parsed cache)
//     const json_data = "{\"builtin_classes\": [{\"name\": \"Node\"}, {\"name\": \"Node2D\"}]}";
//     const json_path = try cache.getJsonCachePathInDir(allocator, tmp_path);
//     defer allocator.free(json_path);

//     var json_file = try std.fs.createFileAbsolute(json_path, .{});
//     defer json_file.close();
//     try json_file.writeAll(json_data);

//     // Call loadOrGenerateCache - should parse JSON and create parsed cache
//     const fake_godot = "/nonexistent/godot";
//     const result = try loadOrGenerateCache(allocator, fake_godot, tmp_path);
//     defer result.deinit(allocator);

//     // Should have loaded the JSON data
//     try std.testing.expectEqualStrings(json_data, result.data);

//     // Verify parsed cache was created
//     const parsed_path = try cache.getParsedCachePathInDir(allocator, tmp_path);
//     defer allocator.free(parsed_path);

//     const parsed_cache = try cache.CacheFile.loadFromPath(allocator, parsed_path);
//     defer parsed_cache.deinit(allocator);

//     try std.testing.expectEqualStrings(json_data, parsed_cache.data);
// }

const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

const cache = @import("cache.zig");
const CacheFile = cache.CacheFile;

const DocDatabase = @import("DocDatabase.zig");
