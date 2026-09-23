pub fn clearCache(io: Io, config: *const Config) !void {
    try Io.Dir.cwd().deleteTree(io, config.cache_dir);
}

// TODO: move to fs module as it is not cache specific
pub fn ensureDirectoryExists(io: Io, dir_path: []const u8) !void {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try Io.Dir.cwd().createDirPath(io, dir_path);
            return;
        },
        else => return err,
    };
    defer dir.close(io);
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

pub fn writeSymbolMarkdown(allocator: Allocator, io: Io, db: DocDatabase, symbol: []const u8, cache_path: []const u8) !void {
    const output_file_path = try resolveSymbolPath(allocator, cache_path, symbol);
    defer allocator.free(output_file_path);

    const output_dir_path = std.fs.path.dirname(output_file_path).?;
    try ensureDirectoryExists(io, output_dir_path);

    var output_file = try Io.Dir.cwd().createFile(io, output_file_path, .{});
    defer output_file.close(io);

    var buf: [4096]u8 = undefined;
    var file_writer = output_file.writer(io, &buf);
    var writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, symbol, writer);
    try writer.flush();
}

pub fn readSymbolMarkdown(allocator: Allocator, io: Io, symbol: []const u8, cache_path: []const u8, output: *Writer) !void {
    const symbol_path = try resolveSymbolPath(allocator, cache_path, symbol);
    defer allocator.free(symbol_path);

    const file = Io.Dir.openFileAbsolute(io, symbol_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SymbolNotFound,
        else => return err,
    };
    defer file.close(io);

    const content = try readFileToEndAlloc(allocator, io, file, 1024 * 1024);
    defer allocator.free(content);

    try output.writeAll(content);
}

pub fn generateMarkdownCache(allocator: Allocator, io: Io, db: DocDatabase, cache_path: []const u8) !void {
    try ensureDirectoryExists(io, cache_path);

    for (db.symbols.values()) |entry| {
        try writeSymbolMarkdown(allocator, io, db, entry.key, cache_path);
    }
}

pub fn cacheIsPopulated(allocator: Allocator, io: Io, cache_path: []const u8) !bool {
    // Check xml_docs/.complete marker
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_path);
    defer allocator.free(xml_dir);

    if (source_fetch.readCompleteMarker(allocator, io, xml_dir)) |m| {
        allocator.free(m);
    } else {
        return false;
    }

    // Check Object/index.md sentinel
    const object_path = try resolveSymbolPath(allocator, cache_path, "Object");
    defer allocator.free(object_path);

    const object_file = Io.Dir.openFileAbsolute(io, object_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    object_file.close(io);

    return true;
}

pub fn getXmlDocsDirInCache(allocator: Allocator, cache_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "xml_docs" })},
    );
}

test "testing config has valid cache directory" {
    try std.testing.expect(Config.testing.cache_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, Config.testing.cache_dir, "gdoc") != null);
}

test "ensureCacheDir creates directory if it doesn't exist" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Get a unique test cache directory path
    const test_cache = try std.fmt.allocPrint(
        allocator,
        "{s}/gdoc-test-cache",
        .{tmp_path},
    );
    defer allocator.free(test_cache);

    // Call ensureCacheDir with test path
    try ensureDirectoryExists(std.testing.io, test_cache);

    // Verify directory was created
    var dir = try Io.Dir.openDirAbsolute(std.testing.io, test_cache, .{});
    dir.close(std.testing.io);

    // Cleanup
    try Io.Dir.cwd().deleteTree(std.testing.io, test_cache);
}

test "ensureCacheDir succeeds when directory already exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_cache = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(test_cache);

    // Call ensureCacheDir - should not fail
    try ensureDirectoryExists(std.testing.io, test_cache);

    // Verify directory still exists
    var dir = try Io.Dir.openDirAbsolute(std.testing.io, test_cache, .{});
    dir.close(std.testing.io);

    // Cleanup
    try Io.Dir.cwd().deleteTree(std.testing.io, test_cache);
}

