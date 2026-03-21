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

const Allocator = std.mem.Allocator;
const std = @import("std");
