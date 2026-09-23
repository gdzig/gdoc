pub const std_options = std.Options{
    .log_level = .err,
};

pub fn main(init: std.process.Init) !void {
    var dbg = DebugAllocator(.{}).init;

    const allocator = switch (@import("builtin").mode) {
        .Debug => dbg.allocator(),
        .ReleaseFast, .ReleaseSafe, .ReleaseSmall => std.heap.smp_allocator,
    };

    defer if (@import("builtin").mode == .Debug) {
        std.debug.assert(dbg.deinit() == .ok);
    };

    var config = try gdoc.Config.init(allocator, init.io, init.minimal.environ);
    defer config.deinit(allocator);

    var stdout_writer = File.stdout().writerStreaming(init.io, &.{});
    const stdout = &stdout_writer.interface;

    var buf: [4096]u8 = undefined;
    var stdin_reader = File.stdin().readerStreaming(init.io, &buf);
    const stdin = &stdin_reader.interface;

    const root = try cli.build(allocator, init.io, stdout, stdin);
    defer root.deinit();

    var args_iter = init.minimal.args.iterate();
    try root.execute(&args_iter, .{ .data = @ptrCast(&config) });
    try stdout.flush();
}

const std = @import("std");
const DebugAllocator = std.heap.DebugAllocator;
const File = std.Io.File;

const cli = @import("cli/root.zig");
const gdoc = @import("gdoc");
