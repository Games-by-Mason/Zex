const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Dds = @import("Dds");
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const PositionalArg = structopt.PositionalArg;
const log = std.log;

const c = @cImport({
    @cInclude("dds.h");
    @cInclude("stb_image.h");
});

const max_file_len = 4294967296;

const Metric = enum {
    linear,
    perceptual,
};

const raw_command: Command = .{
    .name = "raw",
    .description = "Store the image raw.",
};

const rdo_command: Command = .{
    .name = "rdo",
    .description = "Use RDO to make the output more compressible.",
    .named_args = &.{
        NamedArg.init(f32, .{
            .description = "bc7 rdo to apply, defaults to 0",
            .long = "lambda",
            .default = .{ .value = 0.0 },
        }),
        NamedArg.init(?f32, .{
            .description = "bc7 manually set smooth block error scale factor, higher values result in less distortion",
            .long = "smooth-block-error-scale",
            .default = .{ .value = 15.0 },
        }),
        NamedArg.init(bool, .{
            .long = "quant-mode6-endpoints",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "weight-modes",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "weight-low-frequency-partitions",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "pbit1-weighting",
            .default = .{ .value = true },
        }),
        NamedArg.init(f32, .{
            .long = "max-smooth-block-std-dev",
            .default = .{ .value = 18.0 },
        }),
        NamedArg.init(bool, .{
            .long = "try-2-matches",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "ultrasmooth-block-handling",
            .default = .{ .value = true },
        }),
    },
};

const bc7_command: Command = .{
    .name = "bc7",
    .description = "Encode as bc7.",
    .named_args = &.{
        NamedArg.init(Metric, .{
            .description = "bc7 metric, ignored when RDO is in use",
            .long = "metric",
            .default = .{ .value = .linear },
        }),
        NamedArg.init(u8, .{
            .description = "bc7 quality level, defaults to highest",
            .long = "uber-level",
            .default = .{ .value = RdoBcParams.bc7enc_max_uber_level },
        }),
        NamedArg.init(u8, .{
            .description = "bc7 partitions to scan in mode 1, defaults to highest",
            .long = "max-partitions-to-scan",
            .default = .{ .value = RdoBcParams.bc7enc_max_partitions },
        }),
        NamedArg.init(bool, .{
            .long = "mode6-only",
            .default = .{ .value = false },
        }),
        NamedArg.init(?u32, .{
            .long = "max-threads",
            .default = .{ .value = null },
        }),
        NamedArg.init(bool, .{
            .long = "status-output",
            .default = .{ .value = false },
        }),
    },
    .subcommands = &.{rdo_command},
};

const command: Command = .{
    .name = "dds",
    .description = "Converts PNG to DDS.",
    .named_args = &.{
        NamedArg.init(bool, .{
            .long = "y-flip",
            .default = .{ .value = false },
        }),
    },
    .positional_args = &.{
        PositionalArg.init([]const u8, .{
            .meta = "INPUT",
        }),
        PositionalArg.init([]const u8, .{
            .meta = "OUTPUT",
        }),
    },
    .subcommands = &.{
        raw_command,
        bc7_command,
    },
};

