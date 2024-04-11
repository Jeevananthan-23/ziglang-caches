const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main modules for projects to use.
    const lru_module = b.addModule("lrucache", .{ .root_source_file = .{ .path = "src/lru/lru.zig" } });

    _ = b.addModule("s3fifocache", .{ .root_source_file = .{ .path = "src/s3fifo/s3fifo.zig" } });

    // Library
    const lib_step = b.step("lib", "Install library");

    const liblru = b.addStaticLibrary(.{
        .name = "lrucache",
        .root_source_file = .{ .path = "src/lru/lru.zig" },
        .target = target,
        .optimize = optimize,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    const libs3fifo = b.addStaticLibrary(.{
        .name = "s3fifocache",
        .root_source_file = .{ .path = "src/s3fifo/s3fifo.zig" },
        .target = target,
        .optimize = optimize,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    const liblru_install = b.addInstallArtifact(liblru, .{});
    const libs3fifo_instal = b.addInstallArtifact(libs3fifo, .{});

    lib_step.dependOn(&liblru_install.step);
    lib_step.dependOn(&libs3fifo_instal.step);
    b.default_step.dependOn(lib_step);

    // Docs
    const docs_step = b.step("docs", "Emit docs");

    const docs_install = b.addInstallDirectory(.{
        .source_dir = libs3fifo.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs_install.step);
    b.default_step.dependOn(docs_step);

    // Sample cache in Main
    const run_step = b.step("run", "Run the app");

    const exe = b.addExecutable(.{
        .name = "ziglang-caches",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("lru", lru_module);

    exe.root_module.addAnonymousImport("zbench", .{
        .root_source_file = .{ .path = "libs/zbench/zbench.zig" },
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const liblru_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lru/lru.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_liblru_unit_tests = b.addRunArtifact(liblru_unit_tests);

    const libs3fifo_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/s3fifo/s3fifo.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_libs3fifo_unit_tests = b.addRunArtifact(libs3fifo_unit_tests);

    const main_test = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_test);

    test_step.dependOn(&run_liblru_unit_tests.step);
    test_step.dependOn(&run_libs3fifo_unit_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // Lints
    const lints_step = b.step("lint", "Run lints");

    const lints = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    lints_step.dependOn(&lints.step);
    b.default_step.dependOn(lints_step);

    // benchmarking
    const bench_step = b.step("bench", "benchmark");

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        // TODO: make it work
        // .optimize = std.builtin.Mode.ReleaseSafe, // to get decent results - but things get optimized away
        .optimize = optimize,
    });

    b.installArtifact(bench_exe);
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    bench_step.dependOn(&bench_cmd.step);
    b.default_step.dependOn(bench_step);
}
