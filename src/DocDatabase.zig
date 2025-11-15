const DocDatabase = @This();

const empty = DocDatabase{};

symbols: StringArrayHashMap(Entry) = .empty,

pub const EntryKind = enum {
    builtin_class,
    class,
    method,
    property,
    constant,
    enum_value,
    global_function,
    operator,
};

pub const Entry = struct {
    name: []const u8,
    full_path: []const u8,
    parent_index: ?usize = null,
    kind: EntryKind,
    description: ?[]const u8 = null,
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

pub fn loadFromJsonLeaky(gpa: Allocator, scanner: *Scanner) !DocDatabase {
    var db = empty;

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);
                switch (std.meta.stringToEnum(RootState, s) orelse continue) {
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
                try db.symbols.put(allocator, method.name, method);
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
};

fn parseClass(allocator: Allocator, scanner: *Scanner, kind: EntryKind, db: *DocDatabase) !void {
    var entry: Entry = .{
        .name = undefined,
        .full_path = undefined,
        .kind = kind,
    };

    var method_entries: ArrayList(Entry) = .empty;

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);

                switch (std.meta.stringToEnum(ClassKey, s) orelse std.debug.panic("Unexpected class key: {s}", .{s})) {
                    .name => {
                        const name = try scanner.next();
                        std.debug.assert(name == .string);

                        entry.name = try allocator.dupe(u8, name.string);
                        entry.full_path = entry.name;
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
                }
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    try db.symbols.put(allocator, entry.name, entry);
    const parent_index = db.symbols.getIndex(entry.name).?;
    var entry_ptr = db.symbols.getPtr(entry.name).?;

    var member_indices = try allocator.alloc(usize, method_entries.items.len);
    entry_ptr.members = member_indices;

    for (method_entries.items, 0..) |*method_entry, i| {
        method_entry.parent_index = parent_index;
        method_entry.full_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ entry.name, method_entry.name });

        // store method entry in the database
        try db.symbols.put(allocator, method_entry.full_path, method_entry.*);

        // update method index on the parent entry
        const method_index = db.symbols.getIndex(method_entry.full_path).?;
        member_indices[i] = method_index;
    }
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
        .full_path = undefined,
        .kind = kind,
    };

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                std.debug.assert(scanner.string_is_object_key);

                switch (std.meta.stringToEnum(MethodKey, s) orelse std.debug.panic("Unexpected method key: {s}", .{s})) {
                    .name => {
                        const name = try scanner.next();
                        std.debug.assert(name == .string);

                        method.name = try allocator.dupe(u8, name.string);
                        method.full_path = method.name;
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
    try std.testing.expectEqualStrings("Node2D.get_global_position", method_entry.?.full_path);
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
    try std.testing.expectEqualStrings("sin", entry.?.full_path);
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
    try std.testing.expect(entry.?.description != null);

    // BBCode should be converted to Markdown
    // [b]text[/b] -> **text**
    // [i]text[/i] -> *text*
    const expected = "A 2D game object with **position** and *rotation*.";
    try std.testing.expectEqualStrings(expected, entry.?.description.?);
}

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Token = std.json.Token;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const ArrayList = std.ArrayListUnmanaged;