pub fn main() !void {
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Setup
    defer std.process.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const cwd = std.fs.cwd();

    // Load the PNG
    var input = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input.close();

    const input_bytes = input.readToEndAllocOptions(allocator, max_file_len, null, 1, 0) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(input_bytes);

    const subcommand = args.subcommand orelse {
        log.err("subcommand not specified", .{});
        std.process.exit(1);
    };

    var width_c: c_int = 0;
    var height_c: c_int = 0;
    var input_channels: c_int = 0;
    const raw_c = c.stbi_load_from_memory(
        input_bytes.ptr,
        @intCast(input_bytes.len),
        &width_c,
        &height_c,
        &input_channels,
        4,
    ) orelse {
        log.err("{s}: decoding failed", .{args.positional.INPUT});
        std.process.exit(1);
    };
    defer c.stbi_image_free(raw_c);
    const width: u32 = @intCast(width_c);
    const height: u32 = @intCast(height_c);
    const raw = raw_c[0 .. width * height * 4];

    var output = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output.sync() catch |err| @panic(@errorName(err));
        output.close();
    }

    // Write the four character code
    output.writeAll(&Dds.four_cc) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };

    // Write the header
    comptime assert(builtin.cpu.arch.endian() == .little);
    const header: Dds.Header = .{
        .height = @intCast(height),
        .width = @intCast(width),
        .ddspf = .{
            .flags = .{
                .four_cc = true,
            },
            .four_cc = Dds.Dxt10.four_cc,
        },
    };
    output.writeAll(std.mem.asBytes(&header)) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };

    const dxt10: Dds.Dxt10 = switch (subcommand) {
        .raw => .{
            .dxgi_format = .r8g8b8a8_unorm_srgb,
            .resource_dimension = .texture_2d,
            .misc_flags_2 = .{
                .straight = true,
            },
        },
        .bc7 => .{
            .dxgi_format = .bc7_unorm_srgb,
            .resource_dimension = .texture_2d,
            .misc_flags_2 = .{
                .straight = true,
            },
        },
    };
    output.writeAll(std.mem.asBytes(&dxt10)) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };

    switch (subcommand) {
        .raw => output.writeAll(raw) catch |err| {
            log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
            std.process.exit(1);
        },
        .bc7 => |bc7| {
            var params: RdoBcParams = .{};

            if (bc7.named.@"uber-level" > RdoBcParams.bc7enc_max_uber_level) {
                log.err("invalid value for uber-level", .{});
                std.process.exit(1);
            }
            params.bc7_uber_level = bc7.named.@"uber-level";

            if (bc7.named.@"max-partitions-to-scan" > RdoBcParams.bc7enc_max_partitions) {
                log.err("invalid value for max-partitions-to-scan", .{});
                std.process.exit(1);
            }
            params.bc7enc_max_partitions_to_scan = bc7.named.@"max-partitions-to-scan";
            params.perceptual = bc7.named.metric == .perceptual;
            params.y_flip = args.named.@"y-flip";
            params.bc7enc_mode6_only = bc7.named.@"mode6-only";

            if (bc7.named.@"max-threads") |v| {
                if (v == 0) {
                    log.err("invalid value for max-threads", .{});
                    std.process.exit(1);
                }
                params.rdo_max_threads = v;
            } else {
                params.rdo_max_threads = @intCast(std.math.clamp(std.Thread.getCpuCount() catch 1, 1, std.math.maxInt(u32)));
            }
            params.rdo_multithreading = params.rdo_max_threads > 1;
            params.status_output = bc7.named.@"status-output";

            if (bc7.subcommand) |bc7_subcommand| switch (bc7_subcommand) {
                .rdo => |rdo| {
                    if ((rdo.named.lambda < 0.0) or (rdo.named.lambda > 500.0)) {
                        log.err("invalid value for rdo-lambda", .{});
                        std.process.exit(1);
                    }
                    params.rdo_lambda = rdo.named.lambda;

                    if (rdo.named.@"smooth-block-error-scale") |v| {
                        if ((v < 1.0) or (v > 500.0)) {
                            log.err("invalid value for rdo-smooth-block-error-scale", .{});
                            std.process.exit(1);
                        }
                        params.rdo_smooth_block_error_scale = v;
                        params.custom_rdo_smooth_block_error_scale = true;
                    }

                    params.bc7enc_rdo_bc7_quant_mode6_endpoints = rdo.named.@"quant-mode6-endpoints";
                    params.bc7enc_rdo_bc7_weight_modes = rdo.named.@"weight-modes";
                    params.bc7enc_rdo_bc7_weight_low_frequency_partitions = rdo.named.@"weight-low-frequency-partitions";
                    params.bc7enc_rdo_bc7_pbit1_weighting = rdo.named.@"pbit1-weighting";

                    if ((rdo.named.@"max-smooth-block-std-dev") < 0.000125 or (rdo.named.@"max-smooth-block-std-dev" > 256.0)) {
                        log.err("invalid value for rdo-max-smooth-block-std-dev", .{});
                        std.process.exit(1);
                    }
                    params.rdo_max_smooth_block_std_dev = rdo.named.@"max-smooth-block-std-dev";
                    params.rdo_try_2_matches = rdo.named.@"try-2-matches";
                    params.rdo_ultrasmooth_block_handling = rdo.named.@"ultrasmooth-block-handling";
                },
            };

            const encoder = c.bc7enc_init() orelse @panic("failed to init encoder");
            defer c.bc7enc_deinit(encoder);
            if (!c.bc7enc_encode(encoder, &params, width, height, raw.ptr)) {
                log.err("{s}: encoder failed", .{args.positional.INPUT});
                std.process.exit(1);
            }

            // Write the pixels
            const blocks_bytes = c.bc7enc_get_total_blocks_size_in_bytes(encoder);
            const blocks = c.bc7enc_get_blocks(encoder)[0..blocks_bytes];

            output.writeAll(blocks) catch |err| {
                log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
                std.process.exit(1);
            };
        },
    }
}

