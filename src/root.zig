const std = @import("std");
const tracy = @import("tracy");

const Allocator = std.mem.Allocator;
const Zone = tracy.Zone;

pub const Image = @import("Image.zig");
pub const Texture = @import("Texture.zig");

pub const Options = struct {
    encoding: Image.EncodeOptions = .r8g8b8a8_srgb,
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
    premultiply: bool = true,
};

/// High level helper that reads from input and writes to output, processing the image as described
/// by options. Intended for use in an asset pipeline. Feel free to fork this function into your
/// codebase if you need to customize it further, it only calls into the public API.
pub fn process(
    gpa: Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    options: Options,
) !void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Create the texture
    var texture: Texture = .{};
    defer texture.deinit();

    // Append the first level
    const encoding: Image.Encoding = options.encoding;
    texture.appendLevel(try Image.rgbaF32InitFromReader(
        gpa,
        input,
        .{
            .color_space = encoding.colorSpace(),
            .alpha = if (options.preserve_alpha_coverage) |pac|
                .{ .alpha_test = .{ .threshold = pac.alpha_test } }
            else
                .opacity,
            .premultiply = options.premultiply,
        },
    )) catch @panic("OOB");

    // Resize the first level
    try texture.levels()[0].rgbaF32ResizeToFit(.{
        .max_size = options.max.size,
        .max_width = options.max.width,
        .max_height = options.max.height,
        .address_mode_u = options.address_mode.u,
        .address_mode_v = options.address_mode.v,
        .filter_u = options.filter.u,
        .filter_v = options.filter.v,
    });

    // Generate mipmaps if requested
    if (options.generate_mipmaps) {
        try texture.rgbaF32GenerateMipmaps(.{
            .filter_u = options.filter.u,
            .filter_v = options.filter.v,
            .address_mode_u = options.address_mode.u,
            .address_mode_v = options.address_mode.v,
            .block_size = encoding.blockSize(),
        });
    }

    // Encode the texture
    try texture.rgbaF32Encode(gpa, null, options.encoding);

    // Compress the texture if requested
    if (options.zlib) |zlib_options| {
        try texture.compressZlib(gpa, zlib_options);
    }

    // Write the texture to Ktx2 and flush
    try texture.writeKtx2(output);
    try output.flush();
}

test {
    _ = @import("zon.zig");
}
