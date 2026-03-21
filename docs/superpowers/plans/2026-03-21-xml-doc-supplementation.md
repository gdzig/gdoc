# XML Documentation Supplementation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supplement Godot's JSON API docs with XML documentation from the Godot source tree, adding tutorials, missing descriptions, and GlobalScope entries.

**Architecture:** New `source_fetch.zig` handles version parsing and tarball streaming extraction. New `XmlDocParser.zig` parses Godot XML class docs. XML data merges into `DocDatabase` entries during markdown cache generation. All errors degrade gracefully to JSON-only mode.

**Tech Stack:** Zig 0.15.2, zig-xml (ianprime0509/zig-xml), std.tar, std.compress.gzip, std.http.Client

**API Notes:** The Zig 0.15.2 stdlib APIs for tar, gzip, and HTTP may have different signatures than what is shown in code snippets below. Code snippets illustrate the *intent* and *data flow*; the implementer must verify exact function signatures against the Zig stdlib source (e.g., `std.tar`, `std.compress.gzip` or `std.compress.flate` with gzip container mode, `std.http.Client`) and adapt accordingly. When in doubt, check the Zig stdlib source or run `zig std` for documentation.

**Spec:** `docs/superpowers/specs/2026-03-21-xml-doc-supplementation-design.md`

---

### File Structure

| File | Responsibility |
|------|---------------|
| `src/source_fetch.zig` (create) | Parse `godot --version`, download tarball, stream-extract XML docs to cache |
| `src/XmlDocParser.zig` (create) | Parse a single Godot XML class doc file into structured data |
| `build.zig.zon` (modify) | Add zig-xml dependency |
| `build.zig` (modify) | Wire zig-xml into the gdoc module |
| `src/DocDatabase.zig` (modify) | Add `tutorials` field to `Entry` |
| `src/cache.zig` (modify) | Add XML staleness check, integrate XML fetch into cache population |
| `src/root.zig` (modify) | Merge XML data during cache generation |

---

### Task 1: Add zig-xml Dependency

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`

- [ ] **Step 1: Fetch zig-xml**

```bash
cd /home/sh/Projects/gdzig/gdoc
zig fetch --save git+https://github.com/ianprime0509/zig-xml
```

Expected: `build.zig.zon` updated with zig-xml dependency entry.

- [ ] **Step 2: Wire zig-xml into build.zig**

In `build.zig`, after the `zigdown` dependency block (line 23-26), add:

```zig
const zig_xml = b.dependency("zig_xml", .{
    .target = target,
    .optimize = optimize,
}).module("xml");
```

Then add it to the `mod` imports array (line 31-35):

```zig
.{ .name = "xml", .module = zig_xml },
```

- [ ] **Step 3: Verify build compiles**

```bash
zig build
```

Expected: Clean build, no errors.

- [ ] **Step 4: Commit**

```bash
git add build.zig build.zig.zon
git commit -m "feat: add zig-xml dependency for XML doc parsing"
```

---

### Task 2: Version String Parser in source_fetch.zig

**Files:**
- Create: `src/source_fetch.zig`

- [ ] **Step 1: Write failing test for version parsing**

Create `src/source_fetch.zig`:

```zig
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

/// Parses a Godot version string like "4.6.1.stable.official.14d19694e"
/// Returns the version components and optional commit hash.
pub fn parseGodotVersion(version_str: []const u8) ?VersionInfo {
    _ = version_str;
    return null; // TODO: implement
}

test "parseGodotVersion parses standard version string" {
    const result = parseGodotVersion("4.6.1.stable.official.14d19694e").?;
    try std.testing.expectEqualStrings("4", result.major);
    try std.testing.expectEqualStrings("6", result.minor);
    try std.testing.expectEqualStrings("1", result.patch);
    try std.testing.expectEqualStrings("14d19694e", result.hash.?);
}

test "parseGodotVersion parses version without hash" {
    const result = parseGodotVersion("4.6.1.stable.custom_build").?;
    try std.testing.expectEqualStrings("4", result.major);
    try std.testing.expectEqualStrings("6", result.minor);
    try std.testing.expectEqualStrings("1", result.patch);
    try std.testing.expect(result.hash == null);
}

test "parseGodotVersion handles dev builds" {
    const result = parseGodotVersion("4.7.0.dev.official.abc123def").?;
    try std.testing.expectEqualStrings("4", result.major);
    try std.testing.expectEqualStrings("7", result.minor);
    try std.testing.expectEqualStrings("0", result.patch);
    try std.testing.expectEqualStrings("abc123def", result.hash.?);
}

