const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match the specified filters.",
    ) orelse &.{};

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

    const test_step = b.step("test", "Run unit tests");

    const external_tests_exe = b.addTest(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    external_tests_exe.root_module.addImport("zcs", zcs);
    const external_tests = b.addRunArtifact(external_tests_exe);
    test_step.dependOn(&external_tests.step);

    const zcs_tests_exe = b.addTest(.{ .root_module = zcs, .filters = test_filters });
    const zcs_tests = b.addRunArtifact(zcs_tests_exe);
    test_step.dependOn(&zcs_tests.step);

    const docs = zcs_tests_exe.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the docs");
    docs_step.dependOn(&install_docs.step);
}
