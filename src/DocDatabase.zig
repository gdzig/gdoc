const DocDatabase = @This();

const parser_log = std.log.scoped(.parser);

symbols: StringArrayHashMap(Entry) = .empty,

pub const Error = error{
    SymbolNotFound,
};

pub const EntryKind = enum {
    class,
    constructor,
    method,
    property,
    constant,
    enum_value,
    global_function,
    operator,
    signal,
};

pub const Tutorial = struct {
    title: []const u8,
    url: []const u8,
};

pub const Entry = struct {
    key: []const u8,
    name: []const u8,
    parent_index: ?usize = null,
    kind: EntryKind,
    description: ?[]const u8 = null,
    brief_description: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    members: ?[]usize = null,
    tutorials: ?[]const Tutorial = null,
    inherits: ?[]const u8 = null,
    qualifiers: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
};

fn bbcodeToMarkdown(allocator: Allocator, input: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);

    const bbcode_doc = try bbcodez.loadFromBuffer(allocator, input, .{});
    defer bbcode_doc.deinit();

    try bbcodez.fmt.md.renderDocument(allocator, bbcode_doc, &output.writer, .{});

    return try output.toOwnedSlice();
}

pub fn lookupSymbolExact(self: DocDatabase, symbol: []const u8) DocDatabase.Error!Entry {
    return self.symbols.get(symbol) orelse return DocDatabase.Error.SymbolNotFound;
}

