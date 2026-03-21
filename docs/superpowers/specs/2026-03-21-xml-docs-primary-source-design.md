# Replace JSON Docs with XML as Primary Source

**Date:** 2026-03-21
**Status:** Proposed

## Summary

Replace the JSON extension API (`extension_api.json` from `godot --dump-extension-api`) with Godot's XML class documentation as the sole data source for gdoc. The XML docs are the upstream source from which the JSON is generated, and they contain significantly richer information: tutorials, code examples, constructors, operators, property defaults, and method qualifiers.

## Motivation

The current architecture uses JSON as the primary source and XML as a supplement to fill gaps. This is backwards — the XML docs are the authoritative, hand-curated source, and the JSON is a machine-generated subset designed for GDExtension binding generators, not human documentation. JSON-only data (hashes, memory sizes, native structures) is irrelevant to a doc viewer.

Key XML advantages over JSON:
- **Tutorials** with documentation links
- **Constructors** (e.g., `Vector2(x, y)`)
- **Operators** (e.g., `Vector2 * float`)
- **Property default values** (e.g., `default="Vector2(0, 0)"`)
- **Method qualifiers** (`virtual`, `const`, `static`)
- **Code examples** in `[codeblock]` sections
- **Richer descriptions** — XML is hand-written; JSON strips or abbreviates

## Design

### Data Model

The `DocDatabase.Entry` struct expands to hold everything XML provides:

```
Entry {
    key                 // "Node2D" or "Node2D.position"
    name                // "Node2D" or "position"
    kind                // class, builtin_class, method, property, signal, constant,
                        //   enum_value, constructor, operator, utility_function
    inherits            // "CanvasItem" (classes only)
    description         // full BBCode description
    brief_description
    signature           // ": Vector2", "(x: float, y: float) -> Vector2", etc.
    qualifiers          // "virtual const", "static" (methods only)
    default_value       // "Vector2(0, 0)" (properties only)
    members             // indices of child entries
    tutorials           // [{title, url}]
}
```

New `EntryKind` values added: `constructor`, `operator`.

The `DocDatabase` remains a flat symbol table keyed by dotted paths (`"Vector2.abs"`, `"@GlobalScope.sin"`). Utility functions from `@GlobalScope.xml` and `@GDScript.xml` are registered both under their qualified name and as top-level entries for convenience (e.g., both `"@GlobalScope.abs"` and `"abs"`).

### XmlDocParser Expansion

The parser currently handles: `brief_description`, `description`, `tutorials`, `methods`, `members` (properties), `signals`, `constants`.

New parsing:

- **`<constructors>`** — same structure as methods (name, params, return type, description)
- **`<operators>`** — name like `operator +`, params, return type, description
- **`inherits` attribute** on `<class>` — already parsed, now stored in DocDatabase
- **Method `qualifiers` attribute** — `"virtual const"`, `"static"`, etc.
- **Property `default` attribute** — `default="Vector2(0, 0)"`
- **Method/constructor/operator params** — `name`, `type`, `default` per param
- **Return types** — `<return type="float" />`

Expanded structs:

```
ClassDoc {
    name, inherits, brief_description, description, tutorials
    methods, properties, signals, constants                     // existing
    constructors                                                // new
    operators                                                   // new
}

MemberDoc {
    name, description                                           // existing
    qualifiers                                                  // new
    default_value                                               // new
    return_type                                                 // new
    params: []ParamDoc                                          // new
}

ParamDoc {
    name, type, default_value
}
```

### Removals

- **`api.zig`** — entire file (runs `godot --dump-extension-api`)
- **`DocDatabase.loadFromJsonFileLeaky`** — JSON parsing logic in `DocDatabase.zig`
- **`--api-json` CLI flag** — and `api_json_path` parameter threaded through `markdownForSymbol` / `formatAndDisplay`
- **`mergeXmlDocs`** in `root.zig` — no more supplementation
- **`fetchXmlDocs`** as a separate supplementation step — XML fetch becomes the main path
- **`api.generateApiJsonIfNotExists`** call in cache flow
- **`getJsonCachePathInDir`** and JSON-specific cache helpers in `cache.zig`
- **JSON cache file** (`extension_api.json`) from cache directory

**Kept:**
- **`bbcodez`** — still needed for BBCode→Markdown conversion in descriptions
- **`source_fetch.zig`** — still fetches XML docs from GitHub tarballs
- **`XmlDocParser.zig`** — expanded
- **`cache.zig`** — adapted to build from XML instead of JSON

### New Cache Flow

Current: `godot --dump-extension-api` → JSON → merge XML → generate markdown cache

New:

```
1. Check cache populated (markdown sentinel files exist)
2. If not:
   a. godot --version → get version string
   b. Download source tarball from GitHub → extract XML to cache/xml_docs/
   c. Parse all XML files → build DocDatabase (new: DocDatabase.loadFromXmlDir)
   d. Generate markdown cache from DocDatabase
3. Read symbol markdown from cache
```

The `godot` binary is only used for `--version` (to match the tarball URL), never for `--dump-extension-api`.

`cache.cacheIsPopulated` checks for the `xml_docs/.complete` marker plus sentinel markdown files.

### Markdown Output Format

With the expanded data model, generated markdown per class becomes richer:

```markdown
# Vector2

*Inherits: none*

A 2D vector using floating-point coordinates.

## Description

A 2-element structure that can be used to represent 2D coordinates...

## Tutorials

- [Math documentation index](https://docs.godotengine.org/en/stable/tutorials/math/index.html)
- [Vector math](https://docs.godotengine.org/en/stable/tutorials/math/vector_math.html)

## Properties

- **x: float** = `0.0` — The vector's X component.
- **y: float** = `0.0` — The vector's Y component.

## Constructors

- **Vector2()** — Constructs a default-initialized Vector2...
- **Vector2(from: Vector2i)** — Constructs a new Vector2 from Vector2i.
- **Vector2(x: float, y: float)** — Constructs a new Vector2...

## Methods

- **abs() -> Vector2** `const` — Returns a new vector with all components in absolute values.
- **angle() -> float** `const` — Returns this vector's angle...

## Operators

- **Vector2 * float -> Vector2** — Multiplies each component...
- **Vector2 + Vector2 -> Vector2** — Adds each component...

## Constants

- **ZERO = Vector2(0, 0)** — Zero vector...
- **ONE = Vector2(1, 1)** — One vector...
```

Key additions vs current output:
- Inheritance line
- Property default values
- Constructors section
- Full method signatures with params, return types, and qualifiers
- Operators section

## Testing

- Existing snapshot tests updated to reflect new markdown format
- New snapshots for classes with constructors/operators (e.g., Vector2)
- Unit tests for expanded XmlDocParser (constructors, operators, qualifiers, defaults, params)
- Integration test: XML dir → DocDatabase → markdown output roundtrip
- Tests that previously used inline JSON fixtures rewritten to use inline XML fixtures
