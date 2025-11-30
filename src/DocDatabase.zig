const DocDatabase = @This();

symbols: StringArrayHashMap(Entry) = .empty,

pub const Error = error{
    SymbolNotFound,
    InvalidApiJson,
};

pub const EntryKind = enum {
    builtin_class,
    class,
    method,
    property,
    constant,
    enum_value,
    global_function,
    operator,
    signal,
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
};

const RootState = enum {
    init,
    builtin_classes,
    classes,
    global_constants,
    global_enums,
    native_structures,
    singletons,
    utility_functions,
};

pub fn loadFromJsonFileLeaky(arena_allocator: Allocator, file: File) !DocDatabase {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    const file_content = try reader.readAlloc(arena_allocator, try file.getEndPos());
    defer arena_allocator.free(file_content);

    var scanner = Scanner.initCompleteInput(arena_allocator, file_content);
    defer scanner.deinit();

    return loadFromJsonLeaky(arena_allocator, &scanner) catch |err| switch (err) {
        Scanner.Error.SyntaxError, Scanner.Error.UnexpectedEndOfInput => return Error.InvalidApiJson,
        else => return err,
    };
}

pub fn loadFromJsonLeaky(arena_allocator: Allocator, scanner: *Scanner) !DocDatabase {
    var db = DocDatabase{};

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                const state = std.meta.stringToEnum(RootState, s) orelse {
                    try scanner.skipValue();
                    continue;
                };

                switch (state) {
                    .builtin_classes => try db.parseClasses(.builtin_class, arena_allocator, scanner),
                    .classes => try db.parseClasses(.class, arena_allocator, scanner),
                    .utility_functions => try db.parseGlobalMethods(arena_allocator, scanner),
                    else => continue,
                }
            },
            .end_of_document => break,
            else => {},
        }
    }

    return db;
}

fn parseGlobalMethods(self: *DocDatabase, allocator: Allocator, scanner: *Scanner) !void {
    std.debug.assert(try scanner.next() == .array_begin);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                const method = try self.parseMethod(.global_function, allocator, scanner);
                try self.symbols.put(allocator, method.key, method);
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }
}

fn parseClasses(self: *DocDatabase, comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner) !void {
    std.debug.assert(try scanner.next() == .array_begin);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                try self.parseClass(allocator, scanner, kind);
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }
}

const ClassKey = enum {
    name,
    methods,
    properties,
    signals,
    constants,
    description,
    brief_description,
    enums,
};

fn bbcodeToMarkdown(allocator: Allocator, input: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);

    const bbcode_doc = try bbcodez.loadFromBuffer(allocator, input, .{});
    defer bbcode_doc.deinit();

    try bbcodez.fmt.md.renderDocument(allocator, bbcode_doc, &output.writer, .{});

    return try output.toOwnedSlice();
}

fn parseClass(self: *DocDatabase, allocator: Allocator, scanner: *Scanner, kind: EntryKind) !void {
    var entry: Entry = .{
        .name = undefined,
        .key = undefined,
        .kind = kind,
    };

    var methods: []Entry = &.{};
    var properties: []Entry = &.{};
    var signals: []Entry = &.{};
    var constants: []Entry = &.{};
    var enums: []Entry = &.{};

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                const class_key = std.meta.stringToEnum(ClassKey, s) orelse {
                    try scanner.skipValue();
                    continue;
                };

                switch (class_key) {
                    .name => {
                        const name = try scanner.next();
                        std.debug.assert(name == .string);

                        entry.name = try allocator.dupe(u8, name.string);
                        entry.key = entry.name;
                    },
                    .methods => methods = try self.parseClassMethods(allocator, scanner),
                    .properties => properties = try self.parseClassProperties(allocator, scanner),
                    .signals => signals = try self.parseEntryArray(.signal, allocator, scanner),
                    .constants => constants = try self.parseEntryArray(.constant, allocator, scanner),
                    .enums => enums = try self.parseEntryArray(.enum_value, allocator, scanner),
                    .brief_description => entry.brief_description = try nextTokenToMarkdownAlloc(allocator, scanner),
                    .description => entry.description = try nextTokenToMarkdownAlloc(allocator, scanner),
                }
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    try self.symbols.put(allocator, entry.key, entry);
    const entry_idx = self.symbols.getIndex(entry.name).?;

    const member_count = methods.len + properties.len + signals.len + constants.len + enums.len;

    var member_indices: ArrayList(usize) = .empty;
    defer member_indices.deinit(allocator);
    try member_indices.ensureTotalCapacity(allocator, member_count);

    try self.appendEntries(allocator, entry, entry_idx, methods, &member_indices);
    try self.appendEntries(allocator, entry, entry_idx, properties, &member_indices);
    try self.appendEntries(allocator, entry, entry_idx, signals, &member_indices);
    try self.appendEntries(allocator, entry, entry_idx, constants, &member_indices);
    try self.appendEntries(allocator, entry, entry_idx, enums, &member_indices);

    if (member_indices.items.len > 0) {
        var entry_ptr = self.symbols.getPtr(entry.key).?;
        entry_ptr.members = try member_indices.toOwnedSlice(allocator);
    }
}