test "parseGodotVersion returns null for empty string" {
    try std.testing.expect(parseGodotVersion("") == null);
}

test "parseGodotVersion returns null for malformed string" {
    try std.testing.expect(parseGodotVersion("not-a-version") == null);
}

const std = @import("std");
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test 2>&1 | head -20
```

Expected: Tests fail because `parseGodotVersion` returns `null`.

- [ ] **Step 3: Implement parseGodotVersion**

Replace the stub with:

```zig
pub fn parseGodotVersion(version_str: []const u8) ?VersionInfo {
    if (version_str.len == 0) return null;

    // Split on dots: "4.6.1.stable.official.14d19694e"
    var iter = std.mem.splitScalar(u8, version_str, '.');
    const major = iter.next() orelse return null;
    const minor = iter.next() orelse return null;
    const patch = iter.next() orelse return null;

    // Validate major/minor/patch are numeric
    for (major) |c| if (!std.ascii.isDigit(c)) return null;
    for (minor) |c| if (!std.ascii.isDigit(c)) return null;
    for (patch) |c| if (!std.ascii.isDigit(c)) return null;

    // Skip stability label (stable/dev/beta/rc)
    _ = iter.next() orelse return VersionInfo{
        .major = major,
        .minor = minor,
        .patch = patch,
        .hash = null,
    };

    // Next segment: "official" or "custom_build" etc.
    const build_type = iter.next() orelse return VersionInfo{
        .major = major,
        .minor = minor,
        .patch = patch,
        .hash = null,
    };

    // If build type is "official", the next segment is the commit hash
    const hash: ?[]const u8 = if (std.mem.eql(u8, build_type, "official"))
        iter.next()
    else
        null;

    return VersionInfo{
        .major = major,
        .minor = minor,
        .patch = patch,
        .hash = hash,
    };
}
```

- [ ] **Step 4: Register module in build.zig**

`source_fetch.zig` is part of the `gdoc` module. Since `root.zig` uses `comptime { std.testing.refAllDecls(@This()); }`, add to `src/root.zig`:

```zig
pub const source_fetch = @import("source_fetch.zig");
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
zig build test
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/source_fetch.zig src/root.zig
git commit -m "feat: add Godot version string parser"
```

---

### Task 3: Run godot --version and Parse Output

**Files:**
- Modify: `src/source_fetch.zig`

- [ ] **Step 1: Write failing test for getGodotVersion**

Add to `src/source_fetch.zig`:

```zig
/// Runs `godot --version` and parses the output.
/// Returns null if godot is not installed or version can't be parsed.
pub fn getGodotVersion(allocator: Allocator) ?VersionInfo {
    _ = allocator;
    return null; // TODO
}

test "getGodotVersion with fake godot script" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a fake godot that outputs a version string
    const script = "#!/bin/sh\necho '4.6.1.stable.official.14d19694e'";
    try tmp_dir.dir.writeFile(.{ .sub_path = "fake-godot", .data = script });

    var file = try tmp_dir.dir.openFile("fake-godot", .{});
    try file.chmod(0o755);
    file.close();

    const fake_path = try std.fmt.allocPrint(allocator, "{s}/fake-godot", .{tmp_path});
    defer allocator.free(fake_path);

    const result = getGodotVersionFromPath(allocator, fake_path);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("14d19694e", result.?.hash.?);
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zig build test 2>&1 | head -20
```

- [ ] **Step 3: Implement getGodotVersionFromPath**

```zig
/// Runs a godot executable at the given path with --version and parses output.
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
    return parseGodotVersion(trimmed);
}

/// Convenience wrapper that uses "godot" from PATH.
pub fn getGodotVersion(allocator: Allocator) ?VersionInfo {
    return getGodotVersionFromPath(allocator, "godot");
}
```

- [ ] **Step 4: Run tests**

```bash
zig build test
```

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/source_fetch.zig
git commit -m "feat: run godot --version and parse output"
```

---

### Task 4: Tarball Download and XML Extraction

**Files:**
- Modify: `src/source_fetch.zig`

- [ ] **Step 1: Write the tarball URL builder**

Add to `src/source_fetch.zig`:

