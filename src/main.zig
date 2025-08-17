const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const PositionalArg = structopt.PositionalArg;
const zex = @import("zex");
const Image = zex.Image;
pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");
const Zone = tracy.Zone;

const max_file_len = 4294967296;

const ColorSpace = enum {
    linear,
    srgb,
};

const Alpha = enum {
    straight,
    premultiplied,
};

pub const Filter = enum(c_uint) {
    triangle = @intFromEnum(Image.Filter.triangle),
    @"cubic-b-spline" = @intFromEnum(Image.Filter.cubic_b_spline),
    @"catmull-rom" = @intFromEnum(Image.Filter.catmull_rom),
    mitchell = @intFromEnum(Image.Filter.mitchell),
    @"point-sample" = @intFromEnum(Image.Filter.point_sample),

    pub fn filter(self: @This()) Image.Filter {
        return @enumFromInt(@intFromEnum(self));
    }
};

const ZlibLevel = enum(u4) {
    const StdLevel = std.compress.flate.Compress.Level;

    fastest = @intFromEnum(StdLevel.fast),
    smallest = @intFromEnum(StdLevel.best),

    @"4" = @intFromEnum(StdLevel.level_4),
    @"5" = @intFromEnum(StdLevel.level_5),
    @"6" = @intFromEnum(StdLevel.level_6),
    @"7" = @intFromEnum(StdLevel.level_7),
    @"8" = @intFromEnum(StdLevel.level_8),
    @"9" = @intFromEnum(StdLevel.level_9),

    pub fn toStdLevel(self: @This()) StdLevel {
        return @enumFromInt(@intFromEnum(self));
    }
};

