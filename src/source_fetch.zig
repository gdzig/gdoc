pub const VersionInfo = struct {
    major: []const u8,
    minor: []const u8,
    patch: []const u8,
    hash: ?[]const u8,

    /// Formats the version as "major.minor.patch" into the provided buffer.
    pub fn formatVersion(self: VersionInfo, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}.{s}.{s}", .{ self.major, self.minor, self.patch }) catch null;
    }
};

/// Parses a Godot version string like "4.6.1.stable.official.14d19694e".
/// Returns null for empty or malformed strings.
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

const std = @import("std");
