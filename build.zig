const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match the specified filters.",
    ) orelse &.{};

    // Fetch dependencies
    const bc7enc = b.dependency("bc7enc_rdo", .{});
    const stb = b.dependency("stb", .{});
    const structopt = b.dependency("structopt", .{
        .target = target,
        .optimize = optimize,
    });

    // Build Ktx2
    const ktx2 = b.addModule("Ktx2", .{
        .root_source_file = b.path("src/Ktx2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build bc7enc
    const libbc7enc = b.addLibrary(.{
        .name = "bc7enc",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            // Doesn't currently pass safety checks
            .optimize = switch (optimize) {
                .ReleaseSmall => .ReleaseSmall,
                else => .ReleaseFast,
            },
        }),
    });
    libbc7enc.addIncludePath(bc7enc.path(""));
    libbc7enc.addCSourceFiles(.{
        .root = bc7enc.path(""),
        .files = &.{
            "bc7enc.cpp",
            "bc7decomp.cpp",
            "bc7decomp_ref.cpp",
            "lodepng.cpp",
            "rgbcx.cpp",
            "utils.cpp",
            "ert.cpp",
            "rdo_bc_encoder.cpp",
        },
    });
    libbc7enc.linkLibCpp();
    libbc7enc.addIncludePath(bc7enc.path("."));
    libbc7enc.installHeadersDirectory(bc7enc.path("."), "bc7enc", .{});

    // Build the C bindings
    const bindings = b.addLibrary(.{
        .name = "bindings",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            // Doesn't currently pass safety checks
            .optimize = switch (optimize) {
                .ReleaseSmall => .ReleaseSmall,
                else => .ReleaseFast,
            },
        }),
    });
    bindings.addIncludePath(stb.path(""));
    bindings.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "bindings.cpp",
        },
    });
    bindings.installHeadersDirectory(stb.path("."), "", .{});
    bindings.linkLibrary(libbc7enc);

    // Build Tracy
    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    // Build zlib
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    // Build Zex
    const zex = b.addModule("zex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zex.addImport("Ktx2", ktx2);
    zex.linkLibrary(bindings);
    zex.addImport("tracy", tracy.module("tracy"));
    zex.linkLibrary(zlib_dep.artifact("z"));

    // Build the command line tool
    const zex_exe = b.addExecutable(.{
        .name = "zex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zex_exe.root_module.addImport("zex", zex);
    zex_exe.root_module.addImport("structopt", structopt.module("structopt"));

    zex_exe.root_module.addImport("tracy", tracy.module("tracy"));
    if (tracy_enabled) {
        zex_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        zex_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    b.installArtifact(zex_exe);

    // Create the run command
    const run_cmd = b.addRunArtifact(zex_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Create the test command
    const lib_unit_tests = b.addTest(.{
        .root_module = zex,
        .filters = test_filters,
    });
    const exe_unit_tests = b.addTest(.{
        .root_module = zex_exe.root_module,
        .filters = test_filters,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
