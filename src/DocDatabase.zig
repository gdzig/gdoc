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
                    .builtin_classes => try parseBuiltinClasses(gpa, scanner, &db),
                    else => continue,
                }
            },
            .end_of_document => break,
            else => {},
        }
    }

    return db;
}

fn parseBuiltinClasses(allocator: Allocator, scanner: *Scanner, db: *DocDatabase) !void {
    std.debug.assert(try scanner.next() == .array_begin);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                const entry = try parseClass(allocator, scanner);
                try db.symbols.put(allocator, entry.name, entry);
            },
            .array_end => break,
            .end_of_document => unreachable,
            else => {
                std.debug.print("  Token: {}\n", .{token});
            },
        }
    }
}

fn parseClass(allocator: Allocator, scanner: *Scanner) !Entry {
    var entry: Entry = .{
        .name = undefined,
        .full_path = undefined,
        .kind = .builtin_class,
    };

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                const is_key = scanner.string_is_object_key;
                if (is_key and std.mem.eql(u8, s, "name")) {
                    const name = try scanner.next();

                    std.debug.assert(name == .string);
                    entry.name = try allocator.dupe(u8, name.string);
                    entry.full_path = entry.name;
                }
            },
            .object_end => break,
            .end_of_document => unreachable,
            else => {},
        }
    }

    return entry;
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

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Token = std.json.Token;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