test "clearCache deletes cache directory" {
    const allocator = std.testing.allocator;
    const cache_dir = Config.testing.cache_dir;

    // Ensure cache directory exists
    try ensureDirectoryExists(std.testing.io, cache_dir);

    // Create a dummy file
    const dummy_path = try std.fmt.allocPrint(allocator, "{s}/dummy.txt", .{cache_dir});
    defer allocator.free(dummy_path);

    var dummy_file = try Io.Dir.createFileAbsolute(std.testing.io, dummy_path, .{});
    dummy_file.close(std.testing.io);

    const node_dir = try std.fmt.allocPrint(allocator, "{s}/Node", .{cache_dir});
    defer allocator.free(node_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, node_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{node_dir});
    defer allocator.free(index_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = index_path, .data = "# Node\n" });

    // Verify files exist
    _ = try Io.Dir.openFileAbsolute(std.testing.io, dummy_path, .{});
    _ = try Io.Dir.openFileAbsolute(std.testing.io, index_path, .{});

    // Clear cache
    try clearCache(std.testing.io, &Config.testing);

    // Verify cache directory is deleted
    const dir_result = Io.Dir.openDirAbsolute(std.testing.io, cache_dir, .{});
    try std.testing.expectError(error.FileNotFound, dir_result);
}

test "clearCache succeeds when cache files do not exist" {
    // Don't create any files - just call clearCache
    // Should not error even if files don't exist
    try clearCache(std.testing.io, &Config.testing);
}

test "clearCache succeeds when cache directory does not exist" {
    // Make sure cache directory doesn't exist
    Io.Dir.cwd().deleteTree(std.testing.io, Config.testing.cache_dir) catch {};

    // Call clearCache - should not error
    try clearCache(std.testing.io, &Config.testing);
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

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try writeSymbolMarkdown(allocator, std.testing.io, db, "abs", cache_dir);

    // Verify file was created at correct path
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/abs/index.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);

    const content = try readFileToEndAlloc(allocator, std.testing.io, file, 1024 * 1024);
    defer allocator.free(content);

    // Verify content contains expected markdown
    try std.testing.expect(std.mem.indexOf(u8, content, "# abs") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Returns absolute value.") != null);
}

test "writeSymbolMarkdown writes class member with parent directory creation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try writeSymbolMarkdown(allocator, std.testing.io, db, "Vector2.x", cache_dir);

    // Verify file was created at correct path with parent directory
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/x.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);

    const content = try readFileToEndAlloc(allocator, std.testing.io, file, 1024 * 1024);
    defer allocator.free(content);

    // Verify content
    try std.testing.expect(std.mem.indexOf(u8, content, "# Vector2.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**Parent**: Vector2") != null);
}

test "writeSymbolMarkdown writes class to index.md in subdirectory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try writeSymbolMarkdown(allocator, std.testing.io, db, "Node3D", cache_dir);

    // Verify file was created at Node3D/index.md
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/Node3D/index.md", .{cache_dir});
    defer allocator.free(expected_path);

    const file = try Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);

    const content = try readFileToEndAlloc(allocator, std.testing.io, file, 1024 * 1024);
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

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try generateMarkdownCache(allocator, std.testing.io, db, cache_dir);

    // Verify all files were created
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/abs/index.md", .{cache_dir});
    defer allocator.free(abs_path);
    _ = try Io.Dir.openFileAbsolute(std.testing.io, abs_path, .{});

    const vec2_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/index.md", .{cache_dir});
    defer allocator.free(vec2_path);
    _ = try Io.Dir.openFileAbsolute(std.testing.io, vec2_path, .{});

    const x_path = try std.fmt.allocPrint(allocator, "{s}/Vector2/x.md", .{cache_dir});
    defer allocator.free(x_path);
    _ = try Io.Dir.openFileAbsolute(std.testing.io, x_path, .{});
}

