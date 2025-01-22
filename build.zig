const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const slot_map = b.dependency("slot_map", .{
        .target = target,
        .optimize = optimize,
    });

    const zcs = b.addModule("zcs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcs.addImport("slot_map", slot_map.module("slot_map"));

    const tests = b.addTest(.{ .root_module = zcs });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const docs = tests.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the docs");
    docs_step.dependOn(&install_docs.step);
}