const command: Command = .{
    .name = "zex",
    .description = "Converts images to KTX2.",
    .named_args = &.{
        NamedArg.init(Alpha, .{
            .description = "whether or not the input is already premultiplied",
            .long = "input-alpha",
            .default = .{ .value = .straight },
        }),
        NamedArg.init(?ZlibLevel, .{
            .description = "supercompress the data at the given level with zlib",
            .long = "zlib",
            .default = .{ .value = null },
        }),
        NamedArg.init(bool, .{
            .description = "automatically generate mipmaps",
            .long = "generate-mipmaps",
            .default = .{ .value = false },
        }),
        NamedArg.init(?f32, .{
            .description = "preserves alpha coverage for the given alpha test threshold, slower but significantly improves mipmapping of cutouts and alpha to coverage textures",
            .long = "preserve-alpha-coverage",
            .default = .{ .value = null },
        }),
        NamedArg.init(u8, .{
            .description = "the max number of search steps used by --preserve-alpha-coverage",
            .long = "preserve-alpha-coverage-max-steps",
            .default = .{ .value = 10 },
        }),
        NamedArg.init(?Filter, .{
            .description = "defaults to the mitchell filter for LDR images, triangle for HDR images",
            .long = "filter",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Filter, .{
            .description = "overrides --filter in the U direction",
            .long = "filter-u",
            .default = .{ .value = null },
        }),
        NamedArg.init(?Filter, .{
            .description = "overrides --filter in the V direction",
            .long = "filter-v",
            .default = .{ .value = null },
        }),
        NamedArg.init(Image.AddressMode, .{
            .description = "overrides --address-mode in the U direction",
            .long = "address-mode-u",
        }),
        NamedArg.init(Image.AddressMode, .{
            .description = "overrides --address-mode in the V direction",
            .long = "address-mode-v",
        }),
        NamedArg.init(?u32, .{
            .description = "scale the largest dimension down to max size, preserves aspect ratio",
            .long = "max-size",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u32, .{
            .description = "overrides --max-size for the width, still preserves aspect ratio",
            .long = "max-width",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u32, .{
            .description = "overrides --max-size for the height, still preserves aspect ratio",
            .long = "max-height",
            .default = .{ .value = null },
        }),
        NamedArg.init(?u16, .{
            .long = "max-threads",
            .default = .{ .value = null },
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
        rgba_u8_command,
        rgba_f32_command,
        bc7_command,
    },
};

const rgba_u8_command: Command = .{
    .name = "rgba-u8",
    .named_args = &.{
        NamedArg.init(ColorSpace, .{
            .long = "color-space",
            .default = .{ .value = .srgb },
        }),
    },
};

const rgba_f32_command: Command = .{
    .name = "rgba-f32",
};

const bc7_command: Command = .{
    .name = "bc7",
    .named_args = &.{
        NamedArg.init(ColorSpace, .{
            .long = "color-space",
            .default = .{ .value = .srgb },
        }),
        NamedArg.init(u8, .{
            .description = "quality level, defaults to highest",
            .long = "uber",
            .default = .{ .value = Image.Bc7Enc.Params.max_uber_level },
        }),
        NamedArg.init(bool, .{
            .description = "reduce entropy for better supercompression",
            .long = "reduce-entropy",
            .default = .{ .value = false },
        }),
        NamedArg.init(u8, .{
            .description = "partitions to scan in mode 1, defaults to highest",
            .long = "max-partitions-to-scan",
            .default = .{ .value = Image.Bc7Enc.Params.max_partitions },
        }),
        NamedArg.init(bool, .{
            .long = "mode-6-only",
            .default = .{ .value = false },
        }),
    },
    .subcommands = &.{rdo_command},
};

const rdo_command: Command = .{
    .name = "rdo",
    .description = "use RDO for better supercompression",
    .named_args = &.{
        NamedArg.init(f32, .{
            .description = "rdo to apply",
            .long = "lambda",
            .default = .{ .value = 0.5 },
        }),
        NamedArg.init(?u17, .{
            .long = "lookback-window",
            .default = .{ .value = null },
        }),
        NamedArg.init(?f32, .{
            .description = "manually set smooth block error scale factor, higher values result in less distortion",
            .long = "smooth-block-error-scale",
            .default = .{ .value = 15.0 },
        }),
        NamedArg.init(bool, .{
            .long = "quantize-mode-6-endpoints",
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
            .long = "try-two-matches",
            .default = .{ .value = true },
        }),
        NamedArg.init(bool, .{
            .long = "ultrasmooth-block-handling",
            .default = .{ .value = true },
        }),
    },
};

pub fn main() !void {
    // Tracy
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    tracy.frameMarkStart("main");
    tracy.appInfo("Zex");

    // Setup
    defer std.process.cleanExit();
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const encoding = args.subcommand orelse {
        log.err("subcommand not specified", .{});
        std.process.exit(1);
    };

    const cwd = std.fs.cwd();

    var input_file = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input_file.close();

    var reader_buf: [1024]u8 = undefined;
    var input_file_reader = input_file.readerStreaming(&reader_buf);

    // XXX: make sure we flush writers!
    var output_file = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    // XXX: share buf or no? size?
    var writer_buf: [1024]u8 = undefined;
    // XXX: share buf or no? size?
    var output_file_writer = output_file.writerStreaming(&writer_buf);

    const encoding_options: Image.EncodeOptions = switch (encoding) {
        .bc7 => |eo| b: {
            const bc7: Image.Bc7Options = .{
                .uber_level = eo.named.uber,
                .reduce_entropy = eo.named.@"reduce-entropy",
                .max_partitions_to_scan = eo.named.@"max-partitions-to-scan",
                .mode_6_only = eo.named.@"mode-6-only",
                .rdo = if (eo.subcommand) |subcommand| switch (subcommand) {
                    .rdo => |rdo| .{
                        .lambda = rdo.named.lambda,
                        .lookback_window = rdo.named.@"lookback-window",
                        .smooth_block_error_scale = rdo.named.@"smooth-block-error-scale",
                        .quantize_mode_6_endpoints = rdo.named.@"quantize-mode-6-endpoints",
                        .weight_modes = rdo.named.@"weight-modes",
                        .weight_low_frequency_partitions = rdo.named.@"weight-low-frequency-partitions",
                        .pbit1_weighting = rdo.named.@"pbit1-weighting",
                        .max_smooth_block_std_dev = rdo.named.@"max-smooth-block-std-dev",
                        .try_two_matches = rdo.named.@"try-two-matches",
                        .ultrasmooth_block_handling = rdo.named.@"ultrasmooth-block-handling",
                    },
                } else null,
            };
            break :b switch (eo.named.@"color-space") {
                .srgb => .{ .bc7_srgb = bc7 },
                .linear => .{ .bc7 = bc7 },
            };
        },
        .@"rgba-u8" => |eo| switch (eo.named.@"color-space") {
            .linear => .rgba_u8,
            .srgb => .rgba_srgb_u8,
        },
        .@"rgba-f32" => .rgba_f32,
    };
    const encoding_tag: Image.Encoding = encoding_options;

    var texture: zex.Texture = .{};
    defer texture.deinit();

    // XXX: size?
    // XXX: make sure we flush writers!
    texture.appendLevel(try Image.rgbaF32InitFromReader(
        allocator,
        max_file_len,
        &input_file_reader.interface,
        .{
            // XXX: a little weird that this arg is here, alos other should be named/have default...
            .color_space = encoding_tag.colorSpace(),
            // XXX: support `.other` too in cli
            .alpha = if (args.named.@"preserve-alpha-coverage") |threshold| .{ .alpha_test = .{
                .threshold = threshold,
            } } else .opacity,
        },
    )) catch @panic("OOB");
    // XXX: maybe we DO want to set filters/address mode on the texture once up front to make less verbose?
    // note that we resize the first level via a getter so would need a wrapper for that for that to be doable
    // with the params
    // Resize the image if requested
    try texture.levels()[0].rgbaF32ResizeToFit(.{
        .max_size = args.named.@"max-size" orelse std.math.maxInt(u32),
        .max_width = args.named.@"max-width" orelse std.math.maxInt(u32),
        .max_height = args.named.@"max-height" orelse std.math.maxInt(u32),
        .address_mode_u = args.named.@"address-mode-u",
        .address_mode_v = args.named.@"address-mode-v",
        .filter_u = switch (args.named.@"filter-u" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
        .filter_v = switch (args.named.@"filter-v" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
    });
    try texture.rgbaF32GenerateMipmaps(.{
        .filter_u = switch (args.named.@"filter-u" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
        .filter_v = switch (args.named.@"filter-v" orelse args.named.filter orelse @panic("unimplemented")) {
            .triangle => .triangle,
            .@"cubic-b-spline" => .cubic_b_spline,
            .@"catmull-rom" => .catmull_rom,
            .mitchell => .mitchell,
            .@"point-sample" => .point_sample,
        },
        .address_mode_u = args.named.@"address-mode-u",
        .address_mode_v = args.named.@"address-mode-v",
        .block_size = encoding_tag.blockSize(),
    });
    try texture.rgbaF32Encode(allocator, args.named.@"max-threads", encoding_options);
    if (args.named.zlib) |compression_level| {
        try texture.compressZlib(allocator, .{ .level = compression_level.toStdLevel() });
    }
    try texture.writeKtx2(&output_file_writer.interface);
}