fn appendEntries(self: *DocDatabase, allocator: Allocator, parent: Entry, parent_idx: usize, entries: []Entry, indices: *ArrayList(usize)) !void {
    for (entries) |*property_entry| {
        property_entry.parent_index = parent_idx;
        property_entry.key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent.name, property_entry.name });

        // store property entry in the database
        try self.symbols.put(allocator, property_entry.key, property_entry.*);

        // update property index on the parent entry
        const property_index = self.symbols.getIndex(property_entry.key).?;
        indices.appendAssumeCapacity(property_index);
    }
}

fn parseClassMethods(self: *const DocDatabase, allocator: Allocator, scanner: *Scanner) ![]Entry {
    var methods: ArrayList(Entry) = .empty;
    defer methods.deinit(allocator);

    const methods_token = try scanner.next();
    std.debug.assert(methods_token == .array_begin);

    while (true) {
        const method_token = try scanner.next();
        switch (method_token) {
            .object_begin => {
                try methods.append(allocator, try self.parseMethod(.method, allocator, scanner));
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return methods.toOwnedSlice(allocator);
}

fn parseClassProperties(self: *const DocDatabase, allocator: Allocator, scanner: *Scanner) ![]Entry {
    var properties: ArrayList(Entry) = .empty;
    defer properties.deinit(allocator);

    const properties_token = try scanner.next();
    std.debug.assert(properties_token == .array_begin);

    while (true) {
        const property_token = try scanner.next();
        switch (property_token) {
            .object_begin => {
                try properties.append(allocator, try self.parseProperty(allocator, scanner));
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return properties.toOwnedSlice(allocator);
}

const PropertyKey = enum {
    name,
    type,
    getter,
    setter,
};

fn parseProperty(self: *const DocDatabase, allocator: Allocator, scanner: *Scanner) !Entry {
    _ = self; // autofix

    var property: Entry = .{
        .name = undefined,
        .key = undefined,
        .kind = .property,
    };

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                const property_key = std.meta.stringToEnum(PropertyKey, s) orelse {
                    try scanner.skipValue();
                    continue;
                };

                switch (property_key) {
                    .name => {
                        const name = try scanner.next();
                        std.debug.assert(name == .string);

                        property.name = try allocator.dupe(u8, name.string);
                        property.key = property.name;
                    },
                    .type => {
                        const @"type" = try scanner.next();
                        std.debug.assert(@"type" == .string);

                        property.signature = try std.fmt.allocPrint(allocator, ": {s}", .{@"type".string});
                    },
                    else => try scanner.skipValue(),
                }
            },
            .object_end => break,
            else => {},
        }
    }

    return property;
}

const ConstantKey = enum {
    name,
};

const SignalKey = enum {
    name,
};

const EnumKey = enum {
    name,
};

const kind_key_map: std.StaticStringMap(type) = .initComptime(.{
    .{ @tagName(EntryKind.constant), ConstantKey },
    .{ @tagName(EntryKind.signal), SignalKey },
    .{ @tagName(EntryKind.enum_value), EnumKey },
});

const kind_handler_map: std.StaticStringMap(std.StaticStringMap(*const fn (Allocator, *Entry, *Scanner) anyerror!void)) = .initComptime(.{
    .{ @tagName(EntryKind.constant), constant_handler_map },
    .{ @tagName(EntryKind.signal), signal_handler_map },
    .{ @tagName(EntryKind.enum_value), enum_value_handler_map },
});

const constant_handler_map: std.StaticStringMap(*const fn (Allocator, *Entry, *Scanner) anyerror!void) = .initComptime(.{
    .{ @tagName(ConstantKey.name), handleNameKey },
});

const signal_handler_map: std.StaticStringMap(*const fn (Allocator, *Entry, *Scanner) anyerror!void) = .initComptime(.{
    .{ @tagName(SignalKey.name), handleNameKey },
});

const enum_value_handler_map: std.StaticStringMap(*const fn (Allocator, *Entry, *Scanner) anyerror!void) = .initComptime(.{
    .{ @tagName(EnumKey.name), handleNameKey },
});

fn handleNameKey(allocator: Allocator, entry: *Entry, scanner: *Scanner) anyerror!void {
    const name = try scanner.next();
    std.debug.assert(name == .string);

    entry.name = try allocator.dupe(u8, name.string);
    entry.key = entry.name;
}

fn parseEntry(self: *const DocDatabase, comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner) !Entry {
    _ = self; // autofix

    var entry: Entry = .{
        .name = undefined,
        .key = undefined,
        .kind = kind,
    };

    const KeyType = kind_key_map.get(@tagName(kind)) orelse comptime unreachable;
    const handlers = kind_handler_map.get(@tagName(kind)) orelse std.debug.panic("No handlers found for kind: {}", .{kind});

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                const key = std.meta.stringToEnum(KeyType, s) orelse {
                    try scanner.skipValue();
                    continue;
                };

                const handler = handlers.get(@tagName(key)) orelse std.debug.panic("No handler found for key ({}): {}", .{ kind, key });
                try handler(allocator, &entry, scanner);
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return entry;
}

fn parseEntryArray(self: *const DocDatabase, comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner) ![]Entry {
    var entries: ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    const constants_token = try scanner.next();
    std.debug.assert(constants_token == .array_begin);

    while (true) {
        const constant_token = try scanner.next();
        switch (constant_token) {
            .object_begin => {
                try entries.append(allocator, try self.parseEntry(kind, allocator, scanner));
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return entries.toOwnedSlice(allocator);
}

fn nextTokenToMarkdownAlloc(allocator: Allocator, scanner: *Scanner) ![]const u8 {
    const token = try scanner.nextAlloc(allocator, .alloc_if_needed);

    const value = switch (token) {
        inline .string, .allocated_string => |str| str,
        else => unreachable,
    };

    return try bbcodeToMarkdown(allocator, value);
}

const MethodKey = enum {
    name,
};

fn parseMethod(self: *const DocDatabase, comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner) !Entry {
    _ = self; // autofix

    switch (kind) {
        .method, .global_function => {},
        else => comptime unreachable,
    }

    var method: Entry = .{
        .name = undefined,
        .key = undefined,
        .kind = kind,
    };

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                const method_key = std.meta.stringToEnum(MethodKey, s) orelse {
                    try scanner.skipValue();
                    continue;
                };

                switch (method_key) {
                    .name => {
                        const name = try scanner.next();
                        std.debug.assert(name == .string);

                        method.name = try allocator.dupe(u8, name.string);
                        method.key = method.name;
                    },
                }
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return method;
}

pub fn lookupSymbolExact(self: DocDatabase, symbol: []const u8) DocDatabase.Error!Entry {
    return self.symbols.get(symbol) orelse return DocDatabase.Error.SymbolNotFound;
}

fn generateMarkdownForEntry(self: DocDatabase, allocator: Allocator, entry: Entry, writer: *Writer) !void {
    try writer.print("# {s}", .{entry.key});

    if (entry.signature) |sig| {
        try writer.writeAll(sig);
    }

    try writer.writeByte('\n');

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

    if (entry.members) |member_indices| {
        try self.generateMemberListings(allocator, member_indices, writer);
    }
}

fn generateMemberListings(self: DocDatabase, allocator: Allocator, member_indices: []usize, writer: *Writer) !void {
    var properties: ArrayList(usize) = .empty;
    var methods: ArrayList(usize) = .empty;
    var signals: ArrayList(usize) = .empty;
    var constants: ArrayList(usize) = .empty;
    var enums: ArrayList(usize) = .empty;

    defer properties.deinit(allocator);
    defer methods.deinit(allocator);
    defer signals.deinit(allocator);
    defer constants.deinit(allocator);
    defer enums.deinit(allocator);

    for (member_indices) |idx| {
        const member: Entry = self.symbols.values()[idx];
        switch (member.kind) {
            .property => try properties.append(allocator, idx),
            .method => try methods.append(allocator, idx),
            .signal => try signals.append(allocator, idx),
            .constant => try constants.append(allocator, idx),
            .enum_value => try enums.append(allocator, idx),
            else => continue,
        }
    }

    try self.formatMemberSection("Properties", properties.items, writer);
    try self.formatMemberSection("Methods", methods.items, writer);
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

    try writer.writeAll("**");

    if (member.brief_description) |brief| {
        try writer.print(" - {s}", .{brief});
    }

    try writer.writeByte('\n');
}

pub fn generateMarkdownForSymbol(self: DocDatabase, allocator: Allocator, symbol: []const u8, writer: *Writer) !void {
    try self.generateMarkdownForEntry(allocator, self.symbols.get(symbol) orelse return error.SymbolNotFound, writer);
}

test "parse simple builtin class from JSON" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // Minimal JSON with one builtin class
    const json_source =
        \\{
        \\  "builtin_classes": [
        \\    {
        \\      "name": "bool"
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);

    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class was parsed
    const entry = db.symbols.get("bool");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("bool", entry.?.name);
    try std.testing.expectEqual(EntryKind.builtin_class, entry.?.kind);
}

test "parse regular class from JSON" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node2D"
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    const entry = db.symbols.get("Node2D");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("Node2D", entry.?.name);
    try std.testing.expectEqual(EntryKind.class, entry.?.kind);
}

test "parse method with parent" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node2D",
        \\      "methods": [
        \\        {
        \\          "name": "get_global_position"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class exists
    const class_entry = db.symbols.get("Node2D");
    try std.testing.expect(class_entry != null);

    // Verify the method exists with correct full_path
    const method_entry = db.symbols.get("Node2D.get_global_position");
    try std.testing.expect(method_entry != null);
    try std.testing.expectEqualStrings("get_global_position", method_entry.?.name);
    try std.testing.expectEqualStrings("Node2D.get_global_position", method_entry.?.key);
    try std.testing.expectEqual(EntryKind.method, method_entry.?.kind);

    // Verify parent points to the class
    try std.testing.expect(method_entry.?.parent_index != null);

    const parent = db.symbols.values()[method_entry.?.parent_index.?];
    try std.testing.expectEqualStrings("Node2D", parent.name);
}

test "parse utility functions as global functions" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "utility_functions": [
        \\    {
        \\      "name": "sin"
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    const entry = db.symbols.get("sin");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("sin", entry.?.name);
    try std.testing.expectEqualStrings("sin", entry.?.key);
    try std.testing.expectEqual(EntryKind.global_function, entry.?.kind);
    try std.testing.expect(entry.?.parent_index == null); // No parent
}

test "class stores member indices not strings" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Vector2",
        \\      "methods": [
        \\        {
        \\          "name": "normalized"
        \\        },
        \\        {
        \\          "name": "length"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class has members array
    const class_entry = db.symbols.get("Vector2");
    try std.testing.expect(class_entry != null);
    try std.testing.expect(class_entry.?.members != null);

    // Should have 2 members
    const members = class_entry.?.members.?;
    try std.testing.expectEqual(@as(usize, 2), members.len);

    // Members should be indices into the symbols array
    const first_member = db.symbols.values()[members[0]];
    const second_member = db.symbols.values()[members[1]];

    // Verify members are the methods
    try std.testing.expectEqualStrings("normalized", first_member.name);
    try std.testing.expectEqual(EntryKind.method, first_member.kind);

    try std.testing.expectEqualStrings("length", second_member.name);
    try std.testing.expectEqual(EntryKind.method, second_member.kind);
}

test "convert BBCode description to Markdown" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node2D",
        \\      "brief_description": "A 2D game object with [b]position[/b] and [i]rotation[/i]."
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    const entry = db.symbols.get("Node2D");
    try std.testing.expect(entry != null);
    try std.testing.expect(entry.?.brief_description != null);

    // BBCode should be converted to Markdown
    // [b]text[/b] -> **text**
    // [i]text[/i] -> *text*
    const expected = "A 2D game object with **position** and *rotation*.";
    try std.testing.expectEqualStrings(expected, entry.?.brief_description.?);
}

test "skip unknown root-level keys like header" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // JSON with all unknown root-level keys that should be skipped
    const json_source =
        \\{
        \\  "header": {
        \\    "version_major": 4,
        \\    "version_minor": 5
        \\  },
        \\  "builtin_class_sizes": [
        \\    {
        \\      "build_configuration": "float_32",
        \\      "sizes": [
        \\        {
        \\          "name": "bool",
        \\          "size": 1
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "builtin_class_member_offsets": [],
        \\  "global_constants": [],
        \\  "global_enums": [],
        \\  "native_structures": [],
        \\  "singletons": [],
        \\  "classes": [
        \\    {
        \\      "name": "Node2D"
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Should successfully parse despite unknown keys
    const entry = db.symbols.get("Node2D");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("Node2D", entry.?.name);
}

test "skip unknown method fields like return_type" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // JSON with method containing fields beyond just "name"
    const json_source =
        \\{
        \\  "utility_functions": [
        \\    {
        \\      "name": "sin",
        \\      "return_type": "float",
        \\      "category": "math",
        \\      "is_vararg": false,
        \\      "hash": 12345,
        \\      "arguments": []
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Should successfully parse method despite unknown fields
    const entry = db.symbols.get("sin");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("sin", entry.?.name);
    try std.testing.expectEqual(EntryKind.global_function, entry.?.kind);
}

test "skip unknown class fields like api_type" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // JSON with class containing fields beyond name/methods/brief_description
    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node2D",
        \\      "api_type": "core",
        \\      "inherits": "CanvasItem",
        \\      "is_instantiable": true,
        \\      "is_refcounted": false,
        \\      "description": "A 2D game object.",
        \\      "enums": []
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Should successfully parse class despite unknown fields
    const entry = db.symbols.get("Node2D");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("Node2D", entry.?.name);
    try std.testing.expectEqual(EntryKind.class, entry.?.kind);
}

// RED PHASE: Test parsing properties from class
test "parse class with properties array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node2D",
        \\      "properties": [
        \\        {
        \\          "name": "position",
        \\          "type": "Vector2",
        \\          "setter": "set_position",
        \\          "getter": "get_position"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class has members with the property
    const class_entry = db.symbols.get("Node2D");
    try std.testing.expect(class_entry != null);
    try std.testing.expect(class_entry.?.members != null);
    try std.testing.expectEqual(@as(usize, 1), class_entry.?.members.?.len);

    // Verify the property entry exists
    const property_entry = db.symbols.get("Node2D.position");
    try std.testing.expect(property_entry != null);
    try std.testing.expectEqualStrings("position", property_entry.?.name);
    try std.testing.expectEqualStrings("Node2D.position", property_entry.?.key);
    try std.testing.expectEqual(EntryKind.property, property_entry.?.kind);

    // Verify property is in the class members
    const member = db.symbols.values()[class_entry.?.members.?[0]];
    try std.testing.expectEqualStrings("position", member.name);
    try std.testing.expectEqual(EntryKind.property, member.kind);
}

// RED PHASE: Test parsing signals from class
test "parse class with signals array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Area2D",
        \\      "signals": [
        \\        {
        \\          "name": "body_entered",
        \\          "description": "Emitted when a body enters."
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class has members with the signal
    const class_entry = db.symbols.get("Area2D");
    try std.testing.expect(class_entry != null);
    try std.testing.expect(class_entry.?.members != null);
    try std.testing.expectEqual(@as(usize, 1), class_entry.?.members.?.len);

    // Verify the signal entry exists
    const signal_entry = db.symbols.get("Area2D.body_entered");
    try std.testing.expect(signal_entry != null);
    try std.testing.expectEqualStrings("body_entered", signal_entry.?.name);
    try std.testing.expectEqualStrings("Area2D.body_entered", signal_entry.?.key);
    try std.testing.expectEqual(EntryKind.signal, signal_entry.?.kind);

    // Verify signal is in the class members
    const member = db.symbols.values()[class_entry.?.members.?[0]];
    try std.testing.expectEqualStrings("body_entered", member.name);
    try std.testing.expectEqual(EntryKind.signal, member.kind);
}

// RED PHASE: Test parsing constants from class
test "parse class with constants array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "Node",
        \\      "constants": [
        \\        {
        \\          "name": "NOTIFICATION_READY",
        \\          "value": 30
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class has members with the constant
    const class_entry = db.symbols.get("Node");
    try std.testing.expect(class_entry != null);
    try std.testing.expect(class_entry.?.members != null);
    try std.testing.expectEqual(@as(usize, 1), class_entry.?.members.?.len);

    // Verify the constant entry exists
    const constant_entry = db.symbols.get("Node.NOTIFICATION_READY");
    try std.testing.expect(constant_entry != null);
    try std.testing.expectEqualStrings("NOTIFICATION_READY", constant_entry.?.name);
    try std.testing.expectEqualStrings("Node.NOTIFICATION_READY", constant_entry.?.key);
    try std.testing.expectEqual(EntryKind.constant, constant_entry.?.kind);

    // Verify constant is in the class members
    const member = db.symbols.values()[class_entry.?.members.?[0]];
    try std.testing.expectEqualStrings("NOTIFICATION_READY", member.name);
    try std.testing.expectEqual(EntryKind.constant, member.kind);
}

// RED PHASE: Test parsing enums from class
test "parse class with enums array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const json_source =
        \\{
        \\  "classes": [
        \\    {
        \\      "name": "AESContext",
        \\      "enums": [
        \\        {
        \\          "name": "Mode",
        \\          "is_bitfield": false,
        \\          "values": [
        \\            {
        \\              "name": "MODE_ECB_ENCRYPT",
        \\              "value": 0
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var json_scanner = Scanner.initCompleteInput(allocator, json_source);
    const db = try DocDatabase.loadFromJsonLeaky(allocator, &json_scanner);

    // Verify the class has members with the enum
    const class_entry = db.symbols.get("AESContext");
    try std.testing.expect(class_entry != null);
    try std.testing.expect(class_entry.?.members != null);
    try std.testing.expectEqual(@as(usize, 1), class_entry.?.members.?.len);

    // Verify the enum value entry exists
    const enum_entry = db.symbols.get("AESContext.Mode");
    try std.testing.expect(enum_entry != null);
    try std.testing.expectEqualStrings("Mode", enum_entry.?.name);
    try std.testing.expectEqualStrings("AESContext.Mode", enum_entry.?.key);
    try std.testing.expectEqual(EntryKind.enum_value, enum_entry.?.kind);

    // Verify enum value is in the class members
    const member = db.symbols.values()[class_entry.?.members.?[0]];
    try std.testing.expectEqualStrings("Mode", member.name);
    try std.testing.expectEqual(EntryKind.enum_value, member.kind);
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

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Reader = std.json.Reader;
const Token = std.json.Token;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const ArrayList = std.ArrayListUnmanaged;
const File = std.fs.File;
const Writer = std.Io.Writer;

const bbcodez = @import("bbcodez");
