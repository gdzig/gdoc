pub const OutputFormat = enum {
    markdown,
    terminal,
    detect,
};

pub const LookupError = Writer.Error || DocDatabase.Error || File.OpenError;

pub fn markdownForSymbol(allocator: Allocator, symbol: []const u8, writer: *Writer, config: *const Config) !void {
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    const cache_path = config.cache_dir;

    const needs_full_rebuild = !try cache.cacheIsPopulated(allocator, cache_path);

    if (needs_full_rebuild) {
        try cache.ensureDirectoryExists(cache_path);

        const xml_dir = try cache.getXmlDocsDirInCache(allocator, cache_path);
        defer allocator.free(xml_dir);
        try cache.ensureDirectoryExists(xml_dir);

        const version = source_fetch.getGodotVersion(allocator) orelse
            return error.GodotNotFound;
        defer version.deinit(allocator);

        var url_buf: [256]u8 = undefined;
        const url = source_fetch.buildTarballUrl(&url_buf, version) orelse
            return error.GodotNotFound;

        var spinner = Spinner{ .message = "Downloading XML docs..." };
        spinner.start();

        source_fetch.fetchAndExtractXmlDocs(allocator, url, xml_dir) catch |err| {
            if (version.hash) |hash| {
                var hash_url_buf: [256]u8 = undefined;
                const hash_url = source_fetch.buildTarballUrlFromHash(&hash_url_buf, hash) orelse {
                    spinner.finish();
                    return err;
                };
                source_fetch.fetchAndExtractXmlDocs(allocator, hash_url, xml_dir) catch {
                    spinner.finish();
                    return err;
                };
            } else {
                spinner.finish();
                return err;
            }
        };

        spinner.finish();

        var version_buf: [64]u8 = undefined;
        const version_str = version.formatVersion(&version_buf) orelse return error.GodotNotFound;
        source_fetch.writeCompleteMarker(allocator, xml_dir, version_str) catch return error.GodotNotFound;

        var build_spinner = Spinner{ .message = "Building documentation cache..." };
        build_spinner.start();
        defer build_spinner.finish();

        const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, xml_dir);
        try cache.generateMarkdownCache(allocator, db, cache_path);
    }

    try cache.readSymbolMarkdown(allocator, symbol, cache_path, writer);
}

pub fn formatAndDisplay(allocator: Allocator, symbol: []const u8, writer: *Writer, format: OutputFormat, config: *const Config) !void {
    switch (format) {
        .markdown => try markdownForSymbol(allocator, symbol, writer, config),
        .terminal => try renderWithZigdown(allocator, symbol, writer, config),
        .detect => {
            try formatAndDisplay(allocator, symbol, writer, if (File.stdout().isTty()) .terminal else .markdown, config);
        },
    }
}

fn renderWithZigdown(allocator: Allocator, symbol: []const u8, writer: *Writer, config: *const Config) !void {
    var markdown_buf: AllocatingWriter = .init(allocator);
    defer markdown_buf.deinit();

    try markdownForSymbol(allocator, symbol, &markdown_buf.writer, config);
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

test "OutputFormat enum has markdown and terminal values" {
    // Test that OutputFormat enum exists with expected values
    const format_markdown: OutputFormat = .markdown;
    const format_terminal: OutputFormat = .terminal;

    try std.testing.expect(format_markdown == .markdown);
    try std.testing.expect(format_terminal == .terminal);
}

// Test verifies the normal cache flow when cache is pre-populated
test "markdownForSymbol reads from markdown cache when available" {
    const allocator = std.testing.allocator;
    const cache_dir = Config.testing.cache_dir;

    // Clear any existing cache to start fresh
    cache.clearCache(&Config.testing) catch {};

    // Ensure cache directory exists
    try cache.ensureDirectoryExists(cache_dir);

    // Create xml_docs/.complete marker to make cacheIsPopulated return true
    const xml_dir = try cache.getXmlDocsDirInCache(allocator, cache_dir);
    defer allocator.free(xml_dir);
    try cache.ensureDirectoryExists(xml_dir);
    try source_fetch.writeCompleteMarker(allocator, xml_dir, "4.3.stable");

    // Create Object/index.md sentinel to make cacheIsPopulated return true
    const object_dir = try std.fmt.allocPrint(allocator, "{s}/Object", .{cache_dir});
    defer allocator.free(object_dir);
    try cache.ensureDirectoryExists(object_dir);

    const object_index = try std.fmt.allocPrint(allocator, "{s}/index.md", .{object_dir});
    defer allocator.free(object_index);
    try std.fs.cwd().writeFile(.{ .sub_path = object_index, .data = "# Object\n" });

    // Pre-populate cache with a markdown file for TestCachedClass
    const testclass_dir = try std.fmt.allocPrint(allocator, "{s}/TestCachedClass", .{cache_dir});
    defer allocator.free(testclass_dir);
    try std.fs.makeDirAbsolute(testclass_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{testclass_dir});
    defer allocator.free(index_path);

    const cached_markdown = "# TestCachedClass\n\nA cached test class from markdown cache.\n";
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = cached_markdown });

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    // Call markdownForSymbol - should use cache
    try markdownForSymbol(allocator, "TestCachedClass", &allocating_writer.writer, &Config.testing);

    const written = allocating_writer.written();

    // Verify it used the cached markdown
    try std.testing.expect(std.mem.indexOf(u8, written, "cached test class from markdown cache") != null);

    // Cleanup
    cache.clearCache(&Config.testing) catch {};
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

pub const DocDatabase = @import("DocDatabase.zig");
pub const XmlDocParser = @import("XmlDocParser.zig");
pub const cache = @import("cache.zig");
pub const Config = @import("Config.zig");
pub const source_fetch = @import("source_fetch.zig");
const Spinner = @import("Spinner.zig");

const zigdown = @import("zigdown");
const ConsoleRenderer = zigdown.ConsoleRenderer;
const Parser = zigdown.Parser;
const TermSize = zigdown.gfx.TermSize;