```zig
/// Builds the GitHub tarball URL for a Godot version.
/// Tries tag-based URL first (e.g., v4.6.1-stable), with hash fallback.
pub fn buildTarballUrl(buf: []u8, version: VersionInfo) ?[]const u8 {
    const result = std.fmt.bufPrint(buf, "https://github.com/godotengine/godot/archive/refs/tags/{s}.{s}.{s}-stable.tar.gz", .{
        version.major, version.minor, version.patch,
    }) catch return null;
    return result;
}

pub fn buildTarballUrlFromHash(buf: []u8, hash: []const u8) ?[]const u8 {
    const result = std.fmt.bufPrint(buf, "https://github.com/godotengine/godot/archive/{s}.tar.gz", .{hash}) catch return null;
    return result;
}

test "buildTarballUrl formats tag-based URL" {
    var buf: [256]u8 = undefined;
    const url = buildTarballUrl(&buf, .{
        .major = "4",
        .minor = "6",
        .patch = "1",
        .hash = "14d19694e",
    }).?;
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot/archive/refs/tags/4.6.1-stable.tar.gz",
        url,
    );
}

test "buildTarballUrlFromHash formats hash-based URL" {
    var buf: [256]u8 = undefined;
    const url = buildTarballUrlFromHash(&buf, "14d19694e").?;
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot/archive/14d19694e.tar.gz",
        url,
    );
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test
```

- [ ] **Step 3: Write the streaming extraction function**

This is the core function that downloads a tarball and extracts XML docs. Add to `src/source_fetch.zig`:

```zig
const Allocator = std.mem.Allocator;

/// Downloads the Godot source tarball and extracts XML doc files.
/// Streams: HTTP -> gzip decompress -> tar extract -> filter XML files.
/// Writes extracted XML files to `xml_docs_dir`.
///
/// **API NOTE:** The exact std.tar, std.compress.gzip, and std.http.Client
/// signatures must be verified against the Zig 0.15.2 stdlib source.
/// The pseudocode below shows the intended data flow. Key things to verify:
/// - gzip decompression: try `std.compress.gzip.decompress(reader)` or
///   `std.compress.flate.decompressor(.gzip, reader)`
/// - tar iteration: check `std.tar.iterator()` or `std.tar.pipeToFileSystem()`
/// - HTTP: `std.http.Client` open/send/wait or fetch API
/// - File writer: use `.writer(&buf)` then `.interface` pattern from cache.zig
pub fn fetchAndExtractXmlDocs(
    allocator: Allocator,
    url: []const u8,
    xml_docs_dir: []const u8,
) !void {
    // 1. HTTP GET the tarball URL
    var client: std.http.Client = .init(allocator);
    defer client.deinit();

    // Open connection, send request, wait for response
    var header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, try std.Uri.parse(url), .{
        .server_header_buffer = &header_buf,
    });
    defer req.deinit();
    try req.send();
    try req.wait();

    if (req.response.status != .ok) return error.DownloadFailed;

    // 2. Pipe HTTP response reader -> gzip decompressor -> tar iterator
    //    Verify exact API: std.compress.gzip or std.compress.flate with gzip mode
    var decompress = std.compress.gzip.decompressor(req.reader());

    // 3. Iterate tar entries, filtering for XML doc files
    var tar_iter = std.tar.iterator(decompress.reader(), .{});

    while (try tar_iter.next()) |entry| {
        const name = entry.name;
        const basename = std.fs.path.basename(name);

        if (!std.mem.endsWith(u8, basename, ".xml")) continue;

        // Match: */doc/classes/*.xml and */modules/*/doc_classes/*.xml
        const is_core_doc = std.mem.indexOf(u8, name, "/doc/classes/") != null;
        const is_module_doc = std.mem.indexOf(u8, name, "/doc_classes/") != null;
        if (!is_core_doc and !is_module_doc) continue;

        // 4. Write matching XML file to xml_docs_dir/ClassName.xml
        const output_path = try std.fs.path.join(allocator, &.{ xml_docs_dir, basename });
        defer allocator.free(output_path);

        var output_file = try std.fs.createFileAbsolute(output_path, .{});
        defer output_file.close();

        // Stream entry content to file using buffered writer
        // Use the .writer(&buf) then .interface pattern from cache.zig
        var buf: [4096]u8 = undefined;
        var file_writer = output_file.writer(&buf);
        var writer = &file_writer.interface;

        // Read entry content and write to file
        // Exact API depends on tar entry reader interface
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try entry.reader().read(&read_buf);
            if (bytes_read == 0) break;
            try writer.writeAll(read_buf[0..bytes_read]);
        }
        try writer.flush();
    }
}
```

