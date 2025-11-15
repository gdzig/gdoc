pub fn generateApiJson(allocator: Allocator, godot_path: []const u8, destination_dir: []const u8) !void {
    const result = try Child.run(.{
        .cwd = destination_dir,
        .argv = &[_][]const u8{ godot_path, "--dump-extension-api-with-docs" },
        .allocator = allocator,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                return error.GodotExecutionFailed;
            }
        },
        else => return error.GodotExecutionFailed,
    }
}

// Tests for generateApiJson function

test "generateApiJson executes godot and creates extension_api.json in cache" {
    const allocator = std.testing.allocator;

    // Create a fake godot script that creates extension_api.json
    // We'll use a shell script to simulate godot's behavior
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const fake_godot = try std.fmt.allocPrint(allocator, "{s}/fake-godot.sh", .{tmp_path});
    defer allocator.free(fake_godot);

    // Create fake godot script that writes extension_api.json
    const script_content =
        \\#!/bin/sh
        \\echo '{"version": "test"}' > extension_api.json
    ;

    try tmp_dir.dir.writeFile(.{ .sub_path = "fake-godot.sh", .data = script_content });

    // Make it executable
    var file = try tmp_dir.dir.openFile("fake-godot.sh", .{});
    try file.chmod(0o755);
    file.close();

    // Generate the API JSON
    try generateApiJson(allocator, fake_godot, tmp_path);

    // Verify the JSON file was created in cache directory
    const json_path = try std.fmt.allocPrint(allocator, "{s}/extension_api.json", .{tmp_path});
    defer allocator.free(json_path);

    const json_data = try std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 1024);
    defer allocator.free(json_data);

    // Should contain the test JSON
    try std.testing.expect(std.mem.indexOf(u8, json_data, "test") != null);
}

test "generateApiJson returns error when godot executable not found" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const non_existant_godot = try std.fmt.allocPrint(allocator, "{s}/godot", .{tmp_path});
    defer allocator.free(non_existant_godot);

    const result = generateApiJson(allocator, non_existant_godot, "");

    try std.testing.expectError(error.FileNotFound, result);
}

test "generateApiJson returns error on non-zero exit code" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Use 'false' command which always exits with code 1
    const result = generateApiJson(allocator, "false", tmp_path);

    try std.testing.expectError(error.GodotExecutionFailed, result);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

const cache = @import("cache.zig");