pub fn loadFromXmlDir(arena_allocator: Allocator, tmp_allocator: Allocator, xml_dir_path: []const u8) !DocDatabase {
    var db: DocDatabase = .{};

    var dir = try std.fs.openDirAbsolute(xml_dir_path, .{ .iterate = true });
    defer dir.close();

    // First pass: collect all files, parse them, register classes.
    // We need two passes for GlobalScope precedence, but we can do it in one
    // by deferring global registration.
    const GlobalEntry = struct {
        key: []const u8,
        entry: Entry,
    };
    var global_scope_entries: ArrayList(GlobalEntry) = .empty;
    defer global_scope_entries.deinit(tmp_allocator);
    var gdscript_entries: ArrayList(GlobalEntry) = .empty;
    defer gdscript_entries.deinit(tmp_allocator);

    var iter = dir.iterate();
    while (iter.next() catch return error.ReadFailed) |dir_entry| {
        if (dir_entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, dir_entry.name, ".xml")) continue;

        const content = dir.readFileAlloc(tmp_allocator, dir_entry.name, 2 * 1024 * 1024) catch continue;
        defer tmp_allocator.free(content);

        const class_doc = XmlDocParser.parseClassDoc(arena_allocator, content) catch |err| {
            const class_name = dir_entry.name[0 .. dir_entry.name.len - 4];
            parser_log.warn("failed to parse XML doc for {s}: {}", .{ class_name, err });
            continue;
        };

        // Convert tutorials
        const db_tutorials: ?[]const Tutorial = if (class_doc.tutorials) |tutorials| blk: {
            const result = try arena_allocator.alloc(Tutorial, tutorials.len);
            for (tutorials, 0..) |t, i| {
                result[i] = .{ .title = t.title, .url = t.url };
            }
            break :blk result;
        } else null;

        // Convert BBCode descriptions to Markdown
        const description = if (class_doc.description) |desc|
            bbcodeToMarkdown(arena_allocator, desc) catch desc
        else
            null;
        const brief_description = if (class_doc.brief_description) |desc|
            bbcodeToMarkdown(arena_allocator, desc) catch desc
        else
            null;

        // Create class entry
        const class_key = class_doc.name;
        try db.symbols.put(arena_allocator, class_key, .{
            .key = class_key,
            .name = class_key,
            .kind = .class,
            .description = description,
            .brief_description = brief_description,
            .inherits = class_doc.inherits,
            .tutorials = db_tutorials,
        });
        const class_idx = db.symbols.getIndex(class_key).?;

        var member_indices: ArrayList(usize) = .empty;
        defer member_indices.deinit(tmp_allocator);

        const is_global_scope = std.mem.eql(u8, class_doc.name, "@GlobalScope");
        const is_gdscript = std.mem.eql(u8, class_doc.name, "@GDScript");

        // Process methods
        if (class_doc.methods) |methods| {
            for (methods) |method| {
                const sig = try buildMethodSignature(arena_allocator, method);
                const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, method.name });
                const child_kind: EntryKind = if (is_global_scope or is_gdscript) .global_function else .method;
                const desc = if (method.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                const child: Entry = .{
                    .key = dotted_key,
                    .name = method.name,
                    .parent_index = class_idx,
                    .kind = child_kind,
                    .description = desc,
                    .signature = sig,
                    .qualifiers = method.qualifiers,
                };
                try db.symbols.put(arena_allocator, dotted_key, child);
                const child_idx = db.symbols.getIndex(dotted_key).?;
                try member_indices.append(tmp_allocator, child_idx);

                // Track for top-level registration
                if (is_global_scope) {
                    try global_scope_entries.append(tmp_allocator, .{ .key = method.name, .entry = child });
                } else if (is_gdscript) {
                    try gdscript_entries.append(tmp_allocator, .{ .key = method.name, .entry = child });
                }
            }
        }

        // Process properties
        if (class_doc.properties) |properties| {
            for (properties) |prop| {
                const sig = try buildPropertySignature(arena_allocator, prop);
                const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, prop.name });
                const desc = if (prop.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                const child: Entry = .{
                    .key = dotted_key,
                    .name = prop.name,
                    .parent_index = class_idx,
                    .kind = .property,
                    .description = desc,
                    .signature = sig,
                    .default_value = prop.default_value,
                };
                try db.symbols.put(arena_allocator, dotted_key, child);
                const child_idx = db.symbols.getIndex(dotted_key).?;
                try member_indices.append(tmp_allocator, child_idx);
            }
        }

        // Process signals
        if (class_doc.signals) |signals| {
            for (signals) |signal| {
                const sig = try buildSignalSignature(arena_allocator, signal);
                const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, signal.name });
                const desc = if (signal.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                const child: Entry = .{
                    .key = dotted_key,
                    .name = signal.name,
                    .parent_index = class_idx,
                    .kind = .signal,
                    .description = desc,
                    .signature = sig,
                };
                try db.symbols.put(arena_allocator, dotted_key, child);
                const child_idx = db.symbols.getIndex(dotted_key).?;
                try member_indices.append(tmp_allocator, child_idx);
            }
        }

        // Process constants (with enum grouping)
        if (class_doc.constants) |constants| {
            for (constants) |constant| {
                const sig = try buildConstantSignature(arena_allocator, constant);
                const desc = if (constant.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                if (constant.qualifiers) |enum_name| {
                    // Enum-grouped constant: "ClassName.EnumName.VALUE_NAME"
                    const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}.{s}", .{ class_doc.name, enum_name, constant.name });
                    const child: Entry = .{
                        .key = dotted_key,
                        .name = constant.name,
                        .parent_index = class_idx,
                        .kind = .enum_value,
                        .description = desc,
                        .signature = sig,
                        .qualifiers = constant.qualifiers,
                        .default_value = constant.default_value,
                    };
                    try db.symbols.put(arena_allocator, dotted_key, child);
                    const child_idx = db.symbols.getIndex(dotted_key).?;
                    try member_indices.append(tmp_allocator, child_idx);
                } else {
                    // Regular constant: "ClassName.CONSTANT_NAME"
                    const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, constant.name });
                    const child: Entry = .{
                        .key = dotted_key,
                        .name = constant.name,
                        .parent_index = class_idx,
                        .kind = .constant,
                        .description = desc,
                        .signature = sig,
                        .default_value = constant.default_value,
                    };
                    try db.symbols.put(arena_allocator, dotted_key, child);
                    const child_idx = db.symbols.getIndex(dotted_key).?;
                    try member_indices.append(tmp_allocator, child_idx);
                }
            }
        }

        // Process constructors
        if (class_doc.constructors) |constructors| {
            for (constructors) |ctor| {
                const sig = try buildConstructorSignature(arena_allocator, ctor);
                const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, ctor.name });
                const desc = if (ctor.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                const child: Entry = .{
                    .key = dotted_key,
                    .name = ctor.name,
                    .parent_index = class_idx,
                    .kind = .constructor,
                    .description = desc,
                    .signature = sig,
                };
                // Constructors may have duplicate keys (overloads); only keep first
                if (db.symbols.get(dotted_key) == null) {
                    try db.symbols.put(arena_allocator, dotted_key, child);
                    const child_idx = db.symbols.getIndex(dotted_key).?;
                    try member_indices.append(tmp_allocator, child_idx);
                }
            }
        }

        // Process operators
        if (class_doc.operators) |operators| {
            for (operators) |op| {
                const sig = try buildOperatorSignature(arena_allocator, op);
                const dotted_key = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ class_doc.name, op.name });
                const desc = if (op.description) |d|
                    bbcodeToMarkdown(arena_allocator, d) catch d
                else
                    null;
                const child: Entry = .{
                    .key = dotted_key,
                    .name = op.name,
                    .parent_index = class_idx,
                    .kind = .operator,
                    .description = desc,
                    .signature = sig,
                };
                if (db.symbols.get(dotted_key) == null) {
                    try db.symbols.put(arena_allocator, dotted_key, child);
                    const child_idx = db.symbols.getIndex(dotted_key).?;
                    try member_indices.append(tmp_allocator, child_idx);
                }
            }
        }

        // Update class entry's members
        if (member_indices.items.len > 0) {
            const members_slice = try arena_allocator.dupe(usize, member_indices.items);
            var class_ptr = db.symbols.getPtr(class_key).?;
            class_ptr.members = members_slice;
        }
    }

    // Register @GDScript functions as top-level (lower precedence)
    for (gdscript_entries.items) |ge| {
        if (db.symbols.get(ge.key) == null) {
            var entry = ge.entry;
            entry.key = try arena_allocator.dupe(u8, ge.key);
            try db.symbols.put(arena_allocator, entry.key, entry);
        }
    }

    // Register @GlobalScope functions as top-level (higher precedence, overwrites)
    for (global_scope_entries.items) |ge| {
        var entry = ge.entry;
        entry.key = try arena_allocator.dupe(u8, ge.key);
        try db.symbols.put(arena_allocator, entry.key, entry);
    }

    return db;
}

