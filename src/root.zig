pub const LookupError = Writer.Error || DocDatabase.Error;

pub fn lookupAndDisplay(symbol: []const u8, writer: *Writer) LookupError!void {
    try writer.print("Lookup not yet implemented for symbol: {s}\n", .{symbol});
}

comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const known_folders = @import("known-folders");

pub const DocDatabase = @import("DocDatabase.zig");
pub const cache = @import("cache.zig");
pub const api = @import("api.zig");
