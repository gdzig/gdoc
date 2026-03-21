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

New fields on `Entry`: `inherits`, `qualifiers`, `default_value` (the existing struct has `key`, `name`, `kind`, `description`, `brief_description`, `signature`, `members`, `tutorials`).

New `EntryKind` value: `constructor` (added to existing set which already includes `operator`).

The `DocDatabase` remains a flat symbol table keyed by dotted paths (`"Vector2.abs"`, `"@GlobalScope.sin"`). Utility functions from `@GlobalScope.xml` and `@GDScript.xml` are registered both under their qualified name and as top-level entries for convenience (e.g., both `"@GlobalScope.abs"` and `"abs"`). If both files define the same function name, `@GlobalScope` wins (it is the canonical source; `@GDScript` contains GDScript-specific helpers like `preload`).

**Builtin class detection:** XML docs don't distinguish builtin classes from regular classes. Builtins are identified by a hardcoded list matching the Variant types (Vector2, Vector3, Color, AABB, Basis, Transform2D, Transform3D, Projection, Quaternion, Plane, Rect2, Rect2i, Vector2i, Vector3i, Vector4, Vector4i, RID, Callable, Signal, Dictionary, Array, NodePath, StringName, String, PackedByteArray, PackedInt32Array, PackedInt64Array, PackedFloat32Array, PackedFloat64Array, PackedStringArray, PackedVector2Array, PackedVector3Array, PackedColorArray, PackedVector4Array, int, float, bool, Nil). This list is stable across Godot versions.

**Enum extraction from XML:** XML stores enums within `<constants>` elements using an `enum` attribute (e.g., `<constant name="PROCESS_MODE_INHERIT" value="0" enum="ProcessMode">`). Constants with the same `enum` attribute are grouped into enum entries with kind `enum_value`, keyed as `"ClassName.EnumName.VALUE_NAME"`.

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
- **`DocDatabase.loadFromJsonFileLeaky`** — all JSON parsing logic in `DocDatabase.zig`
- **`--godot-extension-api` CLI flag** — and the `api_json_path` parameter threaded through `markdownForSymbol`, `formatAndDisplay`, and `renderWithZigdown`
- **`mergeXmlDocs`** in `root.zig` — no more supplementation
- **`fetchXmlDocs`** as a separate supplementation step — XML fetch becomes the main path
- **`api.generateApiJsonIfNotExists`** call in cache flow
- **`getJsonCachePathInDir`** and JSON-specific cache helpers in `cache.zig`
- **JSON cache file** (`extension_api.json`) from cache directory
- **`--no-xml` / `GDOC_NO_XML`** — the `no_xml` field on `Config` becomes meaningless since XML is the sole source
- **Tests using JSON fixtures** — tests in `root.zig` that create inline JSON (e.g., `markdownForSymbol returns ApiFileNotFound`) are deleted, not rewritten; the JSON path no longer exists

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

The `godot` binary is only used for `--version` (to match the tarball URL), never for `--dump-extension-api`. If `godot` is not on PATH, the tool errors with a clear message: "godot not found. Install Godot and ensure it's on your PATH." This matches the current behavior — `godot` has always been required for JSON export too.

`cache.cacheIsPopulated` checks for the `xml_docs/.complete` marker plus the existence of at least one generated markdown directory (e.g., `Object/index.md` as the sentinel — `Object` is the root of the class hierarchy and is always present).

### DocDatabase.loadFromXmlDir

New entry point replacing `loadFromJsonFileLeaky`. Behavior:

1. Open `xml_dir` and iterate all `.xml` files
2. For each file, call `XmlDocParser.parseClassDoc` (using an arena allocator so all strings outlive the function)
3. Create a class-level `Entry` with kind determined by the builtin list (see Data Model above)
4. For each member category (methods, properties, signals, constants, constructors, operators), create child entries keyed as `"ClassName.member_name"`
5. Build `signature` strings from parsed params and return types:
   - Methods: `(param: Type, param2: Type = default) -> ReturnType`
   - Properties: `: Type` (with `= default` if present)
   - Constructors: `(param: Type, ...)` (name is always the class name)
   - Operators: `OperatorName(other: Type) -> ReturnType`
6. For `@GlobalScope.xml` and `@GDScript.xml`, register utility functions as both qualified (`@GlobalScope.sin`) and top-level (`sin`) entries
7. Populate `members` index arrays on class entries pointing to their children

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
- Tests using inline JSON fixtures are deleted (JSON path no longer exists); new tests use inline XML strings
