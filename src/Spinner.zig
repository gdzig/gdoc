const Spinner = @This();

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const delay_ns = 80 * std.time.ns_per_ms;

message: []const u8,
io: Io,
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub fn start(self: *Spinner) void {
    self.stop.store(false, .release);
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch return;
}

pub fn finish(self: *Spinner) void {
    if (self.thread == null) return;

    self.stop.store(true, .release);
    self.thread.?.join();
    self.thread = null;

    const stderr = File.stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(self.io, &buf);
    w.interface.writeAll("\r\x1b[2K") catch {};
    w.interface.flush() catch {};
}

fn run(self: *Spinner) void {
    const stderr = File.stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(self.io, &buf);
    var i: usize = 0;
    while (!self.stop.load(.acquire)) {
        w.interface.print("\r{s} {s}", .{ frames[i], self.message }) catch return;
        w.interface.flush() catch return;
        i = (i + 1) % frames.len;
        Io.sleep(self.io, .fromNanoseconds(delay_ns), .awake) catch {};
    }
}

const std = @import("std");
const Io = std.Io;
const File = Io.File;