**IMPORTANT for implementer:** The `std.tar`, `std.compress.gzip`/`std.compress.flate`, and `std.http.Client` APIs shown above are pseudocode illustrating the data flow. You **must** check the actual Zig 0.15.2 stdlib source for correct function signatures before coding. The streaming pipeline concept (HTTP -> gzip -> tar -> filter) is correct; only the exact API calls need verification.

- [ ] **Step 4: Write the .complete marker function**

```zig
/// Writes a .complete marker file with the version string.
pub fn writeCompleteMarker(allocator: Allocator, xml_docs_dir: []const u8, version_str: []const u8) !void {
    const marker_path = try std.fs.path.join(allocator, &.{ xml_docs_dir, ".complete" });
    defer allocator.free(marker_path);

    var file = try std.fs.createFileAbsolute(marker_path, .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    var file_writer = file.writer(&buf);
    var writer = &file_writer.interface;
    try writer.writeAll(version_str);
    try writer.flush();
}

/// Reads the .complete marker and returns the version string, or null if not present.
pub fn readCompleteMarker(allocator: Allocator, xml_docs_dir: []const u8) ?[]const u8 {
    const marker_path = std.fs.path.join(allocator, &.{ xml_docs_dir, ".complete" }) catch return null;
    defer allocator.free(marker_path);

    const file = std.fs.openFileAbsolute(marker_path, .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;
    return reader.readAlloc(allocator, 256) catch null;
}
```

- [ ] **Step 5: Write tests for marker functions**

```zig
test "writeCompleteMarker and readCompleteMarker round-trip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try writeCompleteMarker(allocator, tmp_path, "4.6.1.stable.official.14d19694e");

    const read_back = readCompleteMarker(allocator, tmp_path).?;
    defer allocator.free(read_back);

    try std.testing.expectEqualStrings("4.6.1.stable.official.14d19694e", read_back);
}

test "readCompleteMarker returns null when no marker exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.testing.expect(readCompleteMarker(allocator, tmp_path) == null);
}
```

- [ ] **Step 6: Run tests**

```bash
zig build test
```

Expected: Marker tests pass. The `fetchAndExtractXmlDocs` function won't be unit tested (it requires network); it will be integration tested in a later task.

- [ ] **Step 7: Commit**

```bash
git add src/source_fetch.zig
git commit -m "feat: add tarball download, XML extraction, and cache markers"
```

---

### Task 5: XML Doc Parser

**Files:**
- Create: `src/XmlDocParser.zig`
- Modify: `src/root.zig` (add import)

- [ ] **Step 1: Define the output data structures**

Create `src/XmlDocParser.zig`:

```zig
const XmlDocParser = @This();

pub const Tutorial = struct {
    title: []const u8,
    url: []const u8,
};

pub const MemberDoc = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const ClassDoc = struct {
    name: []const u8,
    inherits: ?[]const u8 = null,
    brief_description: ?[]const u8 = null,
    description: ?[]const u8 = null,
    tutorials: ?[]Tutorial = null,
    methods: ?[]MemberDoc = null,
    properties: ?[]MemberDoc = null,
    signals: ?[]MemberDoc = null,
    constants: ?[]MemberDoc = null,
};

const DOCS_BASE_URL = "https://docs.godotengine.org/en/stable";

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");
```

- [ ] **Step 2: Write a test with sample XML**

Add to `src/XmlDocParser.zig`:

