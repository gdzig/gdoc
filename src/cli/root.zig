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
        .name = "output-format",
        .description = "Output format (markdown or terminal). Defaults to terminal for TTY, markdown otherwise.",
        .type = .String,
        .default_value = .{ .String = "detect" },
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

    const output_format_raw = ctx.flag("output-format", []const u8);
    const output_format: OutputFormat = std.meta.stringToEnum(OutputFormat, output_format_raw) orelse .detect;

    // print help when no arguments/flags are provided
    if (!clear_cache and ctx.positional_args.len == 0) {
        try ctx.command.printHelp();
        return;
    }

    const config: *const gdoc.Config = ctx.getContextData(gdoc.Config);

    if (clear_cache) {
        try gdoc.cache.clearCache(config);
        try ctx.writer.writeAll("Cache cleared.\n");
    }

    const symbol = ctx.getArg("symbol") orelse return;

    gdoc.formatAndDisplay(ctx.allocator, symbol, ctx.writer, output_format, config) catch |err| switch (err) {
        DocDatabaseError.SymbolNotFound => try ctx.writer.print("Symbol '{s}' not found.\n", .{symbol}),
        else => return err,
    };

    try ctx.writer.flush();
}

const gdoc = @import("gdoc");
const DocDatabaseError = gdoc.DocDatabase.Error;
const OutputFormat = gdoc.OutputFormat;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

const zli = @import("zli");
const Command = zli.Command;
const CommandContext = zli.CommandContext;
