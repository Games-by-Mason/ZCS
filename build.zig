const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_llvm = b.option(
        bool,
        "no-llvm",
        "Don't use the LLVM backend.",
    ) orelse false;

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match the specified filters.",
    ) orelse &.{};

    const slot_map = b.dependency("slot_map", .{
        .target = target,
        .optimize = optimize,
    });

    const geom = b.dependency("geom", .{
        .target = target,
        .optimize = optimize,
    });

    const tracy = b.dependency("tracy", .{ .optimize = optimize, .target = target });

    const zcs = b.addModule("zcs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcs.addImport("slot_map", slot_map.module("slot_map"));
    zcs.addImport("geom", geom.module("geom"));
    zcs.addImport("tracy", tracy.module("tracy"));

    const test_step = b.step("test", "Run unit tests");

    const external_tests_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .optimize = optimize,
            .target = target,
        }),
        .filters = test_filters,
        .use_llvm = !no_llvm,
    });
    external_tests_exe.root_module.addImport("zcs", zcs);
    const external_tests = b.addRunArtifact(external_tests_exe);
    test_step.dependOn(&external_tests.step);

    const zcs_tests_exe = b.addTest(.{
        .root_module = zcs,
        .filters = test_filters,
        .use_llvm = !no_llvm,
    });
    const zcs_tests = b.addRunArtifact(zcs_tests_exe);
    test_step.dependOn(&zcs_tests.step);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = !no_llvm,
    });
    bench_exe.root_module.addImport("zcs", zcs);
    bench_exe.root_module.addImport("tracy", tracy.module("tracy"));
    bench_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);
    test_step.dependOn(&bench_exe.step);

    // We need an executable to generate docs, but we don't want to use a test executable because
    // "test" ends up in our URLs if we do.
    const docs_exe = b.addExecutable(.{
        .name = "zcs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = !no_llvm,
    });
    const docs = docs_exe.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the docs");
    docs_step.dependOn(&install_docs.step);

    const check_step = b.step("check", "Check the build");
    check_step.dependOn(&external_tests_exe.step);
    check_step.dependOn(&zcs_tests_exe.step);
    check_step.dependOn(&bench_exe.step);
}
