pub const DocDatabase = @import("DocDatabase.zig");
pub const cache = @import("cache.zig");
pub const api = @import("api.zig");

// Import tests from other modules
comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");
