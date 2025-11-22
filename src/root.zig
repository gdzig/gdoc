pub const OutputFormat = enum {
    markdown,
    terminal,
    detect,
};

pub const LookupError = error{
    ApiFileNotFound,
} || Writer.Error || DocDatabase.Error || File.OpenError;

pub fn markdownForSymbol(allocator: Allocator, symbol: []const u8, api_json_path: ?[]const u8, writer: *Writer) !void {
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

pub fn formatAndDisplay(allocator: Allocator, symbol: []const u8, api_json_path: ?[]const u8, writer: *Writer, format: OutputFormat) !void {
    switch (format) {
        .markdown => try markdownForSymbol(allocator, symbol, api_json_path, writer),
        .terminal => try renderWithZigdown(allocator, symbol, api_json_path, writer),
        .detect => {
            try formatAndDisplay(allocator, symbol, api_json_path, writer, if (File.stdout().isTty()) .terminal else .markdown);
        },
    }
}

fn renderWithZigdown(allocator: Allocator, symbol: []const u8, api_json_path: ?[]const u8, writer: *Writer) !void {
    var markdown_buf: AllocatingWriter = .init(allocator);
    defer markdown_buf.deinit();

    try markdownForSymbol(allocator, symbol, api_json_path, &markdown_buf.writer);
    const markdown = markdown_buf.written();

    renderMarkdownWithZigdown(allocator, markdown, writer) catch |err| {
        std.log.warn("terminal rendering failed ({}), falling back to markdown", .{err});
        try writer.writeAll(markdown);
        return;
    };
}

fn renderMarkdownWithZigdown(allocator: Allocator, markdown: []const u8, writer: *Writer) !void {
    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var parser: Parser = .init(arena.allocator(), .{});
    defer parser.deinit();

    try parser.parseMarkdown(markdown);

    const terminal_size: TermSize = zigdown.gfx.getTerminalSize() catch .{};

    var renderer: ConsoleRenderer = .init(writer, arena.allocator(), .{
        .termsize = terminal_size,
    });
    defer renderer.deinit();

    try renderer.renderBlock(parser.document);
}

test "markdownForSymbol returns ApiFileNotFound for nonexistent file" {
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

    const result = markdownForSymbol(allocator, "Node2D", nonexistent_path, &discard.writer);

    try std.testing.expectError(LookupError.ApiFileNotFound, result);
}

test "markdownForSymbol returns InvalidApiJson for malformed JSON" {
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

    const result = markdownForSymbol(allocator, "Node2D", bad_api_path, &discard.writer);

    try std.testing.expectError(DocDatabase.Error.InvalidApiJson, result);
}

test "markdownForSymbol loads from custom API file and finds symbol" {
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
    try markdownForSymbol(allocator, "TestClass", api_path, &allocating_writer.writer);

    // Verify something was written to output
    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);
    try std.testing.expect(written.len > 0);
}

test "markdownForSymbol returns SymbolNotFound when symbol doesn't exist" {
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
    const result = markdownForSymbol(allocator, "NonExistentClass", api_path, &discard.writer);

    try std.testing.expectError(DocDatabase.Error.SymbolNotFound, result);
}

test "markdownForSymbol works with relative path" {
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
    try markdownForSymbol(allocator, "TestClass", "test_api.json", &allocating_writer.writer);

    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);
    try std.testing.expect(written.len > 0);
}

test "OutputFormat enum has markdown and terminal values" {
    // Test that OutputFormat enum exists with expected values
    const format_markdown: OutputFormat = .markdown;
    const format_terminal: OutputFormat = .terminal;

    try std.testing.expect(format_markdown == .markdown);
    try std.testing.expect(format_terminal == .terminal);
}

test "formatAndDisplay with markdown format produces markdown output" {
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

    // Call formatAndDisplay with markdown format
    try formatAndDisplay(allocator, "TestClass", api_path, &allocating_writer.writer, .markdown);

    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);

    // Verify markdown output was produced
    try std.testing.expect(written.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, written, "TestClass") != null);
}

test "formatAndDisplay with terminal format produces terminal output" {
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

    // Call formatAndDisplay with terminal format
    try formatAndDisplay(allocator, "TestClass", api_path, &allocating_writer.writer, .terminal);

    const written = try allocating_writer.toOwnedSlice();
    defer allocator.free(written);

    // Verify terminal output was produced (should still contain the symbol name)
    try std.testing.expect(written.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, written, "TestClass") != null);
}

comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const File = std.fs.File;
const Writer = std.Io.Writer;
const AllocatingWriter = Writer.Allocating;

const known_folders = @import("known-folders");

pub const DocDatabase = @import("DocDatabase.zig");
pub const cache = @import("cache.zig");
pub const api = @import("api.zig");

const zigdown = @import("zigdown");
const ConsoleRenderer = zigdown.ConsoleRenderer;
const Parser = zigdown.Parser;
const TermSize = zigdown.gfx.TermSize;