fn buildMethodSignature(allocator: Allocator, method: XmlDocParser.MemberDoc) !?[]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    try buf.writer.writeByte('(');
    try writeParams(&buf.writer, method.params);
    try buf.writer.writeByte(')');

    if (method.return_type) |rt| {
        if (!std.mem.eql(u8, rt, "void")) {
            try buf.writer.print(" -> {s}", .{rt});
        }
    }

    return try buf.toOwnedSlice();
}

fn buildPropertySignature(allocator: Allocator, prop: XmlDocParser.MemberDoc) !?[]const u8 {
    if (prop.return_type) |rt| {
        return try std.fmt.allocPrint(allocator, ": {s}", .{rt});
    }
    return null;
}

fn buildConstructorSignature(allocator: Allocator, ctor: XmlDocParser.MemberDoc) !?[]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    try buf.writer.writeByte('(');
    try writeParams(&buf.writer, ctor.params);
    try buf.writer.writeByte(')');

    return try buf.toOwnedSlice();
}

fn buildOperatorSignature(allocator: Allocator, op: XmlDocParser.MemberDoc) !?[]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    try buf.writer.writeByte('(');
    try writeParams(&buf.writer, op.params);
    try buf.writer.writeByte(')');

    if (op.return_type) |rt| {
        try buf.writer.print(" -> {s}", .{rt});
    }

    return try buf.toOwnedSlice();
}