```zig
/// Parses a Godot XML class documentation file.
/// All returned strings are allocated with the provided allocator.
pub fn parseClassDoc(allocator: Allocator, xml_content: []const u8) !ClassDoc {
    _ = allocator;
    _ = xml_content;
    return error.NotImplemented; // TODO
}

const test_xml =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node2D" inherits="CanvasItem" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    \\    <brief_description>A 2D game object.</brief_description>
    \\    <description>Node2D is the base class for 2D.</description>
    \\    <tutorials>
    \\        <link title="Custom drawing in 2D">$DOCS_URL/tutorials/2d/custom_drawing.html</link>
    \\        <link title="All 2D Demos">https://github.com/godotengine/godot-demo-projects/tree/master/2d</link>
    \\    </tutorials>
    \\    <methods>
    \\        <method name="apply_scale">
    \\            <return type="void" />
    \\            <param index="0" name="ratio" type="Vector2" />
    \\            <description>Multiplies the current scale by the ratio vector.</description>
    \\        </method>
    \\    </methods>
    \\    <members>
    \\        <member name="position" type="Vector2" setter="set_position" getter="get_position" default="Vector2(0, 0)">
    \\Position, relative to the node's parent.
    \\        </member>
    \\    </members>
    \\</class>
;

test "parseClassDoc parses class name and inherits" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expectEqualStrings("Node2D", doc.name);
    try std.testing.expectEqualStrings("CanvasItem", doc.inherits.?);
}

test "parseClassDoc parses descriptions" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expectEqualStrings("A 2D game object.", doc.brief_description.?);
    try std.testing.expectEqualStrings("Node2D is the base class for 2D.", doc.description.?);
}

test "parseClassDoc parses tutorials with DOCS_URL expansion" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expect(doc.tutorials != null);
    try std.testing.expectEqual(@as(usize, 2), doc.tutorials.?.len);

    try std.testing.expectEqualStrings("Custom drawing in 2D", doc.tutorials.?[0].title);
    try std.testing.expectEqualStrings(
        "https://docs.godotengine.org/en/stable/tutorials/2d/custom_drawing.html",
        doc.tutorials.?[0].url,
    );

    // External URL should be left unchanged
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot-demo-projects/tree/master/2d",
        doc.tutorials.?[1].url,
    );
}

test "parseClassDoc parses methods" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expect(doc.methods != null);
    try std.testing.expectEqual(@as(usize, 1), doc.methods.?.len);
    try std.testing.expectEqualStrings("apply_scale", doc.methods.?[0].name);
    try std.testing.expectEqualStrings("Multiplies the current scale by the ratio vector.", doc.methods.?[0].description.?);
}

test "parseClassDoc parses properties from members element" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expect(doc.properties != null);
    try std.testing.expectEqual(@as(usize, 1), doc.properties.?.len);
    try std.testing.expectEqualStrings("position", doc.properties.?[0].name);
}

/// Frees all memory allocated by parseClassDoc.
pub fn freeClassDoc(allocator: Allocator, doc: ClassDoc) void {
    _ = allocator;
    _ = doc;
    // TODO: free all allocated strings and slices
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
zig build test 2>&1 | head -20
```

Expected: `error.NotImplemented`

- [ ] **Step 4: Implement parseClassDoc**

Implement using zig-xml's pull parser API. The implementation should:

1. Create an `xml.Reader` from the content
2. Loop through events matching element starts/ends
3. Collect text content for `brief_description`, `description`
4. Parse `class` element attributes for `name` and `inherits`
5. Parse `tutorials/link` elements, expanding `$DOCS_URL`
6. Parse `methods/method` and `members/member` elements
7. Build and return `ClassDoc`

The exact API calls depend on zig-xml's reader interface. Consult zig-xml's README or tests for the exact method names (likely `reader.read()` returning tagged events).

- [ ] **Step 5: Implement freeClassDoc**

Free all allocated slices and strings in the `ClassDoc`.

- [ ] **Step 6: Register in root.zig**

Add to `src/root.zig`:

```zig
pub const XmlDocParser = @import("XmlDocParser.zig");
```

- [ ] **Step 7: Run tests**

```bash
zig build test
```

Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add src/XmlDocParser.zig src/root.zig
git commit -m "feat: add XML doc parser for Godot class documentation"
```

---

### Task 6: Add tutorials Field to Entry

**Files:**
- Modify: `src/DocDatabase.zig`
- Modify: `src/DocDatabase.zig` (markdown generation)

- [ ] **Step 1: Add tutorials field to Entry struct**

In `src/DocDatabase.zig`, add to the `Entry` struct (after line 32):

```zig
pub const Tutorial = struct {
    title: []const u8,
    url: []const u8,
};
```

And add the field to `Entry` (after `members`):

```zig
tutorials: ?[]const Tutorial = null,
```

- [ ] **Step 2: Update generateMarkdownForSymbol to render tutorials**

Find the `generateMarkdownForSymbol` function in `src/DocDatabase.zig`. After the description section, add:

```zig
if (entry.tutorials) |tutorials| {
    if (tutorials.len > 0) {
        try writer.writeAll("\n## Tutorials\n\n");
        for (tutorials) |tutorial| {
            try writer.print("- [{s}]({s})\n", .{ tutorial.title, tutorial.url });
        }
    }
}
```

- [ ] **Step 3: Write a snapshot test**

Update an existing test or add a new one that includes tutorials in the entry and verifies the markdown output contains a Tutorials section.

- [ ] **Step 4: Run tests**

```bash
zig build test
```

Expected: All pass, snapshots clean.

- [ ] **Step 5: Commit**

```bash
git add src/DocDatabase.zig
git commit -m "feat: add tutorials field to Entry and render in markdown output"
```

---

### Task 7: Integrate XML Fetch into Cache Population

**Files:**
- Modify: `src/cache.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Add XML docs directory helpers to cache.zig**

