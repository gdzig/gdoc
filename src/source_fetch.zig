pub const VersionInfo = struct {
    major: []const u8,
    minor: []const u8,
    patch: []const u8,
    hash: ?[]const u8,
    /// When non-null, this is the allocated buffer that backs major/minor/patch/hash.
    /// Call `deinit(allocator)` to free it.
    backing: ?[]u8 = null,

    pub fn deinit(self: VersionInfo, allocator: Allocator) void {
        if (self.backing) |buf| allocator.free(buf);
    }

    /// Formats the version as "major.minor.patch" into the provided buffer.
    pub fn formatVersion(self: VersionInfo, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}.{s}.{s}", .{ self.major, self.minor, self.patch }) catch null;
    }
};

/// Parses a Godot version string like "4.6.1.stable.official.14d19694e".
/// Returns null for empty or malformed strings.
/// The returned slices point into `version_str`; the caller must ensure it outlives the result.
pub fn parseGodotVersion(version_str: []const u8) ?VersionInfo {
    if (version_str.len == 0) return null;

    var it = std.mem.splitScalar(u8, version_str, '.');

    const major = it.next() orelse return null;
    const minor = it.next() orelse return null;
    const patch = it.next() orelse return null;

    // Validate that major, minor, patch are numeric
    for (major) |c| if (!std.ascii.isDigit(c)) return null;
    for (minor) |c| if (!std.ascii.isDigit(c)) return null;
    for (patch) |c| if (!std.ascii.isDigit(c)) return null;

    if (major.len == 0 or minor.len == 0 or patch.len == 0) return null;

    // 4th segment: stability label (stable/dev/beta/rc) - skip
    _ = it.next() orelse return null;

    // 5th segment: build type
    const build_type = it.next() orelse return null;

    // 6th segment: commit hash (only if build_type is "official")
    const hash: ?[]const u8 = if (std.mem.eql(u8, build_type, "official"))
        it.next()
    else
        null;

    return VersionInfo{
        .major = major,
        .minor = minor,
        .patch = patch,
        .hash = hash,
    };
}

/// Runs the godot executable at `godot_path` with `--version` and parses the output.
/// Returns null if the process fails or the output is malformed.
/// The returned VersionInfo owns its backing buffer; call `result.deinit(allocator)` when done.
pub fn getGodotVersionFromPath(allocator: Allocator, godot_path: []const u8) ?VersionInfo {
    const result = std.process.Child.run(.{
        .argv = &.{ godot_path, "--version" },
        .allocator = allocator,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, &std.ascii.whitespace);
    const owned = allocator.dupe(u8, trimmed) catch return null;
    var info = parseGodotVersion(owned) orelse {
        allocator.free(owned);
        return null;
    };
    info.backing = owned;
    return info;
}

/// Convenience wrapper that calls `getGodotVersionFromPath` with "godot" from PATH.
pub fn getGodotVersion(allocator: Allocator) ?VersionInfo {
    return getGodotVersionFromPath(allocator, "godot");
}

test "parseGodotVersion: standard version with hash" {
    const result = parseGodotVersion("4.6.1.stable.official.14d19694e");
    try std.testing.expect(result != null);
    const v = result.?;
    try std.testing.expectEqualStrings("4", v.major);
    try std.testing.expectEqualStrings("6", v.minor);
    try std.testing.expectEqualStrings("1", v.patch);
    try std.testing.expectEqualStrings("14d19694e", v.hash.?);
}

test "parseGodotVersion: custom build without hash" {
    const result = parseGodotVersion("4.6.1.stable.custom_build");
    try std.testing.expect(result != null);
    const v = result.?;
    try std.testing.expectEqualStrings("4", v.major);
    try std.testing.expectEqualStrings("6", v.minor);
    try std.testing.expectEqualStrings("1", v.patch);
    try std.testing.expect(v.hash == null);
}

test "parseGodotVersion: dev build with hash" {
    const result = parseGodotVersion("4.7.0.dev.official.abc123def");
    try std.testing.expect(result != null);
    const v = result.?;
    try std.testing.expectEqualStrings("4", v.major);
    try std.testing.expectEqualStrings("7", v.minor);
    try std.testing.expectEqualStrings("0", v.patch);
    try std.testing.expectEqualStrings("abc123def", v.hash.?);
}

test "parseGodotVersion: empty string returns null" {
    const result = parseGodotVersion("");
    try std.testing.expect(result == null);
}

test "parseGodotVersion: malformed string returns null" {
    const result = parseGodotVersion("not-a-version");
    try std.testing.expect(result == null);
}

test "VersionInfo.formatVersion produces correct output" {
    const v = VersionInfo{
        .major = "4",
        .minor = "6",
        .patch = "1",
        .hash = "14d19694e",
    };
    var buf: [32]u8 = undefined;
    const formatted = v.formatVersion(&buf);
    try std.testing.expect(formatted != null);
    try std.testing.expectEqualStrings("4.6.1", formatted.?);
}

/// Builds a tarball URL for a specific Godot version tag.
/// Example: version 4.6.1 -> "https://github.com/godotengine/godot/archive/refs/tags/4.6.1-stable.tar.gz"
pub fn buildTarballUrl(buf: []u8, version: VersionInfo) ?[]const u8 {
    return std.fmt.bufPrint(buf, "https://github.com/godotengine/godot/archive/refs/tags/{s}.{s}.{s}-stable.tar.gz", .{
        version.major, version.minor, version.patch,
    }) catch null;
}

/// Builds a tarball URL from a commit hash.
/// Example: hash "14d19694e" -> "https://github.com/godotengine/godot/archive/14d19694e.tar.gz"
pub fn buildTarballUrlFromHash(buf: []u8, hash: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "https://github.com/godotengine/godot/archive/{s}.tar.gz", .{hash}) catch null;
}