fn buildSignalSignature(allocator: Allocator, signal: XmlDocParser.MemberDoc) !?[]const u8 {
    if (signal.params) |_| {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer buf.deinit();

        try buf.writer.writeByte('(');
        try writeParams(&buf.writer, signal.params);
        try buf.writer.writeByte(')');

        return try buf.toOwnedSlice();
    }
    return null;
}

fn buildConstantSignature(allocator: Allocator, constant: XmlDocParser.MemberDoc) !?[]const u8 {
    if (constant.default_value) |val| {
        return try std.fmt.allocPrint(allocator, " = {s}", .{val});
    }
    return null;
}

fn writeParams(writer: *std.Io.Writer, params: ?[]XmlDocParser.ParamDoc) !void {
    if (params) |ps| {
        for (ps, 0..) |p, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}: {s}", .{ p.name, p.type });
            if (p.default_value) |dv| {
                try writer.print(" = {s}", .{dv});
            }
        }
    }
}

fn generateMarkdownForEntry(self: DocDatabase, allocator: Allocator, entry: Entry, writer: *Writer) !void {
    try writer.print("# {s}", .{entry.key});

    if (entry.signature) |sig| {
        try writer.writeAll(sig);
    }

    try writer.writeByte('\n');

    if (entry.inherits) |inherits| {
        try writer.print("\n*Inherits: {s}*\n", .{inherits});
    }

    if (entry.parent_index) |parent_index| {
        const parent = self.symbols.values()[parent_index];
        try writer.print("\n**Parent**: {s}\n", .{parent.name});
    }

    if (entry.brief_description) |brief| {
        try writer.print("\n{s}\n", .{brief});
    }

    if (entry.description) |desc| {
        try writer.print("\n## Description\n\n{s}\n", .{desc});
    }

    if (entry.tutorials) |tutorials| {
        if (tutorials.len > 0) {
            try writer.writeAll("\n## Tutorials\n\n");
            for (tutorials) |tutorial| {
                try writer.print("- [{s}]({s})\n", .{ tutorial.title, tutorial.url });
            }
        }
    }

    if (entry.members) |member_indices| {
        try self.generateMemberListings(allocator, member_indices, writer);
    }
}

fn generateMemberListings(self: DocDatabase, allocator: Allocator, member_indices: []usize, writer: *Writer) !void {
    var constructors: ArrayList(usize) = .empty;
    var properties: ArrayList(usize) = .empty;
    var methods: ArrayList(usize) = .empty;
    var operators: ArrayList(usize) = .empty;
    var signals: ArrayList(usize) = .empty;
    var constants: ArrayList(usize) = .empty;
    var enums: ArrayList(usize) = .empty;

    defer constructors.deinit(allocator);
    defer properties.deinit(allocator);
    defer methods.deinit(allocator);
    defer operators.deinit(allocator);
    defer signals.deinit(allocator);
    defer constants.deinit(allocator);
    defer enums.deinit(allocator);

    for (member_indices) |idx| {
        const member: Entry = self.symbols.values()[idx];
        switch (member.kind) {
            .constructor => try constructors.append(allocator, idx),
            .property => try properties.append(allocator, idx),
            .method => try methods.append(allocator, idx),
            .operator => try operators.append(allocator, idx),
            .signal => try signals.append(allocator, idx),
            .constant => try constants.append(allocator, idx),
            .enum_value => try enums.append(allocator, idx),
            else => continue,
        }
    }

    try self.formatMemberSection("Constructors", constructors.items, writer);
    try self.formatMemberSection("Properties", properties.items, writer);
    try self.formatMemberSection("Methods", methods.items, writer);
    try self.formatMemberSection("Operators", operators.items, writer);
    try self.formatMemberSection("Signals", signals.items, writer);
    try self.formatMemberSection("Constants", constants.items, writer);
    try self.formatMemberSection("Enums", enums.items, writer);
}

fn formatMemberSection(self: DocDatabase, section_name: []const u8, member_indices: []usize, writer: *Writer) !void {
    if (member_indices.len > 0) {
        try writer.print("\n## {s}\n\n", .{section_name});
        for (member_indices) |idx| {
            try self.formatMemberLine(idx, writer);
        }
    }
}