Add to `src/cache.zig`:

```zig
pub fn getXmlDocsDirInCache(allocator: Allocator, cache_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.fs.path.fmtJoin(&[_][]const u8{ cache_dir, "xml_docs" })},
    );
}

pub fn xmlDocsArePopulated(allocator: Allocator, cache_dir: []const u8) !bool {
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_dir);
    defer allocator.free(xml_dir);

    const marker = source_fetch.readCompleteMarker(allocator, xml_dir);
    if (marker) |m| {
        allocator.free(m);
        return true;
    }
    return false;
}
```

Add the import at the bottom:

```zig
const source_fetch = @import("source_fetch.zig");
```

- [ ] **Step 2: Add XML staleness check**

Add to `src/cache.zig`:

```zig
/// Checks if XML docs are stale by comparing cached version to current godot version.
pub fn xmlDocsAreStale(allocator: Allocator, cache_dir: []const u8, current_version: []const u8) !bool {
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_dir);
    defer allocator.free(xml_dir);

    const cached_version = source_fetch.readCompleteMarker(allocator, xml_dir) orelse return true;
    defer allocator.free(cached_version);

    return !std.mem.eql(u8, cached_version, current_version);
}
```

- [ ] **Step 3: Modify root.zig to trigger XML fetch during cache population**

In `src/root.zig`, modify the cache population block (lines 38-50) to also fetch XML docs and check for staleness:

```zig
const needs_full_rebuild = !try cache.cacheIsPopulated(allocator, cache_path);

if (needs_full_rebuild) {
    try cache.ensureDirectoryExists(cache_path);
    try api.generateApiJsonIfNotExists(allocator, "godot", cache_path);
}

// Fetch XML docs if missing or stale (best-effort, independent of JSON cache)
if (needs_full_rebuild or !try cache.xmlDocsArePopulated(allocator, cache_path)) {
    fetchXmlDocs(allocator, cache_path);
}

if (needs_full_rebuild) {
    const json_path = try cache.getJsonCachePathInDir(allocator, cache_path);
    defer allocator.free(json_path);

    const json_file = try std.fs.openFileAbsolute(json_path, .{});
    defer json_file.close();

    var db = try DocDatabase.loadFromJsonFileLeaky(arena.allocator(), json_file);

    // Merge XML data into db before generating markdown cache
    // arena.allocator() for strings that live in the DB, allocator for temporaries
    mergeXmlDocs(arena.allocator(), allocator, &db, cache_path);

    try cache.generateMarkdownCache(allocator, db, cache_path);
}
```

- [ ] **Step 4: Implement fetchXmlDocs helper**

Add to `src/root.zig`:

```zig
fn fetchXmlDocs(allocator: Allocator, cache_path: []const u8) void {
    const xml_dir = cache.getXmlDocsDirInCache(allocator, cache_path) catch return;
    defer allocator.free(xml_dir);

    cache.ensureDirectoryExists(xml_dir) catch return;

    const version = source_fetch.getGodotVersion(allocator) orelse return;

    var url_buf: [256]u8 = undefined;
    const url = source_fetch.buildTarballUrl(&url_buf, version) orelse return;

    source_fetch.fetchAndExtractXmlDocs(allocator, url, xml_dir) catch |err| {
        // Try hash-based fallback URL
        if (version.hash) |hash| {
            var hash_url_buf: [256]u8 = undefined;
            const hash_url = source_fetch.buildTarballUrlFromHash(&hash_url_buf, hash) orelse return;
            source_fetch.fetchAndExtractXmlDocs(allocator, hash_url, xml_dir) catch {
                std.log.warn("XML doc fetch failed ({}), proceeding without XML supplementation", .{err});
                return;
            };
        } else {
            std.log.warn("XML doc fetch failed ({}), proceeding without XML supplementation", .{err});
            return;
        }
    };

    var version_buf: [64]u8 = undefined;
    const version_str = version.formatVersion(&version_buf) orelse return;

    source_fetch.writeCompleteMarker(allocator, xml_dir, version_str) catch return;
}
```

