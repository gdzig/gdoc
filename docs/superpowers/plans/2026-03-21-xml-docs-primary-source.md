# XML Docs as Primary Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace JSON extension API with XML class docs as the sole data source for gdoc.

**Architecture:** Delete all JSON parsing code, expand XmlDocParser to handle constructors/operators/params/qualifiers/defaults, add `DocDatabase.loadFromXmlDir` to build the symbol table from XML files, update cache flow to skip JSON export, update markdown generation to render new fields.

**Tech Stack:** Zig 0.15.1, zig-xml, bbcodez

**Spec:** `docs/superpowers/specs/2026-03-21-xml-docs-primary-source-design.md`

---

## File Map

**Modify:**
- `src/XmlDocParser.zig` — Expand `MemberDoc` with params/qualifiers/return_type/default_value, add `ParamDoc`, parse `<constructors>`, `<operators>`, `<param>`, `<return>`, `qualifiers`/`default` attributes
- `src/DocDatabase.zig` — Remove all JSON parsing, remove `builtin_class` from `EntryKind`, add `constructor` to `EntryKind`, add `inherits`/`qualifiers`/`default_value` to `Entry`, add `loadFromXmlDir`, update `generateMarkdownForEntry` to render new fields (inheritance, constructors, operators, qualifiers, defaults)
- `src/root.zig` — Remove `mergeXmlDocs`, `fetchXmlDocs`, `api_json_path` parameter from all functions, simplify `markdownForSymbol` to XML-only cache flow
- `src/cache.zig` — Remove `getJsonCachePathInDir`, update `cacheIsPopulated` to check `Object/index.md` instead of JSON file
- `src/Config.zig` — Remove `no_xml` field, update `Config.testing`
- `src/cli/root.zig` — Remove `--godot-extension-api` flag, update error handling
- `build.zig` — Keep `bbcodez` (still needed for BBCode→Markdown in descriptions), keep `xml`

**Delete:**
- `src/api.zig` — Entire file

**Update:**
- `snapshots/*.md` — Updated to reflect new markdown format
- Tests throughout — JSON fixture tests deleted, XML fixture tests added

---

### Task 1: Expand XmlDocParser with ParamDoc and new MemberDoc fields

**Files:**
- Modify: `src/XmlDocParser.zig`

- [ ] **Step 1: Write failing test for ParamDoc parsing on methods**

Add test to `src/XmlDocParser.zig` using XML that includes `<param>` and `<return>` elements inside a `<method>`:

```zig
const test_xml_with_params =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node2D" inherits="CanvasItem">
    \\    <brief_description>A 2D game object.</brief_description>
    \\    <description>Node2D is the base class for 2D.</description>
    \\    <methods>
    \\        <method name="get_angle_to" qualifiers="const">
    \\            <return type="float" />
    \\            <param index="0" name="point" type="Vector2" />
    \\            <description>Returns the angle between the node and the point.</description>
    \\        </method>
    \\        <method name="move_local_x">
    \\            <return type="void" />
    \\            <param index="0" name="delta" type="float" />
    \\            <param index="1" name="scaled" type="bool" default="false" />
    \\            <description>Applies a local translation on the X axis.</description>
    \\        </method>
    \\    </methods>
    \\</class>
;

test "parses method params and return type" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_params);
    defer freeClassDoc(allocator, doc);

    const methods = doc.methods.?;
    try std.testing.expectEqual(2, methods.len);

    // First method: get_angle_to
    try std.testing.expectEqualStrings("const", methods[0].qualifiers.?);
    try std.testing.expectEqualStrings("float", methods[0].return_type.?);
    const params0 = methods[0].params.?;
    try std.testing.expectEqual(1, params0.len);
    try std.testing.expectEqualStrings("point", params0[0].name);
    try std.testing.expectEqualStrings("Vector2", params0[0].type);
    try std.testing.expect(params0[0].default_value == null);

    // Second method: move_local_x with default param
    const params1 = methods[1].params.?;
    try std.testing.expectEqual(2, params1.len);
    try std.testing.expectEqualStrings("false", params1[1].default_value.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "parses method params"`
Expected: Compilation error — `MemberDoc` has no field `qualifiers`, `return_type`, `params`

- [ ] **Step 3: Add ParamDoc struct and expand MemberDoc**

In `src/XmlDocParser.zig`, add `ParamDoc` and expand `MemberDoc`:

```zig
pub const ParamDoc = struct {
    name: []const u8,
    type: []const u8,
    default_value: ?[]const u8 = null,
};

pub const MemberDoc = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    qualifiers: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    return_type: ?[]const u8 = null,
    params: ?[]ParamDoc = null,
};
```

Update `parseClassDoc` to parse `qualifiers` attribute on `<method>`, and parse `<return>` and `<param>` elements inside methods. Update `readNestedDescription` to also capture params and return type while walking the method element.

