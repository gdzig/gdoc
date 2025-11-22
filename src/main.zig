pub const std_options = std.Options{
    .log_level = .err,
};

pub fn main() !void {
    var dbg = DebugAllocator(.{}).init;

    const allocator = switch (@import("builtin").mode) {
        .Debug => dbg.allocator(),
        .ReleaseFast, .ReleaseSafe, .ReleaseSmall => std.heap.smp_allocator,
    };

    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(dbg.deinit() == .ok);
    };

    var stdout_writer = File.stdout().writerStreaming(&.{});
    const stdout = &stdout_writer.interface;

    var buf: [4096]u8 = undefined;
    var stdin_reader = File.stdin().readerStreaming(&buf);
    const stdin = &stdin_reader.interface;

    const root = try cli.build(allocator, stdout, stdin);
    defer root.deinit();

    try root.execute(.{});
    try stdout.flush();
}

const std = @import("std");
const DebugAllocator = std.heap.DebugAllocator;
const File = std.fs.File;

const cli = @import("cli/root.zig");
