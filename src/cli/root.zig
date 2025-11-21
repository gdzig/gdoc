pub fn build(allocator: Allocator, writer: *Writer, reader: *Reader) !*Command {
    const root = try Command.init(
        writer,
        reader,
        allocator,
        .{
            .name = "gdoc",
            .description = "Godot documentation CLI",
            .version = .{ .major = 0, .minor = 1, .patch = 0 },
        },
        runLookup,
    );

    try root.addFlag(.{
        .name = "clear-cache",
        .description = "Clears the cache",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root.addFlag(.{
        .name = "godot-extension-api",
        .description = "Path to Godot extension_api.json file (bypasses cache)",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    try root.addPositionalArg(.{
        .name = "symbol",
        .description = "Symbol to look up. (E.g. Node2D, Node2D.position)",
        .required = false,
    });

    return root;
}

fn runLookup(ctx: CommandContext) !void {
    const clear_cache = ctx.flag("clear-cache", bool);
    const api_json_path_raw = ctx.flag("godot-extension-api", []const u8);
    const api_json_path: ?[]const u8 = if (api_json_path_raw.len == 0) null else api_json_path_raw;

    // print help when no arguments/flags are provided
    if (!clear_cache and ctx.positional_args.len == 0 and api_json_path == null) {
        try ctx.command.printHelp();
        return;
    }

    if (clear_cache) {
        try gdoc.cache.clearCache(ctx.allocator);
        try ctx.writer.writeAll("Cache cleared.\n");
    }

    const symbol = ctx.getArg("symbol") orelse return;

    gdoc.lookupAndDisplay(ctx.allocator, symbol, api_json_path, ctx.writer) catch |err| switch (err) {
        DocDatabaseError.SymbolNotFound => try ctx.writer.print("Symbol '{s}' not found.\n", .{symbol}),
        error.ApiFileNotFound => try ctx.writer.print("Error: API file not found: {s}\n", .{api_json_path.?}),
        error.InvalidApiJson => try ctx.writer.print("Error: Invalid JSON in API file: {s}\n", .{api_json_path.?}),
        else => return err,
    };

    try ctx.writer.flush();
}

const gdoc = @import("gdoc");
const DocDatabaseError = gdoc.DocDatabase.Error;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

const zli = @import("zli");
const Command = zli.Command;
const CommandContext = zli.CommandContext;