Replace the `<method>` handler with a call to a new `parseMethodElement` function that:
1. Reads the `name` and `qualifiers` attributes
2. Walks child elements collecting `<return type="...">`, `<param name="..." type="..." default="...">`, and `<description>`
3. Returns a fully populated `MemberDoc`

Update `freeClassDoc` to free the new fields on `MemberDoc` (qualifiers, default_value, return_type, params array and each param's fields).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/XmlDocParser.zig
git commit -m "feat: parse method params, return type, and qualifiers from XML"
```

---

### Task 2: Parse property default values from XML

**Files:**
- Modify: `src/XmlDocParser.zig`

- [ ] **Step 1: Write failing test for property default values**

```zig
test "parses property default value" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const props = doc.properties.?;
    try std.testing.expectEqual(1, props.len);
    try std.testing.expectEqualStrings("Vector2(0, 0)", props[0].default_value.?);
    try std.testing.expectEqualStrings("Vector2", props[0].return_type.?);
}
```

Note: The existing `test_xml` already has `<member name="position" type="Vector2" setter="set_position" getter="get_position" default="Vector2(0, 0)">` — we just need to extract the `default` and `type` attributes.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "parses property default"`
Expected: FAIL — `default_value` is null

- [ ] **Step 3: Update member parsing to read default and type attributes**

In `parseClassDoc`, update the `<member>` handler to also read `default` and `type` attributes:

```zig
} else if (std.mem.eql(u8, name, "member")) {
    const member_name = try getAttributeAlloc(allocator, reader, "name") orelse continue;
    const member_type = try getAttributeAlloc(allocator, reader, "type");
    const member_default = try getAttributeAlloc(allocator, reader, "default");
    const desc = try readTextContent(allocator, reader);
    try properties.append(allocator, .{
        .name = member_name,
        .description = desc,
        .return_type = member_type,
        .default_value = member_default,
    });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/XmlDocParser.zig
git commit -m "feat: parse property type and default value from XML"
```

---

### Task 3: Parse constructors and operators from XML

**Files:**
- Modify: `src/XmlDocParser.zig`

- [ ] **Step 1: Write failing test for constructors and operators**

```zig
const test_xml_with_constructors_and_operators =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Vector2">
    \\    <brief_description>A 2D vector.</brief_description>
    \\    <description>2D vector type.</description>
    \\    <constructors>
    \\        <constructor name="Vector2">
    \\            <return type="Vector2" />
    \\            <description>Constructs a default Vector2.</description>
    \\        </constructor>
    \\        <constructor name="Vector2">
    \\            <return type="Vector2" />
    \\            <param index="0" name="x" type="float" />
    \\            <param index="1" name="y" type="float" />
    \\            <description>Constructs from x and y.</description>
    \\        </constructor>
    \\    </constructors>
    \\    <operators>
    \\        <operator name="operator +">
    \\            <return type="Vector2" />
    \\            <param index="0" name="right" type="Vector2" />
    \\            <description>Adds two vectors.</description>
    \\        </operator>
    \\    </operators>
    \\</class>
;

test "parses constructors" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_constructors_and_operators);
    defer freeClassDoc(allocator, doc);

    const ctors = doc.constructors.?;
    try std.testing.expectEqual(2, ctors.len);
    try std.testing.expectEqualStrings("Vector2", ctors[0].name);
    try std.testing.expect(ctors[0].params == null);
    try std.testing.expectEqual(2, ctors[1].params.?.len);
}

test "parses operators" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_constructors_and_operators);
    defer freeClassDoc(allocator, doc);

    const ops = doc.operators.?;
    try std.testing.expectEqual(1, ops.len);
    try std.testing.expectEqualStrings("operator +", ops[0].name);
    try std.testing.expectEqualStrings("Vector2", ops[0].return_type.?);
    try std.testing.expectEqual(1, ops[0].params.?.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "parses constructors"`
Expected: Compilation error — `ClassDoc` has no field `constructors`

- [ ] **Step 3: Add constructors and operators to ClassDoc and parsing**

Add fields to `ClassDoc`:
```zig
constructors: ?[]MemberDoc = null,
operators: ?[]MemberDoc = null,
```

Add array lists in `parseClassDoc`:
```zig
var constructors: std.ArrayListUnmanaged(MemberDoc) = .empty;
defer constructors.deinit(allocator);
var operators: std.ArrayListUnmanaged(MemberDoc) = .empty;
defer operators.deinit(allocator);
```

Add element handlers for `<constructor>`, `<operator>`, and `<signal>` — reuse the same `parseMethodElement` function from Task 1 since they all have identical XML structure (name, optional return, optional params, description). Update the existing `<signal>` handler to use `parseMethodElement` so signal params are captured (e.g., `child_entered_tree(node: Node)`).

Update `freeClassDoc` to free constructors and operators.