- [ ] **Step 5: Implement mergeXmlDocs helper (stub for now)**

Add to `src/root.zig`:

```zig
fn mergeXmlDocs(arena_allocator: Allocator, tmp_allocator: Allocator, db: *DocDatabase, cache_path: []const u8) void {
    _ = arena_allocator;
    _ = tmp_allocator;
    _ = db;
    _ = cache_path;
    // TODO: implement in Task 8
}
```

- [ ] **Step 6: Run tests**

```bash
zig build test
```

Expected: All pass. Network-dependent code is only called in the actual cache population path, not in tests.

- [ ] **Step 7: Commit**

```bash
git add src/cache.zig src/root.zig
git commit -m "feat: integrate XML doc fetch into cache population flow"
```

---

### Task 8: Merge XML Data into DocDatabase

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Implement mergeXmlDocs**

Replace the stub in `src/root.zig`.

**IMPORTANT memory ownership:** `parseClassDoc` allocates strings with the provided allocator. Since these strings are stored in the `DocDatabase` (which uses an arena allocator that outlives this function), pass the arena allocator to `parseClassDoc` so the strings live as long as the DB. Do NOT free the parsed content -- the arena owns it.

```zig
/// Merges XML documentation into the DocDatabase.
/// Uses arena_allocator for all allocations so strings live as long as the DB.
/// Uses tmp_allocator for temporary allocations (paths, etc.) that are freed immediately.
fn mergeXmlDocs(arena_allocator: Allocator, tmp_allocator: Allocator, db: *DocDatabase, cache_path: []const u8) void {
    const xml_dir = cache.getXmlDocsDirInCache(tmp_allocator, cache_path) catch return;
    defer tmp_allocator.free(xml_dir);

    var dir = std.fs.openDirAbsolute(xml_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;

        const class_name = entry.name[0 .. entry.name.len - 4]; // strip .xml

        // Read XML file content (temporary -- only needed for parsing)
        const xml_path = std.fs.path.join(tmp_allocator, &.{ xml_dir, entry.name }) catch continue;
        defer tmp_allocator.free(xml_path);

        const content = std.fs.openFileAbsolute(xml_path, .{}) catch continue;
        defer content.close();
        const xml_bytes = content.readToEndAlloc(tmp_allocator, 2 * 1024 * 1024) catch continue;
        defer tmp_allocator.free(xml_bytes);

        // Parse XML -- allocate strings with arena so they outlive this function
        const class_doc = XmlDocParser.parseClassDoc(arena_allocator, xml_bytes) catch |err| {
            std.log.warn("failed to parse XML doc for {s}: {}", .{ class_name, err });
            continue;
        };
        // Do NOT call freeClassDoc -- arena owns the memory

        // Merge tutorials into existing entry
        if (class_doc.tutorials) |tutorials| {
            if (db.symbols.getPtr(class_name)) |db_entry| {
                if (db_entry.tutorials == null and tutorials.len > 0) {
                    const db_tutorials = arena_allocator.alloc(DocDatabase.Tutorial, tutorials.len) catch continue;
                    for (tutorials, 0..) |t, i| {
                        db_tutorials[i] = .{ .title = t.title, .url = t.url };
                    }
                    db_entry.tutorials = db_tutorials;
                }
            }
        }

        // Fill missing class description
        if (class_doc.description) |xml_desc| {
            if (db.symbols.getPtr(class_name)) |db_entry| {
                if (db_entry.description == null) {
                    db_entry.description = xml_desc;
                }
            }
        }

        // Helper: merge member descriptions (methods, properties, signals)
        const member_lists = [_]struct { members: ?[]XmlDocParser.MemberDoc }{
            .{ .members = class_doc.methods },
            .{ .members = class_doc.properties },
            .{ .members = class_doc.signals },
        };

        for (member_lists) |list| {
            const members = list.members orelse continue;
            for (members) |member| {
                const member_key = std.fmt.allocPrint(tmp_allocator, "{s}.{s}", .{ class_name, member.name }) catch continue;
                defer tmp_allocator.free(member_key);

                if (db.symbols.getPtr(member_key)) |db_entry| {
                    if (db_entry.description == null) {
                        db_entry.description = member.description;
                    }
                }
            }
        }

        // Add GlobalScope entries not present in JSON
        if (db.symbols.get(class_name) == null) {
            // This class exists in XML but not in JSON -- add it
            const key = std.fmt.allocPrint(arena_allocator, "{s}", .{class_name}) catch continue;
            db.symbols.put(arena_allocator, key, .{
                .key = key,
                .name = key,
                .kind = .class,
                .description = class_doc.description,
                .brief_description = class_doc.brief_description,
            }) catch continue;
        }
    }
}
```

