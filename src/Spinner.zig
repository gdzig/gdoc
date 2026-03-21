const std = @import("std");

const Spinner = @This();

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const delay_ns = 80 * std.time.ns_per_ms;

message: []const u8,
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub fn start(self: *Spinner) void {
    self.stop.store(false, .release);
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch return;
}

pub fn finish(self: *Spinner) void {
    self.stop.store(true, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(&buf);
    w.interface.writeAll("\r\x1b[2K") catch {};
    w.interface.flush() catch {};
}

fn run(self: *Spinner) void {
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(&buf);
    var i: usize = 0;
    while (!self.stop.load(.acquire)) {
        w.interface.print("\r{s} {s}", .{ frames[i], self.message }) catch return;
        w.interface.flush() catch return;
        i = (i + 1) % frames.len;
        std.Thread.sleep(delay_ns);
    }
}
