const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "shared", "Build shared library (.so / .dll / .dylib) instead of static (.a / .lib)") orelse true;
    const strip_option = b.option(bool, "strip", "Strip debug symbols from built artifacts");
    const strip = strip_option orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall);

    const linkage = if (shared) std.builtin.LinkMode.dynamic else std.builtin.LinkMode.static;

    const proxy_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });

    if (target.result.os.tag == .windows) {
        proxy_module.linkSystemLibrary("ws2_32", .{});
    }

    const lib = b.addLibrary(.{
        .name = "proxy_transport",
        .linkage = linkage,
        .root_module = proxy_module,
    });

    lib.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(lib);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "proxy_transport", .module = proxy_module },
        },
    });

    if (target.result.os.tag == .windows) {
        test_module.linkSystemLibrary("ws2_32", .{});
    }

    var filters: std.ArrayList([]const u8) = .empty;
    if (b.option([]const u8, "test-filter", "Skip tests that do not match filter")) |f| {
        filters.append(b.allocator, f) catch @panic("OOM");
    }
    if (b.args) |args| {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--test-filter")) {
                if (i + 1 < args.len) {
                    filters.append(b.allocator, args[i + 1]) catch @panic("OOM");
                    i += 1;
                }
            } else if (std.mem.startsWith(u8, arg, "--test-filter=")) {
                const val = arg["--test-filter=".len..];
                filters.append(b.allocator, val) catch @panic("OOM");
            }
        }
    }

    const main_tests = b.addTest(.{
        .root_module = test_module,
        .filters = filters.toOwnedSlice(b.allocator) catch @panic("OOM"),
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_main_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "proxy_transport", .module = proxy_module },
        },
    });

    if (target.result.os.tag == .windows) {
        example_module.linkSystemLibrary("ws2_32", .{});
    }

    const example_exe = b.addExecutable(.{
        .name = "example_proxy",
        .root_module = example_module,
    });

    b.installArtifact(example_exe);

    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example", "Run consumer usage example in examples/zig/main.zig");
    example_step.dependOn(&run_example.step);

    const fmt_step = b.step("fmt", "Check source code formatting");
    const fmt = b.addFmt(.{
        .paths = &.{
            "src",
            "tests",
            "examples",
            "build.zig",
        },
    });
    fmt_step.dependOn(&fmt.step);
}
