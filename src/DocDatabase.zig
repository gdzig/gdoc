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

pub fn loadFromJsonFileLeaky(gpa: Allocator, file: File) !DocDatabase {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    const file_content = try reader.readAlloc(gpa, try file.getEndPos());
    defer gpa.free(file_content);

    var scanner = Scanner.initCompleteInput(gpa, file_content);
    defer scanner.deinit();

    return loadFromJsonLeaky(gpa, &scanner) catch |err| switch (err) {
        Scanner.Error.SyntaxError, Scanner.Error.UnexpectedEndOfInput => return Error.InvalidApiJson,
        else => return err,
    };
}

pub fn loadFromJsonLeaky(gpa: Allocator, scanner: *Scanner) !DocDatabase {
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
                    .builtin_classes => try parseClasses(.builtin_class, gpa, scanner, &db),
                    .classes => try parseClasses(.class, gpa, scanner, &db),
                    .utility_functions => try parseGlobalMethods(gpa, scanner, &db),
                    else => continue,
                }
            },
            .end_of_document => break,
            else => {},
        }
    }

    return db;
}

fn parseGlobalMethods(allocator: Allocator, scanner: *Scanner, db: *DocDatabase) !void {
    std.debug.assert(try scanner.next() == .array_begin);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                const method = try parseMethod(.global_function, allocator, scanner);
                try db.symbols.put(allocator, method.key, method);
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }
}

fn parseClasses(comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner, db: *DocDatabase) !void {
    std.debug.assert(try scanner.next() == .array_begin);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                try parseClass(allocator, scanner, kind, db);
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
    description,
    brief_description,
};

fn bbcodeToMarkdown(allocator: Allocator, input: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);

    const bbcode_doc = try bbcodez.loadFromBuffer(allocator, input, .{});
    defer bbcode_doc.deinit();

    try bbcodez.fmt.md.renderDocument(allocator, bbcode_doc, &output.writer, .{});

    return try output.toOwnedSlice();
}

fn parseClass(allocator: Allocator, scanner: *Scanner, kind: EntryKind, db: *DocDatabase) !void {
    var entry: Entry = .{
        .name = undefined,
        .key = undefined,
        .kind = kind,
    };

    var method_entries: ArrayList(Entry) = .empty;
    defer method_entries.deinit(allocator);

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
                    .methods => {
                        const methods = try scanner.next();
                        std.debug.assert(methods == .array_begin);

                        while (true) {
                            const method_token = try scanner.next();
                            switch (method_token) {
                                .object_begin => {
                                    try method_entries.append(allocator, try parseMethod(.method, allocator, scanner));
                                },
                                .array_end => break,
                                .end_of_document => unreachable,
                                else => {},
                            }
                        }
                    },
                    .brief_description => entry.brief_description = try nextTokenToMarkdownAlloc(allocator, scanner),
                    .description => entry.description = try nextTokenToMarkdownAlloc(allocator, scanner),
                }
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    try db.symbols.put(allocator, entry.key, entry);
    const parent_index = db.symbols.getIndex(entry.name).?;
    var entry_ptr = db.symbols.getPtr(entry.name).?;

    var member_indices = try allocator.alloc(usize, method_entries.items.len);
    entry_ptr.members = member_indices;

    for (method_entries.items, 0..) |*method_entry, i| {
        method_entry.parent_index = parent_index;
        method_entry.key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ entry.name, method_entry.name });

        // store method entry in the database
        try db.symbols.put(allocator, method_entry.key, method_entry.*);

        // update method index on the parent entry
        const method_index = db.symbols.getIndex(method_entry.key).?;
        member_indices[i] = method_index;
    }
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

fn parseMethod(comptime kind: EntryKind, allocator: Allocator, scanner: *Scanner) !Entry {
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
    try writer.print("# {s}\n", .{entry.key});

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
        .signature = "float sin(float angle)",
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
        .signature = "Vector2",
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