/// Downloads a .tar.gz from a URL and extracts only XML doc files.
/// Matches:
/// - `*/doc/classes/*.xml` (core class docs)
/// - `*/modules/*/doc_classes/*.xml` (module class docs)
///
/// Extracted files are written to `xml_docs_dir` with their basename only.
pub fn fetchAndExtractXmlDocs(allocator: Allocator, url: []const u8, xml_docs_dir: []const u8) !void {
    cache.ensureDirectoryExists(xml_docs_dir) catch {};

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var redirect_buf: [2048]u8 = undefined;
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(10),
    });
    defer req.deinit();

    try req.sendBodiless();

    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.HttpRequestFailed;

    // Get the raw HTTP response body reader
    var transfer_buf: [8192]u8 = undefined;
    const http_reader: *std.Io.Reader = response.reader(&transfer_buf);

    // Decompress gzip
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(http_reader, .gzip, &decompress_buf);

    // Iterate tar entries
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar_iter = std.tar.Iterator.init(&decompressor.reader, .{
        .file_name_buffer = &path_buf,
        .link_name_buffer = &link_buf,
        .diagnostics = null,
    });

    var dir = try std.fs.openDirAbsolute(xml_docs_dir, .{});
    defer dir.close();

    while (try tar_iter.next()) |file| {
        if (file.kind != .file) continue;

        const name = file.name;
        if (!std.mem.endsWith(u8, name, ".xml")) continue;

        // Match */doc/classes/*.xml or */modules/*/doc_classes/*.xml
        const is_core_doc = matchesPattern(name, "/doc/classes/");
        const is_module_doc = matchesPattern(name, "/doc_classes/");

        if (!is_core_doc and !is_module_doc) continue;

        // Extract basename
        const basename = std.fs.path.basename(name);

        var out_file = dir.createFile(basename, .{}) catch continue;
        defer out_file.close();

        var write_buf: [4096]u8 = undefined;
        var file_writer = out_file.writer(&write_buf);
        tar_iter.streamRemaining(file, &file_writer.interface) catch continue;
        file_writer.interface.flush() catch continue;
    }
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    return std.mem.indexOf(u8, path, pattern) != null;
}

/// Writes a version string to `xml_docs_dir/.complete` as a cache marker.
pub fn writeCompleteMarker(allocator: Allocator, xml_docs_dir: []const u8, version_str: []const u8) !void {
    const marker_path = try std.fmt.allocPrint(allocator, "{f}", .{
        std.fs.path.fmtJoin(&[_][]const u8{ xml_docs_dir, ".complete" }),
    });
    defer allocator.free(marker_path);

    var file = try std.fs.createFileAbsolute(marker_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    var writer = &file_writer.interface;

    try writer.writeAll(version_str);
    try writer.flush();
}

/// Reads the content of `xml_docs_dir/.complete`, or returns null if not present.
pub fn readCompleteMarker(allocator: Allocator, xml_docs_dir: []const u8) ?[]const u8 {
    const marker_path = std.fmt.allocPrint(allocator, "{f}", .{
        std.fs.path.fmtJoin(&[_][]const u8{ xml_docs_dir, ".complete" }),
    }) catch return null;
    defer allocator.free(marker_path);

    const file = std.fs.openFileAbsolute(marker_path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();

    _ = reader.stream(&allocating.writer, .unlimited) catch return null;

    const result = allocating.toOwnedSlice() catch return null;
    if (result.len == 0) {
        allocator.free(result);
        return null;
    }

    return result;
}

test "getGodotVersionFromPath with fake godot script" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const script = "#!/bin/sh\necho '4.6.1.stable.official.14d19694e'";
    try tmp_dir.dir.writeFile(.{ .sub_path = "fake-godot", .data = script });

    var file = try tmp_dir.dir.openFile("fake-godot", .{});
    try file.chmod(0o755);
    file.close();

    const fake_path = try std.fmt.allocPrint(allocator, "{s}/fake-godot", .{tmp_path});
    defer allocator.free(fake_path);

    const result = getGodotVersionFromPath(allocator, fake_path);
    try std.testing.expect(result != null);
    defer result.?.deinit(allocator);
    try std.testing.expectEqualStrings("14d19694e", result.?.hash.?);
}

test "buildTarballUrl with version 4.6.1" {
    var buf: [256]u8 = undefined;
    const url = buildTarballUrl(&buf, .{
        .major = "4",
        .minor = "6",
        .patch = "1",
        .hash = null,
    });
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot/archive/refs/tags/4.6.1-stable.tar.gz",
        url.?,
    );
}

test "buildTarballUrlFromHash with commit hash" {
    var buf: [256]u8 = undefined;
    const url = buildTarballUrlFromHash(&buf, "14d19694e");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot/archive/14d19694e.tar.gz",
        url.?,
    );
}

test "buildTarballUrl returns null when buffer too small" {
    var buf: [10]u8 = undefined;
    const url = buildTarballUrl(&buf, .{
        .major = "4",
        .minor = "6",
        .patch = "1",
        .hash = null,
    });
    try std.testing.expect(url == null);
}

test "writeCompleteMarker and readCompleteMarker round-trip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const version_str = "4.6.1";
    try writeCompleteMarker(allocator, tmp_path, version_str);

    const result = readCompleteMarker(allocator, tmp_path);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings(version_str, result.?);
}

test "readCompleteMarker returns null for non-existent marker" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const result = readCompleteMarker(allocator, tmp_path);
    try std.testing.expect(result == null);
}

const Allocator = std.mem.Allocator;
const std = @import("std");
const cache = @import("cache.zig");
