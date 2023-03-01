const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.addModule(.{
        .name = "bincode-zig",
        .source_file = .{ .path = "bincode.zig" },
    });

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "bincode.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
