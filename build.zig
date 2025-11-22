const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();

    const bbcodez = b.dependency("bbcodez", .{
        .target = target,
        .optimize = optimize,
    }).module("bbcodez");

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    const zli = b.dependency("zli", .{
        .target = target,
        .optimize = optimize,
    }).module("zli");

    const zigdown = b.dependency("zigdown", .{
        .target = target,
        .optimize = optimize,
    }).module("zigdown");

    const mod = b.addModule("gdoc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "bbcodez", .module = bbcodez },
            .{ .name = "known-folders", .module = known_folders },
            .{ .name = "zigdown", .module = zigdown },
        },
    });
    mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "gdoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gdoc", .module = mod },
                .{ .name = "zli", .module = zli },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Snapshot testing: verify snapshots haven't changed unexpectedly
    // Works with both git and jujutsu (jj with git backend)
    const diff_check = b.addSystemCommand(&.{
        "git",
        "diff",
        "--exit-code", // Fail if differences exist
    });
    diff_check.addDirectoryArg(b.path("snapshots/"));

    test_step.dependOn(&diff_check.step);
}
