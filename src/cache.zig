pub fn clearCache(allocator: Allocator) !void {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    std.fs.deleteTreeAbsolute(cache_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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

pub fn writeSymbolMarkdown(allocator: Allocator, db: DocDatabase, symbol: []const u8, cache_path: []const u8) !void {
    const output_file_path = try resolveSymbolPath(allocator, cache_path, symbol);
    defer allocator.free(output_file_path);

    const output_dir_path = std.fs.path.dirname(output_file_path).?;
    try ensureDirectoryExists(output_dir_path);

    var output_file = try std.fs.cwd().createFile(output_file_path, .{});
    defer output_file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = output_file.writer(&buf);
    var writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(symbol, writer);
    try writer.flush();
}

pub fn readSymbolMarkdown(allocator: Allocator, symbol: []const u8, cache_path: []const u8, output: *Writer) !void {
    const symbol_path = try resolveSymbolPath(allocator, cache_path, symbol);
    defer allocator.free(symbol_path);

    const symbol_file = std.fs.openFileAbsolute(symbol_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SymbolNotFound,
        else => return err,
    };
    defer symbol_file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = symbol_file.reader(&buf);
    var reader = &file_reader.interface;

    _ = try reader.stream(output, .unlimited);
}

pub fn generateMarkdownCache(allocator: Allocator, db: DocDatabase, cache_path: []const u8) !void {
    try ensureDirectoryExists(cache_path);

    for (db.symbols.values()) |entry| {
        try writeSymbolMarkdown(allocator, db, entry.key, cache_path);
    }
}

pub fn cacheIsPopulated(allocator: Allocator, cache_path: []const u8) !bool {
    const json_file_path = try getJsonCachePathInDir(allocator, cache_path);
    defer allocator.free(json_file_path);

    const json_file = std.fs.openFileAbsolute(json_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer json_file.close();

    const node_path = try resolveSymbolPath(allocator, cache_path, "Node");
    defer allocator.free(node_path);

    const node_file = std.fs.openFileAbsolute(node_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer node_file.close();

    return true;
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


test "clearCache deletes cache directory" {
    const allocator = std.testing.allocator;

    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    // Ensure cache directory exists
    try ensureDirectoryExists(cache_dir);

    // Create JSON file and markdown files
    const json_path = try getJsonCachePathInDir(allocator, cache_dir);
    defer allocator.free(json_path);

    var json_file = try std.fs.createFileAbsolute(json_path, .{});
    json_file.close();

    const node_dir = try std.fmt.allocPrint(allocator, "{s}/Node", .{cache_dir});
    defer allocator.free(node_dir);
    try std.fs.makeDirAbsolute(node_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{node_dir});
    defer allocator.free(index_path);
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = "# Node\n" });

    // Verify files exist
    _ = try std.fs.openFileAbsolute(json_path, .{});
    _ = try std.fs.openFileAbsolute(index_path, .{});

    // Clear cache
    try clearCache(allocator);

    // Verify cache directory is deleted
    const dir_result = std.fs.openDirAbsolute(cache_dir, .{});
    try std.testing.expectError(error.FileNotFound, dir_result);
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
    const sin_md_path = try std.fmt.allocPrint(allocator, "{s}/sin/index.md", .{tmp_path});
    defer allocator.free(sin_md_path);

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

// RED PHASE: Tests for writeSymbolMarkdown
test "writeSymbolMarkdown writes global function to top-level file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a database with a global function
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const entry = DocDatabase.Entry{
        .key = "abs",
        .name = "abs",
        .kind = .global_function,
        .description = "Returns absolute value.",
        .signature = "float abs(float x)",
    };
    try db.symbols.put(allocator, "abs", entry);

    // Write the symbol markdown
    try writeSymbolMarkdown(allocator, db, "abs", cache_dir);

    // Verify file was created at correct path
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/abs/index.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try std.fs.openFileAbsolute(expected_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify content contains expected markdown
    try std.testing.expect(std.mem.indexOf(u8, content, "# abs") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Returns absolute value.") != null);
}

test "writeSymbolMarkdown writes class member with parent directory creation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a database with a class and member
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const parent = DocDatabase.Entry{
        .key = "Vector2",
        .name = "Vector2",
        .kind = .class,
    };
    try db.symbols.put(allocator, "Vector2", parent);

    const entry = DocDatabase.Entry{
        .key = "Vector2.x",
        .name = "x",
        .parent_index = 0,
        .kind = .property,
        .description = "The X coordinate.",
        .signature = "float",
    };
    try db.symbols.put(allocator, "Vector2.x", entry);

    // Write the symbol markdown
    try writeSymbolMarkdown(allocator, db, "Vector2.x", cache_dir);

    // Verify file was created at correct path with parent directory
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/x.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try std.fs.openFileAbsolute(expected_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify content
    try std.testing.expect(std.mem.indexOf(u8, content, "# Vector2.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**Parent**: Vector2") != null);
}

test "writeSymbolMarkdown writes class to index.md in subdirectory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a database with a class
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const entry = DocDatabase.Entry{
        .key = "Node3D",
        .name = "Node3D",
        .kind = .class,
        .brief_description = "3D scene node.",
    };
    try db.symbols.put(allocator, "Node3D", entry);

    // Write the symbol markdown
    try writeSymbolMarkdown(allocator, db, "Node3D", cache_dir);

    // Verify file was created at Node3D/index.md
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/Node3D/index.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try std.fs.openFileAbsolute(expected_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify content
    try std.testing.expect(std.mem.indexOf(u8, content, "# Node3D") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "3D scene node.") != null);
}

// RED PHASE: Test for generateMarkdownCache
// This function should write markdown files for ALL symbols in the database
test "generateMarkdownCache writes all symbols to cache directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a database with multiple symbols
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Add a global function
    try db.symbols.put(allocator, "abs", DocDatabase.Entry{
        .key = "abs",
        .name = "abs",
        .kind = .global_function,
        .description = "Returns absolute value.",
    });

    // Add a class
    try db.symbols.put(allocator, "Vector2", DocDatabase.Entry{
        .key = "Vector2",
        .name = "Vector2",
        .kind = .class,
        .brief_description = "2D vector.",
    });

    // Add a class member
    try db.symbols.put(allocator, "Vector2.x", DocDatabase.Entry{
        .key = "Vector2.x",
        .name = "x",
        .parent_index = 1, // Index of Vector2
        .kind = .property,
        .description = "X coordinate.",
    });

    // Generate all markdown files
    try generateMarkdownCache(allocator, db, cache_dir);

    // Verify all files were created
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/abs/index.md", .{cache_dir});
    defer allocator.free(abs_path);
    _ = try std.fs.openFileAbsolute(abs_path, .{});

    const vec2_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/index.md", .{cache_dir});
    defer allocator.free(vec2_path);
    _ = try std.fs.openFileAbsolute(vec2_path, .{});

    const x_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/x.md", .{cache_dir});
    defer allocator.free(x_path);
    _ = try std.fs.openFileAbsolute(x_path, .{});
}

test "generateMarkdownCache handles empty database" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create an empty database
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Should not error with empty database
    try generateMarkdownCache(allocator, db, cache_dir);

    // Cache directory should exist but be empty (except for . and ..)
    var dir = try std.fs.openDirAbsolute(cache_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    const first = try iter.next();
    // Empty or only has . and .. entries
    if (first) |entry| {
        try std.testing.expect(
            std.mem.eql(u8, entry.name, ".") or
                std.mem.eql(u8, entry.name, ".."),
        );
    }
}

// RED PHASE: Tests for readSymbolMarkdown
// This function should read markdown content from cache files
test "readSymbolMarkdown reads class index file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a class index file
    const node2d_dir = try std.fmt.allocPrint(allocator, "{s}/Node2D", .{cache_dir});
    defer allocator.free(node2d_dir);
    try std.fs.makeDirAbsolute(node2d_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{node2d_dir});
    defer allocator.free(index_path);

    const content = "# Node2D\n\nA 2D scene node.\n";
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, "Node2D", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

test "readSymbolMarkdown reads member file with dot notation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a member file
    const vector2_dir = try std.fmt.allocPrint(allocator, "{s}/Vector2", .{cache_dir});
    defer allocator.free(vector2_dir);
    try std.fs.makeDirAbsolute(vector2_dir);

    const x_path = try std.fmt.allocPrint(allocator, "{s}/x.md", .{vector2_dir});
    defer allocator.free(x_path);

    const content = "# Vector2.x\n\n**Parent**: Vector2\n\nThe X coordinate.\n";
    try std.fs.cwd().writeFile(.{ .sub_path = x_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, "Vector2.x", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

test "readSymbolMarkdown returns error for nonexistent symbol" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Try to read a symbol that doesn't exist
    const result = readSymbolMarkdown(allocator, "NonExistent", cache_dir, &allocating.writer);
    try std.testing.expectError(error.SymbolNotFound, result);
}

test "readSymbolMarkdown reads global function file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create a global function file
    const sin_dir = try std.fmt.allocPrint(allocator, "{s}/sin", .{cache_dir});
    defer allocator.free(sin_dir);
    try std.fs.makeDirAbsolute(sin_dir);

    const sin_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{sin_dir});
    defer allocator.free(sin_path);

    const content = "# sin\n\n**Type**: global_function\n\nReturns sine of angle.\n";
    try std.fs.cwd().writeFile(.{ .sub_path = sin_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, "sin", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

// RED PHASE: Tests for cacheIsPopulated helper function
test "cacheIsPopulated returns false for empty directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Empty directory - should return false
    const result = try cacheIsPopulated(allocator, cache_dir);
    try std.testing.expect(!result);
}

test "cacheIsPopulated returns false for nonexistent directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const nonexistent = try std.fmt.allocPrint(allocator, "{s}/nonexistent", .{tmp_path});
    defer allocator.free(nonexistent);

    // Nonexistent directory - should return false
    const result = try cacheIsPopulated(allocator, nonexistent);
    try std.testing.expect(!result);
}

test "cacheIsPopulated returns true when cache has markdown files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create the JSON file (required by implementation)
    const json_path = try getJsonCachePathInDir(allocator, cache_dir);
    defer allocator.free(json_path);
    try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = "{}" });

    // Create Node symbol directory with markdown file
    const node_dir = try std.fmt.allocPrint(allocator, "{s}/Node", .{cache_dir});
    defer allocator.free(node_dir);
    try std.fs.makeDirAbsolute(node_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{node_dir});
    defer allocator.free(index_path);
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = "# Node\n" });

    // Should return true since cache has both JSON and markdown files
    const result = try cacheIsPopulated(allocator, cache_dir);
    try std.testing.expect(result);
}

test "cacheIsPopulated returns false when only extension_api.json exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create only the JSON file, no markdown files
    const json_path = try std.fmt.allocPrint(allocator, "{s}/extension_api.json", .{cache_dir});
    defer allocator.free(json_path);
    try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = "{}" });

    // Should return false - JSON alone doesn't mean cache is populated
    const result = try cacheIsPopulated(allocator, cache_dir);
    try std.testing.expect(!result);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const known_folders = @import("known-folders");
const DocDatabase = @import("DocDatabase.zig");