fn formatMemberLine(self: DocDatabase, member_idx: usize, writer: *Writer) !void {
    const member = self.symbols.values()[member_idx];

    try writer.print("- **{s}", .{member.name});

    if (member.signature) |sig| {
        try writer.writeAll(sig);
    }

    if (member.qualifiers) |quals| {
        try writer.print("** `{s}`", .{quals});
    } else {
        try writer.writeAll("**");
    }

    if (member.default_value) |default| {
        try writer.print(" = `{s}`", .{default});
    }

    if (member.brief_description) |brief| {
        try writer.print(" - {s}", .{brief});
    } else if (member.description) |desc| {
        const new_line_idx = std.mem.indexOf(u8, desc, "\n");
        const first_line = if (new_line_idx) |idx| desc[0..idx] else desc;
        try writer.print(" - {s}", .{first_line});
    }

    try writer.writeByte('\n');
}

pub fn generateMarkdownForSymbol(self: DocDatabase, allocator: Allocator, symbol: []const u8, writer: *Writer) !void {
    try self.generateMarkdownForEntry(allocator, self.symbols.get(symbol) orelse return error.SymbolNotFound, writer);
}

// RED PHASE: Tests for DocDatabase.generateMarkdownForSymbol using snapshot testing
test "generateMarkdownForSymbol for global function" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const entry = Entry{
        .key = "sin",
        .name = "sin",
        .kind = .global_function,
        .description = "Returns the sine of angle in radians.",
        .signature = "(angle: float)",
    };
    try db.symbols.put(allocator, "sin", entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/global_function.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "sin", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for class with brief description" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const entry = Entry{
        .key = "Node2D",
        .name = "Node2D",
        .kind = .class,
        .brief_description = "A 2D game object with position and rotation.",
        .description = "Node2D is the base class for all 2D objects.",
    };
    try db.symbols.put(allocator, "Node2D", entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/class_with_brief.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Node2D", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for property with parent" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const parent = Entry{
        .key = "Node2D",
        .name = "Node2D",
        .kind = .class,
    };
    try db.symbols.put(allocator, "Node2D", parent);

    const entry = Entry{
        .key = "Node2D.position",
        .name = "position",
        .parent_index = 0,
        .kind = .property,
        .description = "Position, relative to the node's parent.",
    };
    try db.symbols.put(allocator, "Node2D.position", entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/property_with_parent.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Node2D.position", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for class without brief descriptions" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Create parent class without brief description
    var member_indices = [_]usize{ 1, 2 };
    const class_entry = Entry{
        .key = "Vector2",
        .name = "Vector2",
        .kind = .class,
        .description = "A 2D vector using floating point coordinates.",
        .members = &member_indices,
    };
    try db.symbols.put(allocator, "Vector2", class_entry);

    // Create property member WITHOUT brief description
    const property_entry = Entry{
        .key = "Vector2.x",
        .name = "x",
        .parent_index = 0,
        .kind = .property,
        .signature = ": float",
    };
    try db.symbols.put(allocator, "Vector2.x", property_entry);

    // Create method member WITHOUT brief description
    const method_entry = Entry{
        .key = "Vector2.normalized",
        .name = "normalized",
        .parent_index = 0,
        .kind = .method,
        .signature = "() -> Vector2",
    };
    try db.symbols.put(allocator, "Vector2.normalized", method_entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/class_without_brief.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Vector2", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for method with signature" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Create parent class
    const parent = Entry{
        .key = "Node",
        .name = "Node",
        .kind = .class,
    };
    try db.symbols.put(allocator, "Node", parent);

    // Create method with full signature
    const method_entry = Entry{
        .key = "Node.add_child",
        .name = "add_child",
        .parent_index = 0,
        .kind = .method,
        .brief_description = "Adds a child node.",
        .description = "Adds a child node. Nodes can have any number of children, but every child must have a unique name.",
        .signature = "(node: Node, force_readable_name: bool = false)",
    };
    try db.symbols.put(allocator, "Node.add_child", method_entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/method_with_signature.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Node.add_child", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for global function with signature" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Create global function with signature
    const function_entry = Entry{
        .key = "sin",
        .name = "sin",
        .kind = .global_function,
        .brief_description = "Returns the sine of angle in radians.",
        .description = "Returns the sine of angle `angle_rad` in radians. `sin()` has a high precision and is slower than `sinf()`. If you need better performance, use `sinf()`.",
        .signature = "(angle_rad: float) -> float",
    };
    try db.symbols.put(allocator, "sin", function_entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/global_function_with_signature.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "sin", writer);
    try writer.flush();
}

// RED PHASE: Test for class with member listings
test "generateMarkdownForSymbol for class with members" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    // Create parent class
    var member_indices = [_]usize{ 1, 2, 3 };
    const class_entry = Entry{
        .key = "Node2D",
        .name = "Node2D",
        .kind = .class,
        .brief_description = "A 2D game object.",
        .description = "Node2D is the base class for all 2D scene objects.",
        .members = &member_indices,
    };
    try db.symbols.put(allocator, "Node2D", class_entry);

    // Create property member
    const property_entry = Entry{
        .key = "Node2D.position",
        .name = "position",
        .parent_index = 0,
        .kind = .property,
        .brief_description = "Position relative to parent.",
        .signature = ": Vector2",
    };
    try db.symbols.put(allocator, "Node2D.position", property_entry);

    // Create method member with signature
    const method_entry = Entry{
        .key = "Node2D.get_global_position",
        .name = "get_global_position",
        .parent_index = 0,
        .kind = .method,
        .brief_description = "Returns the global position.",
        .signature = "() -> Vector2",
    };
    try db.symbols.put(allocator, "Node2D.get_global_position", method_entry);

    // Create constant member
    const constant_entry = Entry{
        .key = "Node2D.NOTIFICATION_READY",
        .name = "NOTIFICATION_READY",
        .parent_index = 0,
        .kind = .constant,
        .brief_description = "Ready notification.",
        .signature = ": int",
    };
    try db.symbols.put(allocator, "Node2D.NOTIFICATION_READY", constant_entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/class_with_members.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Node2D", writer);
    try writer.flush();
}

test "generateMarkdownForSymbol for class with tutorials" {
    const allocator = std.testing.allocator;

    var db = DocDatabase{
        .symbols = StringArrayHashMap(Entry).empty,
    };
    defer db.symbols.deinit(allocator);

    const tutorials = [_]Tutorial{
        .{ .title = "Custom drawing in 2D", .url = "https://docs.godotengine.org/en/stable/tutorials/2d/custom_drawing_in_2d.html" },
        .{ .title = "All 2D Demos", .url = "https://github.com/godotengine/godot-demo-projects/tree/master/2d" },
    };

    const entry = Entry{
        .key = "Sprite2D",
        .name = "Sprite2D",
        .kind = .class,
        .brief_description = "General-purpose sprite node.",
        .description = "A node that displays a 2D texture.",
        .tutorials = &tutorials,
    };
    try db.symbols.put(allocator, "Sprite2D", entry);

    // Write snapshot
    var file = try std.fs.cwd().createFile("snapshots/class_with_tutorials.md", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try db.generateMarkdownForSymbol(allocator, "Sprite2D", writer);
    try writer.flush();
}

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

test "loadFromXmlDir parses XML files into symbol table" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const sprite2d_xml =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="Sprite2D" inherits="Node2D">
        \\    <brief_description>A 2D sprite node.</brief_description>
        \\    <description>Displays a 2D texture.</description>
        \\    <methods>
        \\        <method name="is_flipped_h" qualifiers="const">
        \\            <return type="bool" />
        \\            <description>Returns whether the sprite is flipped horizontally.</description>
        \\        </method>
        \\    </methods>
        \\    <members>
        \\        <member name="texture" type="Texture2D" default="null">The texture to display.</member>
        \\    </members>
        \\</class>
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "Sprite2D.xml", .data = sprite2d_xml });

    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), std.testing.allocator, tmp_path);

    // Verify class entry
    const class_entry = db.symbols.get("Sprite2D").?;
    try std.testing.expectEqual(EntryKind.class, class_entry.kind);
    try std.testing.expectEqualStrings("Node2D", class_entry.inherits.?);
    try std.testing.expectEqualStrings("A 2D sprite node.", class_entry.brief_description.?);
    try std.testing.expectEqualStrings("Displays a 2D texture.", class_entry.description.?);

    // Verify method entry
    const method_entry = db.symbols.get("Sprite2D.is_flipped_h").?;
    try std.testing.expectEqual(EntryKind.method, method_entry.kind);
    try std.testing.expect(method_entry.signature != null);
    try std.testing.expect(std.mem.indexOf(u8, method_entry.signature.?, "bool") != null);
    try std.testing.expectEqualStrings("const", method_entry.qualifiers.?);

    // Verify property entry
    const prop_entry = db.symbols.get("Sprite2D.texture").?;
    try std.testing.expectEqual(EntryKind.property, prop_entry.kind);
    try std.testing.expectEqualStrings("null", prop_entry.default_value.?);
}