const RdoBcParams = extern struct {
    const bc7enc_max_partitions = 64;
    const bc7enc_max_uber_level = 4;
    const max_level = 18;

    const Bc345ModeMask = enum(u32) {
        const bc4_use_all_modes: @This() = .bc4_default_search_rad;

        bc4_default_search_rad = 3,
        bc4_use_mode8_flag = 1,
        bc4_use_mode6_flag = 2,

        _,
    };

    pub const Bc1ApproxMode = enum(c_uint) {
        ideal = 0,
        nvidia = 1,
        amd = 2,
        ideal_round_4 = 3,
        _,
    };

    bc7_uber_level: c_int = bc7enc_max_uber_level,
    bc7enc_max_partitions_to_scan: c_int = bc7enc_max_partitions,
    perceptual: bool = false,
    y_flip: bool = false,
    bc45_channel0: u32 = 0,
    bc45_channel1: u32 = 1,

    bc1_mode: Bc1ApproxMode = .ideal,
    use_bc1_3color_mode: bool = true,

    use_bc1_3color_mode_for_black: bool = true,

    bc1_quality_level: c_int = max_level,

    dxgi_format: Dds.Dxt10.DxgiFormat = .bc7_unorm,

    rdo_lambda: f32 = 0.0,
    rdo_debug_output: bool = false,
    rdo_smooth_block_error_scale: f32 = 15.0,
    custom_rdo_smooth_block_error_scale: bool = false,
    lookback_window_size: u32 = 128,
    custom_lookback_window_size: bool = false,
    bc7enc_rdo_bc7_quant_mode6_endpoints: bool = true,
    bc7enc_rdo_bc7_weight_modes: bool = true,
    bc7enc_rdo_bc7_weight_low_frequency_partitions: bool = true,
    bc7enc_rdo_bc7_pbit1_weighting: bool = true,
    rdo_max_smooth_block_std_dev: f32 = 18.0,
    rdo_allow_relative_movement: bool = false,
    rdo_try_2_matches: bool = true,
    rdo_ultrasmooth_block_handling: bool = true,

    use_hq_bc345: bool = true,
    bc345_search_rad: c_int = 5,
    bc345_mode_mask: Bc345ModeMask = Bc345ModeMask.bc4_use_all_modes,

    bc7enc_mode6_only: bool = false,
    rdo_multithreading: bool = true,

    bc7enc_reduce_entropy: bool = false,

    m_use_bc7e: bool = false,
    status_output: bool = false,

    rdo_max_threads: u32 = 128,
};
