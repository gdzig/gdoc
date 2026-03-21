# XML Documentation Supplementation

## Problem

Godot's `--dump-extension-api-with-docs` JSON export does not contain all documentation. Tutorials, some GlobalScope entries, and other doc fields are only available in the XML documentation files within the Godot source tree (`doc/classes/*.xml` and `modules/*/doc_classes/*.xml`).

## Solution

Automatically fetch and parse Godot's XML documentation from the source tree, using it to supplement the existing JSON data with missing fields.

## Design

### Source Acquisition

1. Run `godot --version` to get the version string (e.g., `4.6.1.stable.official.14d19694e`).
2. Parse the version number and commit hash. The version number (`4.6.1`) is used to construct a tag-based tarball URL; the commit hash is a fallback.
3. Download the source tarball from `https://github.com/godotengine/godot/archive/refs/tags/{version}-stable.tar.gz` (falling back to `https://github.com/godotengine/godot/archive/{hash}.tar.gz` if the tag URL fails).
4. Stream the tarball through gzip decompression and tar extraction, filtering for:
   - `*/doc/classes/*.xml` (core class docs)
   - `*/modules/*/doc_classes/*.xml` (module class docs, e.g., GDScript, WebSocket)
5. Write matching XML files to `~/.cache/gdoc/xml_docs/`.
6. Write a `.complete` marker file with the version string after successful extraction.
7. The tarball is never written to disk -- streamed directly from HTTP through decompression and extraction.

**When Godot is not installed**: The existing fallback path downloads JSON from GitHub. In this case, use the latest stable release tag from the GitHub API to determine the tarball URL for XML docs.

This runs automatically on first use alongside the existing JSON generation. `--clear-cache` clears XML docs too.

### XML Parsing

**Dependency**: `ianprime0509/zig-xml` -- a pull/streaming XML parser targeting Zig 0.15.1, with W3C conformance testing and standard `build.zig.zon` integration.

**New module**: `src/XmlDocParser.zig` -- parses a single Godot XML class doc file and returns supplemental data.

Godot XML doc structure:

```xml
<class name="Node2D" inherits="CanvasItem">
    <brief_description>A 2D game object.</brief_description>
    <description>...</description>
    <tutorials>
        <link title="Custom drawing in 2D">$DOCS_URL/tutorials/2d/custom_drawing_in_2d.html</link>
    </tutorials>
    <methods>
        <method name="apply_scale">
            <description>...</description>
        </method>
    </methods>
</class>
```

**`$DOCS_URL` expansion**: Replace `$DOCS_URL` with `https://docs.godotengine.org/en/stable` when rendering tutorial links.

### Merge Strategy

XML data supplements JSON data during markdown cache generation. When generating cached markdown for a symbol, the XML file for that class is parsed and merged before writing to disk.

Merge rules:
- **Tutorials**: New field on `Entry` as `?[]Tutorial` where `Tutorial = struct { title: []const u8, url: []const u8 }`. Rendered as a "Tutorials" section in output.
- **Missing descriptions**: If a JSON entry has no description but the XML does, use the XML description.
- **GlobalScope entries**: XML docs for classes/entries not present in the JSON are added as new `Entry` values to the database.

When using `--godot-extension-api` (custom JSON path), XML supplementation does not apply.

### Tar Extraction

Uses Zig 0.15 stdlib -- no external dependency needed:
- `std.http.Client` for HTTP download
- `std.compress.flate` with gzip container mode for decompression
- `std.tar` for streaming extraction

The pipeline streams download -> decompress -> extract without writing the full tarball to disk. The full tarball is ~50-80 MB compressed; only the XML files (~5 MB) are written to disk.

### Cache Layout

```
~/.cache/gdoc/
├── extension_api.json      # Existing JSON dump
├── xml_docs/               # New: extracted XML files
│   ├── .complete           # Marker file with version string
│   ├── Node2D.xml
│   ├── @GlobalScope.xml
│   └── ...
├── Node2D/
│   └── index.md            # Existing markdown cache
└── ...
```

**Staleness check**: On startup, compare the version in `xml_docs/.complete` against the current `godot --version`. If they differ, re-fetch XML docs. Presence of `.complete` (not just the directory) is the sentinel for a successful fetch.

### Error Handling

- **Version parsing failure** (unexpected format, no hash): Skip XML supplementation, proceed with JSON-only display. Log a warning.
- **Download failure** (network error, 404, rate limit): Skip XML supplementation, proceed with JSON-only display. Log a warning.
- **Partial download** (interrupted stream): No `.complete` marker is written, so next run will retry.
- **Malformed XML**: Skip that individual XML file, proceed with other files. Log which file failed.
- **Disk space**: Rely on OS write errors propagating; ~5 MB of XML is unlikely to be a concern.

In all error cases, gdoc degrades gracefully -- XML supplementation is best-effort, and the tool remains fully functional with JSON-only data.

## Changes

### New dependency

- `zig-xml` (`ianprime0509/zig-xml`) -- XML pull parser, 0BSD license

### New files

- `src/XmlDocParser.zig` -- Parses Godot XML doc files, returns supplemental data (tutorials, descriptions, GlobalScope entries)
- `src/source_fetch.zig` -- Version parsing, tarball download, streaming extraction of XML docs

### Modified files

- `build.zig.zon` -- Add zig-xml dependency
- `build.zig` -- Wire zig-xml into modules
- `src/DocDatabase.zig` -- Add `tutorials` field to `Entry`, possibly new `EntryKind` values for GlobalScope items
- `src/root.zig` -- Merge XML data during cache generation, trigger XML fetch in cache population flow
- `src/cache.zig` -- Extend cache population to include XML fetch, update sentinel/staleness check

### No breaking changes

Existing CLI interface unchanged. `--clear-cache` clears everything including XML docs.

### Known limitations

- XML docs total ~800+ files across `doc/classes/` and `modules/*/doc_classes/`, consuming ~5 MB on disk.
- Full tarball must be streamed even though only XML files are extracted (tar is sequential).