test "loadFromXmlDir groups constants with enum attribute as enum_value entries" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const node_xml =
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

    try tmp_dir.dir.writeFile(.{ .sub_path = "Node.xml", .data = node_xml });

    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), std.testing.allocator, tmp_path);

    // Regular constant
    const notif_entry = db.symbols.get("Node.NOTIFICATION_READY").?;
    try std.testing.expectEqual(EntryKind.constant, notif_entry.kind);

    // Enum-grouped constants
    const inherit_entry = db.symbols.get("Node.ProcessMode.PROCESS_MODE_INHERIT").?;
    try std.testing.expectEqual(EntryKind.enum_value, inherit_entry.kind);

    const always_entry = db.symbols.get("Node.ProcessMode.PROCESS_MODE_ALWAYS").?;
    try std.testing.expectEqual(EntryKind.enum_value, always_entry.kind);
}

test "loadFromXmlDir registers GlobalScope functions as top-level entries" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const global_scope_xml =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<class name="@GlobalScope">
        \\    <brief_description>Global scope.</brief_description>
        \\    <description>Global scope constants and functions.</description>
        \\    <methods>
        \\        <method name="abs">
        \\            <return type="Variant" />
        \\            <param index="0" name="x" type="Variant" />
        \\            <description>Returns the absolute value.</description>
        \\        </method>
        \\    </methods>
        \\</class>
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "@GlobalScope.xml", .data = global_scope_xml });

    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), std.testing.allocator, tmp_path);

    // Verify dotted key exists
    const dotted_entry = db.symbols.get("@GlobalScope.abs").?;
    try std.testing.expectEqual(EntryKind.global_function, dotted_entry.kind);

    // Verify top-level entry exists
    const top_entry = db.symbols.get("abs").?;
    try std.testing.expectEqual(EntryKind.global_function, top_entry.kind);
}

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
    var arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();
    const db = try DocDatabase.loadFromXmlDir(arena_alloc.allocator(), allocator, xml_dir);

    // Generate markdown cache
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
    try std.testing.expect(std.mem.indexOf(u8, written, "## Operators") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "## Constants") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "do_thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "speed") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "operator *") != null);
}

test "loadFromXmlDir skips malformed XML files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp_dir.dir.writeFile(.{ .sub_path = "Bad.xml", .data = "<?xml version=\"1.0\" ?>\n<class name=\"Bad\"><broken" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const db = try DocDatabase.loadFromXmlDir(arena.allocator(), allocator, tmp_path);
    // Bad file should be skipped, resulting in empty database
    try std.testing.expectEqual(@as(usize, 0), db.symbols.count());
}

test "lookupSymbolExact returns SymbolNotFound for missing symbol in XML database" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

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

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;

const bbcodez = @import("bbcodez");
const cache = @import("cache.zig");
const XmlDocParser = @import("XmlDocParser.zig");
