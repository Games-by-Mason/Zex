const std = @import("std");
const tracy = @import("tracy");

const Allocator = std.mem.Allocator;
const Zone = tracy.Zone;

pub const Image = @import("Image.zig");
pub const Texture = @import("Texture.zig");

pub const ProcessOptions = struct {
    encoding: Image.EncodeOptions = .rgba_u8,
    preserve_alpha_coverage: ?struct {
        alpha_test: f32 = 0.5,
        max_steps: u8 = 10,
    } = null,
    max: struct {
        size: u32 = std.math.maxInt(u32),
        width: u32 = std.math.maxInt(u32),
        height: u32 = std.math.maxInt(u32),
    } = .{},
    filter: struct {
        u: Image.Filter = .default,
        v: Image.Filter = .default,
    } = .{},
    address_mode: struct {
        u: Image.AddressMode = .clamp,
        v: Image.AddressMode = .clamp,
    } = .{},
    zlib: ?Image.CompressZlibOptions = .{ .level = .@"9" },
    generate_mipmaps: bool = true,
};

// XXX: do we really need all these separate errors? we just want a way to log and return some failure right?
// i mean it's fine
/// High level helper that reads from input and writes to output, processing the image as described
/// by options. Intended for use in an asset pipeline. Feel free to fork this function into your
/// codebase if you need to customize it further, it only calls into the public API.
pub fn process(
    gpa: Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    options: ProcessOptions,
) error{
    ReadFailed,
    EndOfStream,
    OutOfMemory,
    StbImageFailure,
    StreamTooLong,
    WrongColorSpace,
    InvalidOption,
    EncoderFailed,
    WriteFailed,
    StbResizeFailure,
}!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // const encoding_options: Image.EncodeOptions = switch (encoding) {
    //     .bc7 => |eo| b: {
    //         const bc7: Image.Bc7Options = .{
    //             .uber_level = eo.named.uber,
    //             .reduce_entropy = eo.named.@"reduce-entropy",
    //             .max_partitions_to_scan = eo.named.@"max-partitions-to-scan",
    //             .mode_6_only = eo.named.@"mode-6-only",
    //             .rdo = if (eo.subcommand) |subcommand| switch (subcommand) {
    //                 .rdo => |rdo| .{
    //                     .lambda = rdo.named.lambda,
    //                     .lookback_window = rdo.named.@"lookback-window",
    //                     .smooth_block_error_scale = rdo.named.@"smooth-block-error-scale",
    //                     .quantize_mode_6_endpoints = rdo.named.@"quantize-mode-6-endpoints",
    //                     .weight_modes = rdo.named.@"weight-modes",
    //                     .weight_low_frequency_partitions = rdo.named.@"weight-low-frequency-partitions",
    //                     .pbit1_weighting = rdo.named.@"pbit1-weighting",
    //                     .max_smooth_block_std_dev = rdo.named.@"max-smooth-block-std-dev",
    //                     .try_two_matches = rdo.named.@"try-two-matches",
    //                     .ultrasmooth_block_handling = rdo.named.@"ultrasmooth-block-handling",
    //                 },
    //             } else null,
    //         };
    //         break :b switch (eo.named.@"color-space") {
    //             .srgb => .{ .bc7_srgb = bc7 },
    //             .linear => .{ .bc7 = bc7 },
    //         };
    //     },
    //     .@"rgba-u8" => |eo| switch (eo.named.@"color-space") {
    //         .linear => .rgba_u8,
    //         .srgb => .rgba_srgb_u8,
    //     },
    //     .@"rgba-f32" => .rgba_f32,
    // };
    const encoding_tag: Image.Encoding = options.encoding;

    var texture: Texture = .{};
    defer texture.deinit();

    // XXX: size?
    // XXX: make sure we flush writers!
    texture.appendLevel(try Image.rgbaF32InitFromReader(
        gpa,
        input,
        .{
            // XXX: a little weird that this arg is here, alos other should be named/have default...
            .color_space = encoding_tag.colorSpace(),
            .alpha = if (options.preserve_alpha_coverage) |pac|
                .{ .alpha_test = .{ .threshold = pac.alpha_test } }
            else
                .opacity,
        },
    )) catch @panic("OOB");
    // XXX: maybe we DO want to set filters/address mode on the texture once up front to make less verbose?
    // note that we resize the first level via a getter so would need a wrapper for that for that to be doable
    // with the params
    // Resize the image if requested
    try texture.levels()[0].rgbaF32ResizeToFit(.{
        .max_size = options.max.size,
        .max_width = options.max.width,
        .max_height = options.max.height,
        .address_mode_u = options.address_mode.u,
        .address_mode_v = options.address_mode.v,
        .filter_u = options.filter.u,
        .filter_v = options.filter.v,
    });
    // XXX: this should be optional, test in viewer
    if (options.generate_mipmaps) {
        try texture.rgbaF32GenerateMipmaps(.{
            .filter_u = options.filter.u,
            .filter_v = options.filter.v,
            .address_mode_u = options.address_mode.u,
            .address_mode_v = options.address_mode.v,
            .block_size = encoding_tag.blockSize(),
        });
    }
    try texture.rgbaF32Encode(gpa, null, options.encoding);
    if (options.zlib) |zlib_options| {
        try texture.compressZlib(gpa, zlib_options);
    }
    try texture.writeKtx2(output);
    try output.flush();
}

test {
    _ = @import("zon.zig");
}
