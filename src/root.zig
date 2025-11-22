pub const LookupError = error{
    ApiFileNotFound,
} || Writer.Error || DocDatabase.Error || File.OpenError;

pub fn lookupAndDisplay(allocator: Allocator, symbol: []const u8, api_json_path: ?[]const u8, writer: *Writer) !void {
    const api_json_file = if (api_json_path) |path| std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return LookupError.ApiFileNotFound,
        else => return err,
    } else null;
    defer if (api_json_file) |f| f.close();

    if (api_json_file) |f| {
        var arena = ArenaAllocator.init(allocator);
        defer arena.deinit();

        const db = try DocDatabase.loadFromJsonFileLeaky(arena.allocator(), f);
        const entry = try db.lookupSymbolExact(symbol);

        try writer.print("# {s}\n", .{symbol});

        if (entry.brief_description) |brief| {
            try writer.print("\n{s}\n", .{brief});
        }

        if (entry.description) |desc| {
            try writer.print("\n## Description\n\n{s}\n", .{desc});
        }
    }
}

test "lookupAndDisplay returns ApiFileNotFound for nonexistent file" {
    const allocator = std.testing.allocator;

    // Create a temporary directory for test
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const nonexistent_path = try std.fmt.allocPrint(allocator, "{s}/nonexistent.json", .{tmp_path});
    defer allocator.free(nonexistent_path);

    // Create a discarding writer (we don't care about output for this error test)
    var buf: [4096]u8 = undefined;
    var discard = std.io.Writer.Discarding.init(&buf);

    const result = lookupAndDisplay(allocator, "Node2D", nonexistent_path, &discard.writer);

    try std.testing.expectError(LookupError.ApiFileNotFound, result);
}

test "lookupAndDisplay returns InvalidApiJson for malformed JSON" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const bad_api_path = try std.fmt.allocPrint(allocator, "{s}/bad_api.json", .{tmp_path});
    defer allocator.free(bad_api_path);

    // Write invalid JSON
    try tmp_dir.dir.writeFile(.{ .sub_path = "bad_api.json", .data = "{ invalid json" });

    var buf: [4096]u8 = undefined;
    var discard = std.io.Writer.Discarding.init(&buf);

    const result = lookupAndDisplay(allocator, "Node2D", bad_api_path, &discard.writer);

    try std.testing.expectError(DocDatabase.Error.InvalidApiJson, result);
}

test "lookupAndDisplay loads from custom API file and finds symbol" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const api_path = try std.fmt.allocPrint(allocator, "{s}/test_api.json", .{tmp_path});
    defer allocator.free(api_path);

    // Write minimal valid API JSON with a test class
    const test_json =
        \\{"builtin_classes": [{"name": "TestClass", "brief_description": "A test class"}]}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "test_api.json", .data = test_json });

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    // Should successfully load and display TestClass
    try lookupAndDisplay(allocator, "TestClass", api_path, &allocating_writer.writer);

    // Verify something was written to output
    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);
    try std.testing.expect(written.len > 0);
}

test "lookupAndDisplay returns SymbolNotFound when symbol doesn't exist" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const api_path = try std.fmt.allocPrint(allocator, "{s}/test_api.json", .{tmp_path});
    defer allocator.free(api_path);

    // Write valid API JSON but without the symbol we're looking for
    const test_json =
        \\{"builtin_classes": [{"name": "TestClass", "brief_description": "A test class"}]}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "test_api.json", .data = test_json });

    var buf: [4096]u8 = undefined;
    var discard = std.io.Writer.Discarding.init(&buf);

    // Try to look up NonExistentClass which is not in the API
    const result = lookupAndDisplay(allocator, "NonExistentClass", api_path, &discard.writer);

    try std.testing.expectError(DocDatabase.Error.SymbolNotFound, result);
}

test "lookupAndDisplay works with relative path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write minimal valid API JSON
    const test_json =
        \\{"builtin_classes": [{"name": "TestClass", "brief_description": "A test class"}]}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "test_api.json", .data = test_json });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Change to tmp directory and use relative path
    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd);
    defer std.posix.chdir(original_cwd) catch {};

    try std.posix.chdir(tmp_path);

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    // Use relative path
    try lookupAndDisplay(allocator, "TestClass", "test_api.json", &allocating_writer.writer);

    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);
    try std.testing.expect(written.len > 0);
}

comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const File = std.fs.File;
const Writer = std.Io.Writer;

const known_folders = @import("known-folders");

pub const DocDatabase = @import("DocDatabase.zig");
pub const cache = @import("cache.zig");
pub const api = @import("api.zig");