test "generateMarkdownCache handles empty database" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create an empty database
    var db = DocDatabase{
        .symbols = std.StringArrayHashMapUnmanaged(DocDatabase.Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Should not error with empty database
    try generateMarkdownCache(allocator, std.testing.io, db, cache_dir);

    // Cache directory should exist but be empty (except for . and ..)
    var dir = try Io.Dir.openDirAbsolute(std.testing.io, cache_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var iter = dir.iterate();
    const first = try iter.next(std.testing.io);
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

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create a class index file
    const node2d_dir = try std.fmt.allocPrint(allocator, "{s}/Node2D", .{cache_dir});
    defer allocator.free(node2d_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, node2d_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{node2d_dir});
    defer allocator.free(index_path);

    const content = "# Node2D\n\nA 2D scene node.\n";
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = index_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, std.testing.io, "Node2D", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

test "readSymbolMarkdown reads member file with dot notation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create a member file
    const vector2_dir = try std.fmt.allocPrint(allocator, "{s}/Vector2", .{cache_dir});
    defer allocator.free(vector2_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, vector2_dir);

    const x_path = try std.fmt.allocPrint(allocator, "{s}/x.md", .{vector2_dir});
    defer allocator.free(x_path);

    const content = "# Vector2.x\n\n**Parent**: Vector2\n\nThe X coordinate.\n";
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = x_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, std.testing.io, "Vector2.x", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

test "readSymbolMarkdown returns error for nonexistent symbol" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Try to read a symbol that doesn't exist
    const result = readSymbolMarkdown(allocator, std.testing.io, "NonExistent", cache_dir, &allocating.writer);
    try std.testing.expectError(error.SymbolNotFound, result);
}

test "readSymbolMarkdown reads global function file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create a global function file
    const sin_dir = try std.fmt.allocPrint(allocator, "{s}/sin", .{cache_dir});
    defer allocator.free(sin_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, sin_dir);

    const sin_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{sin_dir});
    defer allocator.free(sin_path);

    const content = "# sin\n\n**Type**: global_function\n\nReturns sine of angle.\n";
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sin_path, .data = content });

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    // Read the symbol
    try readSymbolMarkdown(allocator, std.testing.io, "sin", cache_dir, &allocating.writer);

    try std.testing.expectEqualStrings(content, allocating.written());
}

// RED PHASE: Tests for cacheIsPopulated helper function
test "cacheIsPopulated returns false for empty directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Empty directory - should return false
    const result = try cacheIsPopulated(allocator, std.testing.io, cache_dir);
    try std.testing.expect(!result);
}

test "cacheIsPopulated returns false for nonexistent directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const nonexistent = try std.fmt.allocPrint(allocator, "{s}/nonexistent", .{tmp_path});
    defer allocator.free(nonexistent);

    // Nonexistent directory - should return false
    const result = try cacheIsPopulated(allocator, std.testing.io, nonexistent);
    try std.testing.expect(!result);
}

test "cacheIsPopulated returns true when cache has xml marker and Object sentinel" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create xml_docs/.complete marker
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_dir);
    defer allocator.free(xml_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, xml_dir);
    source_fetch.writeCompleteMarker(allocator, std.testing.io, xml_dir, "4.3.stable") catch unreachable;

    // Create Object symbol directory with markdown file
    const object_dir = try std.fmt.allocPrint(allocator, "{s}/Object", .{cache_dir});
    defer allocator.free(object_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, object_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{object_dir});
    defer allocator.free(index_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = index_path, .data = "# Object\n" });

    // Should return true since cache has both xml marker and Object sentinel
    const result = try cacheIsPopulated(allocator, std.testing.io, cache_dir);
    try std.testing.expect(result);
}

test "cacheIsPopulated returns false when only xml marker exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cache_dir);

    // Create xml_docs/.complete marker but no Object sentinel
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_dir);
    defer allocator.free(xml_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, xml_dir);
    source_fetch.writeCompleteMarker(allocator, std.testing.io, xml_dir, "4.3.stable") catch unreachable;

    // Should return false - xml marker alone doesn't mean cache is populated
    const result = try cacheIsPopulated(allocator, std.testing.io, cache_dir);
    try std.testing.expect(!result);
}

fn readFileToEndAlloc(allocator: Allocator, io: Io, file: File, max_bytes: usize) ![]u8 {
    const stat = try file.stat(io);
    if (stat.size > max_bytes) return error.FileTooBig;

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return file_reader.interface.readAlloc(allocator, @intCast(stat.size));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const Writer = std.Io.Writer;

const Config = @import("Config.zig");
const DocDatabase = @import("DocDatabase.zig");
const source_fetch = @import("source_fetch.zig");