- [ ] **Step 2: Write a test for mergeXmlDocs**

```zig
test "mergeXmlDocs fills missing descriptions from XML" {
    const allocator = std.testing.allocator;

    // Use an arena for DB-lifetime allocations (simulates the real flow)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create xml_docs dir with a test XML file
    const xml_dir = try std.fmt.allocPrint(allocator, "{s}/xml_docs", .{cache_dir});
    defer allocator.free(xml_dir);
    try std.fs.makeDirAbsolute(xml_dir);

    const xml_path = try std.fmt.allocPrint(allocator, "{s}/TestClass.xml", .{xml_dir});
    defer allocator.free(xml_path);

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="TestClass">
        \\    <brief_description>A test.</brief_description>
        \\    <description>Full description from XML.</description>
        \\    <tutorials>
        \\        <link title="Test Tutorial">https://example.com</link>
        \\    </tutorials>
        \\</class>
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = xml_path, .data = xml_content });

    // Create a DB with TestClass but no description
    var db = DocDatabase{ .symbols = .empty };
    defer db.symbols.deinit(allocator);

    try db.symbols.put(allocator, "TestClass", .{
        .key = "TestClass",
        .name = "TestClass",
        .kind = .class,
        .description = null, // Missing - should be filled from XML
    });

    // arena.allocator() for DB-lifetime strings, allocator for temporaries
    mergeXmlDocs(arena.allocator(), allocator, &db, cache_dir);

    const entry = db.symbols.get("TestClass").?;
    try std.testing.expectEqualStrings("Full description from XML.", entry.description.?);
    try std.testing.expect(entry.tutorials != null);
}
```

- [ ] **Step 3: Run tests**

```bash
zig build test
```

- [ ] **Step 4: Commit**

```bash
git add src/root.zig
git commit -m "feat: merge XML documentation data into DocDatabase entries"
```

---

### Task 9: Update clearCache and End-to-End Verification

**Files:**
- Modify: `src/cache.zig`

- [ ] **Step 1: Verify clearCache already handles xml_docs**

`clearCache` deletes the entire cache directory tree (`std.fs.deleteTreeAbsolute`), so `xml_docs/` is already covered. No change needed.

- [ ] **Step 2: Manual integration test**

```bash
# Build
zig build

# Clear existing cache
zig-out/bin/gdoc --clear-cache

# Look up a class (triggers JSON + XML fetch)
zig-out/bin/gdoc Node2D

# Verify tutorials section appears
zig-out/bin/gdoc Node2D | grep -i tutorial

# Look up a member
zig-out/bin/gdoc Node2D.position
```

Expected: Node2D output includes a Tutorials section with links. Properties show descriptions that may have been missing before.

- [ ] **Step 3: Test with --godot-extension-api (should skip XML)**

```bash
zig-out/bin/gdoc --godot-extension-api extension_api.json Node2D
```

Expected: Works as before, no tutorials section (XML not used in this path).

- [ ] **Step 4: Run full test suite**

```bash
zig build test
```

Expected: All tests pass.

- [ ] **Step 5: Commit any test adjustments**

```bash
git add src/ snapshots/
git commit -m "test: verify end-to-end XML doc supplementation"
```

---

### Task 10: Update Snapshots

**Files:**
- Modify: `snapshots/*.md` (as needed)

- [ ] **Step 1: Regenerate snapshots if format changed**

If the tutorials section changed the output format for any existing snapshot tests, update the snapshots:

```bash
zig build test 2>&1 | grep -A5 "snapshot"
```

If snapshot diffs exist, review them and update:

```bash
# Review the diffs
git diff snapshots/

# If changes are expected (new Tutorials section), stage them
git add snapshots/
git commit -m "test: update snapshots for tutorials section"
```

- [ ] **Step 2: Final verification**

```bash
zig build test
```

Expected: All green.