Set on doc:
```zig
doc.constructors = if (constructors.items.len > 0) try constructors.toOwnedSlice(allocator) else null;
doc.operators = if (operators.items.len > 0) try operators.toOwnedSlice(allocator) else null;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/XmlDocParser.zig
git commit -m "feat: parse constructors and operators from XML"
```

---

### Task 4: Parse constants with enum attribute from XML

**Files:**
- Modify: `src/XmlDocParser.zig`

- [ ] **Step 1: Write failing test for enum attribute on constants**

```zig
const test_xml_with_enums =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node">
    \\    <brief_description>Base class.</brief_description>
    \\    <description>Base node.</description>
    \\    <constants>
    \\        <constant name="NOTIFICATION_READY" value="13">Ready notification.</constant>
    \\        <constant name="PROCESS_MODE_INHERIT" value="0" enum="ProcessMode">Inherits process mode.</constant>
    \\        <constant name="PROCESS_MODE_ALWAYS" value="3" enum="ProcessMode">Always process.</constant>
    \\    </constants>
    \\</class>
;

test "parses constant value and enum attribute" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_enums);
    defer freeClassDoc(allocator, doc);

    const consts = doc.constants.?;
    try std.testing.expectEqual(3, consts.len);

    // Regular constant — no enum
    try std.testing.expectEqualStrings("13", consts[0].default_value.?);
    try std.testing.expect(consts[0].qualifiers == null);

    // Enum constant — enum name stored in qualifiers field
    try std.testing.expectEqualStrings("0", consts[1].default_value.?);
    try std.testing.expectEqualStrings("ProcessMode", consts[1].qualifiers.?);
}
```

Note: We reuse `qualifiers` on `MemberDoc` to store the `enum` attribute name for constants. This avoids adding yet another field just for this case.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "parses constant value"`
Expected: FAIL — `default_value` is null on constants

- [ ] **Step 3: Update constant parsing to read value and enum attributes**

```zig
} else if (std.mem.eql(u8, name, "constant")) {
    const constant_name = try getAttributeAlloc(allocator, reader, "name") orelse continue;
    const constant_value = try getAttributeAlloc(allocator, reader, "value");
    const constant_enum = try getAttributeAlloc(allocator, reader, "enum");
    const desc = try readTextContent(allocator, reader);
    try constants.append(allocator, .{
        .name = constant_name,
        .description = desc,
        .default_value = constant_value,
        .qualifiers = constant_enum,
    });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/XmlDocParser.zig
git commit -m "feat: parse constant value and enum attribute from XML"
```

---

### Task 5: Update DocDatabase Entry and EntryKind

**Files:**
- Modify: `src/DocDatabase.zig`

- [ ] **Step 1: Write failing test for new Entry fields**

```zig
test "Entry supports inherits, qualifiers, and default_value fields" {
    const entry = Entry{
        .key = "Node2D.position",
        .name = "position",
        .kind = .property,
        .inherits = null,
        .qualifiers = null,
        .default_value = "Vector2(0, 0)",
    };
    try std.testing.expectEqualStrings("Vector2(0, 0)", entry.default_value.?);
}

test "EntryKind has constructor value" {
    const kind: EntryKind = .constructor;
    try std.testing.expect(kind == .constructor);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compilation error — `Entry` has no field `inherits`, `qualifiers`, `default_value`; `EntryKind` has no field `constructor`

- [ ] **Step 3: Update Entry struct and EntryKind enum**

In `src/DocDatabase.zig`:

Add to `EntryKind`:
```zig
constructor,
```

Remove from `EntryKind`:
```zig
builtin_class,
```

Add to `Entry`:
```zig
inherits: ?[]const u8 = null,
qualifiers: ?[]const u8 = null,
default_value: ?[]const u8 = null,
```

- [ ] **Step 4: Fix all compilation errors from builtin_class removal**

Search for all references to `builtin_class` and `.builtin_class` in the codebase and change to `.class`. This includes `loadFromJsonLeaky` and tests that assert `EntryKind.builtin_class`.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/DocDatabase.zig
git commit -m "feat: add inherits, qualifiers, default_value to Entry; add constructor EntryKind; remove builtin_class"
```

---

### Task 6: Add DocDatabase.loadFromXmlDir

**Files:**
- Modify: `src/DocDatabase.zig`

- [ ] **Step 1: Write failing test for loadFromXmlDir**

```zig
test "loadFromXmlDir parses XML files into symbol table" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write a minimal XML file
    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="Sprite2D" inherits="Node2D">
        \\    <brief_description>A sprite node.</brief_description>
        \\    <description>Displays a 2D texture.</description>
        \\    <methods>
        \\        <method name="is_flipped_h" qualifiers="const">
        \\            <return type="bool" />
        \\            <description>Returns true if flipped horizontally.</description>
        \\        </method>
        \\    </methods>
        \\    <members>
        \\        <member name="texture" type="Texture2D" default="null">The texture to display.</member>
        \\    </members>
        \\</class>
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "Sprite2D.xml", .data = xml_content });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);

    // Class entry
    const class_entry = db.symbols.get("Sprite2D");
    try std.testing.expect(class_entry != null);
    try std.testing.expectEqual(EntryKind.class, class_entry.?.kind);
    try std.testing.expectEqualStrings("Node2D", class_entry.?.inherits.?);
    try std.testing.expect(class_entry.?.members != null);

    // Method entry
    const method = db.symbols.get("Sprite2D.is_flipped_h");
    try std.testing.expect(method != null);
    try std.testing.expectEqual(EntryKind.method, method.?.kind);
    try std.testing.expect(std.mem.indexOf(u8, method.?.signature.?, "bool") != null);

    // Property entry
    const prop = db.symbols.get("Sprite2D.texture");
    try std.testing.expect(prop != null);
    try std.testing.expectEqual(EntryKind.property, prop.?.kind);
    try std.testing.expectEqualStrings("null", prop.?.default_value.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compilation error — `DocDatabase` has no declaration `loadFromXmlDir`

- [ ] **Step 3: Implement loadFromXmlDir**

Add a new public function `loadFromXmlDir(arena_allocator: Allocator, tmp_allocator: Allocator, xml_dir_path: []const u8) !DocDatabase`:

1. Open `xml_dir_path` as a directory with `.iterate = true`
2. Iterate all `.xml` files
3. For each file:
   a. Read contents with `tmp_allocator`, parse with `XmlDocParser.parseClassDoc(arena_allocator, content)`, free content
   b. Create class `Entry` with `kind = .class`, set `inherits`, `brief_description`, `description`, `tutorials`
   c. Put class entry into `symbols`
   d. For each member category (methods, properties, signals, constants, constructors, operators):
      - Create child `Entry` with appropriate kind, dotted key (`"ClassName.member_name"`)
      - Build `signature` string (see signature building rules below)
      - Set `qualifiers`, `default_value` from parsed data
      - Put into `symbols`, track index for parent's `members` array
      - **Enum grouping for constants:** If a constant has an `enum` attribute (stored in `qualifiers` by the parser), key it as `"ClassName.EnumName.VALUE_NAME"` with `kind = .enum_value`. Constants without `enum` attribute are keyed as `"ClassName.CONSTANT_NAME"` with `kind = .constant`.
   e. Update class entry's `members` with collected indices
4. Handle `@GlobalScope.xml` and `@GDScript.xml`: also register their methods as top-level entries with `kind = .global_function` (not `.method`), e.g., both `"@GlobalScope.sin"` and `"sin"`. `@GlobalScope` entries take precedence over `@GDScript`.

**Signature building rules:**
- Methods: `(param: Type, param2: Type = default) -> ReturnType` (omit `-> void`)
- Properties: `: Type`
- Constructors: `(param: Type, ...)` (name is class name, no return type shown)
- Operators: format as `(right: Type) -> ReturnType`
- Constants with value: ` = value`

Helper function `buildSignature(allocator, member, kind) !?[]const u8` handles this.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Write test for enum grouping in loadFromXmlDir**

```zig
test "loadFromXmlDir groups constants with enum attribute as enum_value entries" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="Node">
        \\    <brief_description>Base class.</brief_description>
        \\    <description>Base node.</description>
        \\    <constants>
        \\        <constant name="NOTIFICATION_READY" value="13">Ready.</constant>
        \\        <constant name="PROCESS_MODE_INHERIT" value="0" enum="ProcessMode">Inherits.</constant>
        \\        <constant name="PROCESS_MODE_ALWAYS" value="3" enum="ProcessMode">Always.</constant>
        \\    </constants>
        \\</class>
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "Node.xml", .data = xml_content });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);

    // Regular constant: keyed as ClassName.CONSTANT_NAME
    const notif = db.symbols.get("Node.NOTIFICATION_READY");
    try std.testing.expect(notif != null);
    try std.testing.expectEqual(EntryKind.constant, notif.?.kind);

    // Enum constant: keyed as ClassName.EnumName.VALUE_NAME
    const inherit = db.symbols.get("Node.ProcessMode.PROCESS_MODE_INHERIT");
    try std.testing.expect(inherit != null);
    try std.testing.expectEqual(EntryKind.enum_value, inherit.?.kind);

    const always = db.symbols.get("Node.ProcessMode.PROCESS_MODE_ALWAYS");
    try std.testing.expect(always != null);
    try std.testing.expectEqual(EntryKind.enum_value, always.?.kind);
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 7: Write test for @GlobalScope dual-registration**

```zig
test "loadFromXmlDir registers GlobalScope functions as top-level entries" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="@GlobalScope">
        \\    <brief_description>Global scope.</brief_description>
        \\    <description>Global functions.</description>
        \\    <methods>
        \\        <method name="abs">
        \\            <return type="Variant" />
        \\            <param index="0" name="x" type="Variant" />
        \\            <description>Returns absolute value.</description>
        \\        </method>
        \\    </methods>
        \\</class>
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "@GlobalScope.xml", .data = xml_content });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);

    // Should exist under qualified name
    try std.testing.expect(db.symbols.get("@GlobalScope.abs") != null);
    // Should also exist as top-level
    try std.testing.expect(db.symbols.get("abs") != null);
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add src/DocDatabase.zig
git commit -m "feat: add DocDatabase.loadFromXmlDir to build symbol table from XML files"
```

---

### Task 7: Update markdown generation for new fields

**Files:**
- Modify: `src/DocDatabase.zig`
- Update: `snapshots/*.md`

- [ ] **Step 1: Write failing test for inheritance in markdown output**

```zig
test "generateMarkdownForSymbol shows inheritance" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{ .symbols = StringArrayHashMap(Entry).empty };
    defer db.symbols.deinit(allocator);

    try db.symbols.put(allocator, "Node2D", Entry{
        .key = "Node2D",
        .name = "Node2D",
        .kind = .class,
        .inherits = "CanvasItem",
        .brief_description = "A 2D game object.",
    });

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try db.generateMarkdownForSymbol(allocator, "Node2D", &allocating.writer);
    const written = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, written, "*Inherits: CanvasItem*") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — output doesn't contain inheritance line

- [ ] **Step 3: Update generateMarkdownForEntry**

In `generateMarkdownForEntry`, after writing the heading, add:

```zig
if (entry.inherits) |inherits| {
    try writer.print("\n*Inherits: {s}*\n", .{inherits});
}
```

Update `generateMemberListings` to add `constructor` and `operator` sections:

```zig
var constructors: ArrayList(usize) = .empty;
var operators: ArrayList(usize) = .empty;
defer constructors.deinit(allocator);
defer operators.deinit(allocator);

// In the switch:
.constructor => try constructors.append(allocator, idx),
.operator => try operators.append(allocator, idx),

// Render sections:
try self.formatMemberSection("Constructors", constructors.items, writer);
// Render constructors BEFORE methods, operators AFTER methods
```

Update `formatMemberLine` to show qualifiers and default values:

```zig
// After signature, before closing **
if (member.qualifiers) |quals| {
    try writer.print("** `{s}`", .{quals});
} else {
    try writer.writeAll("**");
}

// For properties with defaults:
if (member.default_value) |default| {
    try writer.print(" = `{s}`", .{default});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Update snapshot files**

Run `zig build test` — snapshot tests will update the files. Verify the diffs look correct with `git diff snapshots/`.

- [ ] **Step 6: Commit**

```bash
git add src/DocDatabase.zig snapshots/
git commit -m "feat: render inheritance, constructors, operators, qualifiers, defaults in markdown"
```

---

### Task 8: Remove JSON parsing from DocDatabase

**Files:**
- Modify: `src/DocDatabase.zig`
- Modify: `build.zig`

- [ ] **Step 1: Delete all JSON parsing code**

Remove from `src/DocDatabase.zig`:
- `RootState` enum
- `loadFromJsonFileLeaky` function
- `loadFromJsonLeaky` function
- `parseClasses` function
- `parseClass` function
- `parseEntry` function
- `parseEntryArray` function
- `nextTokenToMarkdownAlloc` function
- `bbcodeToMarkdown` function (only used by JSON parsing — keep a copy if needed by `loadFromXmlDir` for BBCode→Markdown conversion of descriptions)
- All handler maps and handler functions (`MethodKey`, `ConstantKey`, `SignalKey`, `EnumKey`, `PropertyKey`, handler maps)
- All JSON-related imports (`Scanner`, `Reader`, `Token`)
- `InvalidApiJson` from the `Error` enum (this error was only produced by JSON parsing)
- All tests that use `loadFromJsonLeaky` or `loadFromJsonFileLeaky` (tests at lines 511-996)

- [ ] **Step 2: Remove bbcodez from DocDatabase module imports in build.zig**

Check if bbcodez is still used anywhere else. If only DocDatabase used it, remove from `build.zig` module imports. If `root.zig` or other files still use it for BBCode→Markdown conversion of XML descriptions, keep it.

Look at how descriptions flow: XML descriptions contain BBCode (`[b]`, `[code]`, etc.). Currently the JSON path converts BBCode→Markdown via `bbcodeToMarkdown` during JSON parsing. With XML as source, BBCode conversion needs to happen somewhere — either in `loadFromXmlDir` when building entries, or in `generateMarkdownForEntry` when rendering.

Decision: Keep bbcodez, move BBCode→Markdown conversion to `loadFromXmlDir` (convert descriptions as they're stored in Entry). Copy the `bbcodeToMarkdown` helper function to be used by `loadFromXmlDir`.

- [ ] **Step 3: Write test verifying BBCode conversion in loadFromXmlDir**

```zig
test "loadFromXmlDir converts BBCode descriptions to Markdown" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="TestBBCode">
        \\    <brief_description>Has [b]bold[/b] text.</brief_description>
        \\    <description>Uses [code]code[/code] and [i]italic[/i].</description>
        \\</class>
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "TestBBCode.xml", .data = xml_content });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);
    const entry = db.symbols.get("TestBBCode").?;

    // BBCode should be converted to Markdown
    try std.testing.expect(std.mem.indexOf(u8, entry.brief_description.?, "**bold**") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.description.?, "`code`") != null);
}
```

- [ ] **Step 4: Run tests to verify compilation and BBCode test passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All remaining tests pass. JSON tests are gone. BBCode conversion test passes.

- [ ] **Step 5: Commit**

```bash
git add src/DocDatabase.zig build.zig
git commit -m "refactor: remove all JSON parsing code from DocDatabase"
```

---

### Task 9: Remove api.zig and update Config

**Files:**
- Delete: `src/api.zig`
- Modify: `src/Config.zig`
- Modify: `src/root.zig` (remove `pub const api` import)

- [ ] **Step 1: Delete api.zig**

```bash
rm src/api.zig
```

- [ ] **Step 2: Remove no_xml from Config**

In `src/Config.zig`:
- Remove `no_xml: bool` field from `Config` struct
- Remove `.no_xml = hasEnv("GDOC_NO_XML")` from `init`
- Remove `.no_xml = true` from `Config.testing`
- Update the test that asserts `Config.testing.no_xml`
- Keep `hasEnv` function (may be useful later, and it's tiny)

- [ ] **Step 3: Remove api import from root.zig**

Remove `pub const api = @import("api.zig");` from the imports in `src/root.zig`.

- [ ] **Step 4: Run tests to verify compilation**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete api.zig, remove no_xml from Config"
```

---

### Task 10: Update cache.zig — remove JSON helpers, update cacheIsPopulated

**Files:**
- Modify: `src/cache.zig`

- [ ] **Step 1: Write failing test for new cacheIsPopulated logic**

```zig
test "cacheIsPopulated returns true when Object/index.md exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    // Create xml_docs/.complete marker
    const xml_dir = try std.fmt.allocPrint(allocator, "{s}/xml_docs", .{cache_dir});
    defer allocator.free(xml_dir);
    try std.fs.makeDirAbsolute(xml_dir);
    const complete_path = try std.fmt.allocPrint(allocator, "{s}/.complete", .{xml_dir});
    defer allocator.free(complete_path);
    try std.fs.cwd().writeFile(.{ .sub_path = complete_path, .data = "4.4.1" });

    // Create Object/index.md
    const object_dir = try std.fmt.allocPrint(allocator, "{s}/Object", .{cache_dir});
    defer allocator.free(object_dir);
    try std.fs.makeDirAbsolute(object_dir);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{object_dir});
    defer allocator.free(index_path);
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = "# Object\n" });

    const result = try cacheIsPopulated(allocator, cache_dir);
    try std.testing.expect(result);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — current implementation looks for `extension_api.json`

- [ ] **Step 3: Update cacheIsPopulated and remove JSON helpers**

Rewrite `cacheIsPopulated` to check for `xml_docs/.complete` marker and `Object/index.md`:

```zig
pub fn cacheIsPopulated(allocator: Allocator, cache_path: []const u8) !bool {
    // Check xml_docs/.complete marker
    const xml_dir = try getXmlDocsDirInCache(allocator, cache_path);
    defer allocator.free(xml_dir);

    const marker = source_fetch.readCompleteMarker(allocator, xml_dir);
    if (marker) |m| {
        allocator.free(m);
    } else {
        return false;
    }

    // Check Object/index.md sentinel
    const object_path = try resolveSymbolPath(allocator, cache_path, "Object");
    defer allocator.free(object_path);

    const object_file = std.fs.openFileAbsolute(object_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    object_file.close();

    return true;
}
```

Delete `getJsonCachePathInDir`.

Update tests that used `getJsonCachePathInDir` or checked for `extension_api.json`.

- [ ] **Step 4: Run tests to verify all pass**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/cache.zig
git commit -m "refactor: update cacheIsPopulated to check XML marker + Object sentinel, remove JSON helpers"
```

---

### Task 11: Update CLI and root.zig — remove JSON paths, simplify cache flow

**Files:**
- Modify: `src/cli/root.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Remove --godot-extension-api flag from CLI**

In `src/cli/root.zig`:
- Remove the `addFlag` block for `godot-extension-api` (lines 21-26)
- Remove `api_json_path_raw` and `api_json_path` variables (lines 47-48)
- Remove `api_json_path == null` from the help condition (line 54) — just check `ctx.positional_args.len == 0`
- Update `formatAndDisplay` call to remove `api_json_path` argument
- Remove the `error.ApiFileNotFound` and `error.InvalidApiJson` error handlers

- [ ] **Step 2: Remove api_json_path from function signatures in root.zig**

Update `markdownForSymbol`, `formatAndDisplay`, and `renderWithZigdown` to remove `api_json_path: ?[]const u8` parameter.

- [ ] **Step 3: Remove the JSON-direct-load codepath from markdownForSymbol**

Delete the `if (api_json_file)` branch that loads JSON directly. The function now always uses the cache flow.

- [ ] **Step 4: Simplify the cache rebuild flow**

Replace the current cache rebuild logic with:

```zig
if (needs_full_rebuild) {
    try cache.ensureDirectoryExists(cache_path);

    // Fetch XML docs
    const xml_dir = try cache.getXmlDocsDirInCache(allocator, cache_path);
    defer allocator.free(xml_dir);
    try cache.ensureDirectoryExists(xml_dir);

    const version = source_fetch.getGodotVersion(allocator) orelse
        return error.GodotNotFound;
    defer version.deinit(allocator);

    // Download and extract XML
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

    // Write version marker
    var version_buf: [64]u8 = undefined;
    const version_str = version.formatVersion(&version_buf) orelse return error.GodotNotFound;
    try source_fetch.writeCompleteMarker(allocator, xml_dir, version_str);

    // Build database from XML
    var build_spinner = Spinner{ .message = "Building documentation cache..." };
    build_spinner.start();
    defer build_spinner.finish();

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, xml_dir);
    try cache.generateMarkdownCache(allocator, db, cache_path);
}
```

- [ ] **Step 5: Remove mergeXmlDocs and fetchXmlDocs functions**

Delete both functions from `root.zig`.

- [ ] **Step 6: Remove error types for deleted codepaths**

- Remove `ApiFileNotFound` from `LookupError` error set in `root.zig`. Add `GodotNotFound` if not already there.
- `InvalidApiJson` was already removed from `DocDatabase.Error` in Task 8.

- [ ] **Step 7: Delete JSON fixture tests**

Delete tests in `root.zig` that create inline JSON or test `api_json_path`:
- `markdownForSymbol returns ApiFileNotFound for nonexistent file`
- `markdownForSymbol returns InvalidApiJson for malformed JSON`
- `markdownForSymbol loads from custom API file and finds symbol`
- `markdownForSymbol returns SymbolNotFound when symbol doesn't exist`
- `markdownForSymbol works with relative path`
- `formatAndDisplay with markdown format produces markdown output`
- `formatAndDisplay with terminal format produces terminal output`

Keep cache-flow tests but update them to not create `extension_api.json`.

- [ ] **Step 8: Update imports**

Remove `pub const api = @import("api.zig");` if not already done.

- [ ] **Step 9: Run tests to verify everything compiles and passes**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 10: Commit CLI and root.zig together**

```bash
git add src/root.zig src/cli/root.zig
git commit -m "refactor: remove JSON paths from root.zig and CLI, simplify to XML-only cache flow"
```

---

### Task 12: Update remaining cache-flow tests

**Files:**
- Modify: `src/root.zig`
- Modify: `src/cache.zig`

- [ ] **Step 1: Update markdownForSymbol cache tests**

Update `markdownForSymbol reads from markdown cache when available` — remove the `extension_api.json` creation, ensure `cacheIsPopulated` returns true by creating the new sentinels (xml_docs/.complete + Object/index.md).

Update `markdownForSymbol generates markdown cache when cache is empty` — this test now needs XML docs in the cache instead of JSON. Create a minimal XML file in `xml_docs/` dir with a `.complete` marker, or restructure to test `loadFromXmlDir` + `generateMarkdownCache` directly.

- [ ] **Step 2: Run all tests**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 3: Run the full build**

Run: `zig build`
Expected: Clean build, no errors

- [ ] **Step 4: Commit**

```bash
git add src/root.zig src/cache.zig
git commit -m "test: update cache-flow tests for XML-only architecture"
```

---

### Task 13: Integration test — XML dir to markdown roundtrip

**Files:**
- Modify: `src/DocDatabase.zig` (or `src/root.zig`)

- [ ] **Step 1: Write integration test**

```zig
test "XML dir to markdown roundtrip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write a realistic XML doc
    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="TestClass" inherits="RefCounted">
        \\    <brief_description>A test class.</brief_description>
        \\    <description>A class for testing.</description>
        \\    <tutorials>
        \\        <link title="Test Tutorial">https://example.com</link>
        \\    </tutorials>
        \\    <constructors>
        \\        <constructor name="TestClass">
        \\            <return type="TestClass" />
        \\            <description>Default constructor.</description>
        \\        </constructor>
        \\    </constructors>
        \\    <methods>
        \\        <method name="do_thing" qualifiers="const">
        \\            <return type="bool" />
        \\            <param index="0" name="value" type="int" />
        \\            <description>Does a thing.</description>
        \\        </method>
        \\    </methods>
        \\    <members>
        \\        <member name="speed" type="float" default="1.0">Movement speed.</member>
        \\    </members>
        \\    <operators>
        \\        <operator name="operator *">
        \\            <return type="TestClass" />
        \\            <param index="0" name="right" type="float" />
        \\            <description>Multiplies by a scalar.</description>
        \\        </operator>
        \\    </operators>
        \\    <constants>
        \\        <constant name="MAX_SPEED" value="100">Maximum speed.</constant>
        \\    </constants>
        \\</class>
    ;

    // Write XML to a subdir
    const xml_dir = try std.fmt.allocPrint(allocator, "{s}/xml", .{tmp_path});
    defer allocator.free(xml_dir);
    try std.fs.makeDirAbsolute(xml_dir);
    const xml_path = try std.fmt.allocPrint(allocator, "{s}/TestClass.xml", .{xml_dir});
    defer allocator.free(xml_path);
    try std.fs.cwd().writeFile(.{ .sub_path = xml_path, .data = xml_content });

    // Load from XML
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, xml_dir);

    // Generate markdown
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    try cache.generateMarkdownCache(allocator, db, cache_dir);

    // Read back the class markdown
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try cache.readSymbolMarkdown(allocator, "TestClass", cache_dir, &output.writer);
    const written = output.written();

    // Verify key content
    try std.testing.expect(std.mem.indexOf(u8, written, "# TestClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "*Inherits: RefCounted*") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Tutorials") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Constructors") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Methods") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Properties") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Constants") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Operators") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "do_thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "speed") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "operator *") != null);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test 2>&1 | grep "XML dir to markdown"`
Expected: PASS

- [ ] **Step 3: Update snapshot files**

Run full test suite, verify snapshots:
```bash
zig build test
git diff snapshots/
```

- [ ] **Step 4: Commit**

```bash
git add src/ snapshots/
git commit -m "test: add XML-to-markdown roundtrip integration test, update snapshots"
```

---

### Task 14: Error-path replacement tests

**Files:**
- Modify: `src/DocDatabase.zig` or `src/root.zig`

- [ ] **Step 1: Write test for XML parse failure**

`loadFromXmlDir` should propagate zig-xml parse errors when encountering malformed XML. The specific error variant depends on what `zig-xml` returns — check the actual error set from `XmlDocParser.parseClassDoc` (likely `error.MalformedXml` or a zig-xml `SyntaxError`). Use `expectError` with the correct variant:

```zig
test "loadFromXmlDir returns error for malformed XML" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write a malformed XML file
    try tmp_dir.dir.writeFile(.{ .sub_path = "Bad.xml", .data = "<?xml version=\"1.0\" ?>\n<class name=\"Bad\"><broken" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Expect a parse error — use the actual error variant from zig-xml/XmlDocParser
    const result = DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);
    try std.testing.expect(std.meta.isError(result));
}
```

- [ ] **Step 2: Write test for symbol not found in XML-built database**

```zig
test "lookupSymbolExact returns SymbolNotFound for missing symbol in XML database" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write a valid XML file
    try tmp_dir.dir.writeFile(.{ .sub_path = "Node.xml", .data =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="Node" inherits="Object">
        \\    <brief_description>Base class.</brief_description>
        \\    <description>Base node class.</description>
        \\</class>
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);
    const result = db.lookupSymbolExact("NonExistent");
    try std.testing.expectError(DocDatabase.Error.SymbolNotFound, result);
}
```

- [ ] **Step 3: Write test for missing cache directory**

```zig
test "cacheIsPopulated returns false for nonexistent directory" {
    const allocator = std.testing.allocator;
    const result = try cache.cacheIsPopulated(allocator, "/tmp/gdoc-nonexistent-test-path");
    try std.testing.expect(!result);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | grep -E "PASS|FAIL"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/DocDatabase.zig src/cache.zig
git commit -m "test: add error-path tests for XML parse failure, missing symbols, missing cache"
```

---

### Task 15: Final cleanup and verification

**Files:**
- All modified files

- [ ] **Step 1: Verify no dead code remains**

Search for any remaining references to removed items:

```bash
grep -rn "api_json\|extension_api\|loadFromJson\|builtin_class\|no_xml\|GDOC_NO_XML\|api\.zig\|mergeXmlDocs\|fetchXmlDocs" src/
```

Expected: No matches

- [ ] **Step 2: Run full test suite**

```bash
zig build test
```

Expected: All tests pass, no warnings

- [ ] **Step 3: Test the binary manually**

```bash
zig build run -- --clear-cache
zig build run -- Node2D
zig build run -- Vector2
zig build run -- sin
zig build run -- Node2D.position
```

Expected: Each command shows documentation with the new format (inheritance, constructors where applicable, etc.)

- [ ] **Step 4: Final commit if any remaining changes**

```bash
git add -A
git commit -m "chore: final cleanup for XML-only doc source migration"
```
