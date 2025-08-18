//! An image for texture processing.
//!
//! Many manipulations are only supported on uncompressed rgbaf32 encoded images. This is indicated
//! by prefixing the function names with `rgbaf32`. This allows processing LDR and HDR images in the
//! same code paths, and increases precision of intermediate operations. Technically this does result
//! in extra work being done when loading LDR images and exporting them with no processing, but most
//! images require processing (if only to generate mipmaps).
//!
//! The allocator field may be replaced depending on operations done on the image. For example,
//! since resizing is done with STB, resize operations will free the original allocation and replace
//! it with an STB managed allocation, updating the allocator as needed. We can't simply pass a
//! user supplied Zig allocator to STB since it doesn't provide a length when freeing memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const Ktx2 = @import("Ktx2");

const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
    @cInclude("zlib.h");
});

const Image = @This();

/// The width of the image in pixels.
width: u32,
/// The height of the image in pixels.
height: u32,
/// The bytes requires to store the image without supercompression.
uncompressed_byte_length: u64,
/// The encoded image data. See `encoding` and `supercompression` for a description of how to
/// interpret these bytes.
buf: []u8,
/// Whether or not the source data was HDR, regardless of the current encoding.
hdr: bool,
/// The current encoding.
encoding: Encoding,
/// The current supercompression scheme.
supercompression: Ktx2.Header.SupercompressionScheme,
/// The alpha channel mode.
alpha: Alpha,
/// The allocator used to freeing buf on deinit.
allocator: Allocator,

pub const Alpha = union(enum) {
    /// The alpha channel represents opacity.
    opacity: void,
    /// The alpha channel represents opacity and is used for alpha testing.
    alpha_test: struct {
        /// Values less than or equal to threshold are expected to be considered transparent by the
        /// renderer, values larger are expected to be considered opaque.
        threshold: f32,
        /// The ratio of pixels expected to pass the alpha test. See `rgbaF32PreserveAlphaCoverage`.
        target_coverage: f32,
    },
    // XXX: we actually want to support non premul alpha for techniques like C2A
    /// The alpha channel is used for something other than transparency.
    ///
    /// It is not recommended to use this to avoid the premultiply step: you will get incorrect
    /// filtering, both in Zex, and on your GPU. If premultiplied alpha looks wrong in your
    /// renderer, check your blend mode.
    other: void,

    /// Returns true for alpha modes where Zex will premultiply your alpha for you, false otherwise.
    pub fn premultiplied(self: @This()) bool {
        return switch (self) {
            .alpha_test, .opacity => true,
            .other => false,
        };
    }
};

pub const Encoding = enum {
    rgba_u8,
    rgba_srgb_u8,
    rgba_f32,
    bc7,
    bc7_srgb,

    /// Returns the number of samples per pixel.
    pub fn samples(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .rgba_f32 => 4,
            .bc7, .bc7_srgb => 1,
        };
    }

    /// Returns the size of a block in pixels.
    pub fn blockSize(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .rgba_f32 => 1,
            .bc7, .bc7_srgb => 4,
        };
    }

    /// Returns the color space.
    pub fn colorSpace(self: @This()) Image.ColorSpace {
        return switch (self) {
            .bc7, .rgba_u8 => .linear,
            .bc7_srgb, .rgba_srgb_u8 => .srgb,
            .rgba_f32 => .hdr,
        };
    }

    /// Returns the element size.
    pub fn typeSize(self: @This()) u8 {
        return switch (self) {
            .rgba_u8, .rgba_srgb_u8, .bc7, .bc7_srgb => 1,
            .rgba_f32 => 4,
        };
    }
};

pub const ColorSpace = enum(c_uint) {
    /// Linear LDR data.
    linear,
    /// SRGB LDR data.
    srgb,
    /// Linear HDR data.
    hdr,
};

pub const InitFromReaderOptions = struct {
    /// See `Image.Alpha`.
    pub const Alpha = union(enum) {
        opacity: void,
        alpha_test: struct { threshold: f32 = 0.5 },
        other,
    };
    color_space: ColorSpace,
    alpha: @This().Alpha,
};

pub const InitFromReaderError = error{
    StbImageFailure,
    WrongColorSpace,
    StreamTooLong,
    OutOfMemory,
} || std.Io.Reader.Error;

/// Read an image using `stb_image.h`. Allocation done by STB.
pub fn rgbaF32InitFromReader(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: InitFromReaderOptions,
) InitFromReaderError!Image {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // We could pass the reader into STB for additional pipelining and reduced allocations. For
    // simplicity's sake we don't do this yet since it isn't a particularly large performance win,
    // but we keep our options open by taking a reader.
    const input_bytes = b: {
        const read_zone = Zone.begin(.{ .name = "read", .src = @src() });
        defer read_zone.end();
        break :b try reader.allocRemaining(gpa, .unlimited);
    };
    defer gpa.free(input_bytes);

    // Check if the input is HDR
    const hdr = c.stbi_is_hdr_from_memory(
        input_bytes.ptr,
        @intCast(input_bytes.len),
    ) == 1;
    switch (options.color_space) {
        .linear, .srgb => if (hdr) return error.WrongColorSpace,
        .hdr => if (!hdr) return error.WrongColorSpace,
    }

    // We're gonna do our own premul, and STB doesn't expose whether it was already done or not.
    // Typically it is not unless we're dealing with an iPhone PNG. Always get canonical format.
    c.stbi_set_unpremultiply_on_load(1);
    c.stbi_convert_iphone_png_to_rgb(1);

    // All images are loaded as linear floats regardless of the source and dest formats.
    c.stbi_ldr_to_hdr_gamma(switch (options.color_space) {
        .srgb => 2.2,
        .linear, .hdr => 1.0,
    });

    // Load the image using STB
    var width: c_int = 0;
    var height: c_int = 0;
    var input_channels: c_int = 0;
    const buf = b: {
        const read_zone = Zone.begin(.{ .name = "stbi_loadf_from_memory", .src = @src() });
        defer read_zone.end();
        const ptr = c.stbi_loadf_from_memory(
            input_bytes.ptr,
            @intCast(input_bytes.len),
            &width,
            &height,
            &input_channels,
            4,
        ) orelse return error.StbImageFailure;
        const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        break :b std.mem.sliceAsBytes(ptr[0..len]);
    };

    // Create the image
    var result: @This() = .{
        .width = @intCast(width),
        .height = @intCast(height),
        .uncompressed_byte_length = buf.len,
        .buf = buf,
        .hdr = hdr,
        .encoding = .rgba_f32,
        .alpha = switch (options.alpha) {
            .opacity => .opacity,
            .alpha_test => |at| .{ .alpha_test = .{
                .threshold = at.threshold,
                .target_coverage = 0.0,
            } },
            .other => .other,
        },
        .supercompression = .none,
        .allocator = stb_allocator,
    };

    // Premultiply the alpha if requested
    if (result.alpha.premultiplied()) {
        const premultiply_zone = Zone.begin(.{ .name = "premultiply", .src = @src() });
        defer premultiply_zone.end();
        var px: usize = 0;
        const f32s = result.rgbaF32Samples();
        while (px < @as(usize, result.width) * @as(usize, result.height) * 4) : (px += 4) {
            const a = f32s[px + 3];
            f32s[px + 0] = f32s[px + 0] * a;
            f32s[px + 1] = f32s[px + 1] * a;
            f32s[px + 2] = f32s[px + 2] * a;
        }
    }

    // XXX: do this lazily since it may not end up being used?
    // Calculate coverage so that we can preserve it on resize
    switch (result.alpha) {
        .alpha_test => |*at| at.target_coverage = result.rgbaF32AlphaCoverage(at.threshold, 1.0),
        else => {},
    }

    return result;
}

pub fn deinit(self: *Image) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    if (self.isUncompressedRgbaF32()) {
        self.allocator.free(self.rgbaF32Samples());
    } else {
        self.allocator.free(self.buf);
    }
    _ = self.toOwned();
}

pub fn isUncompressedRgbaF32(self: Image) bool {
    return self.encoding == .rgba_f32 and self.supercompression == .none;
}

pub fn assertIsUncompressedRgbaF32(self: Image) void {
    if (!isUncompressedRgbaF32(self)) @panic("expected uncompressed rgba-f32");
}

pub fn rgbaF32Samples(self: Image) []f32 {
    self.assertIsUncompressedRgbaF32();
    var f32s: []f32 = undefined;
    f32s.ptr = @alignCast(@ptrCast(self.buf.ptr));
    f32s.len = self.buf.len / @sizeOf(f32);
    return f32s;
}

pub const AddressMode = enum(c_uint) {
    clamp = c.STBIR_EDGE_CLAMP,
    reflect = c.STBIR_EDGE_REFLECT,
    wrap = c.STBIR_EDGE_WRAP,
    zero = c.STBIR_EDGE_ZERO,
};

pub const Filter = enum(c_uint) {
    // See https://github.com/Games-by-Mason/Zex/issues/20
    // box = c.STBIR_FILTER_BOX,
    default,
    triangle,
    cubic_b_spline,
    catmull_rom,
    mitchell,
    point_sample,

    fn sharpens(self: @This(), hdr: bool) bool {
        return switch (self) {
            .default => !hdr,
            .triangle, .point_sample, .cubic_b_spline => false,
            .mitchell, .catmull_rom => true,
        };
    }

    fn toStbFilter(self: @This(), hdr: bool) c.stbir_filter {
        return switch (self) {
            .default => if (hdr) c.STBIR_FILTER_TRIANGLE else c.STBIR_FILTER_MITCHELL,
            .triangle => c.STBIR_FILTER_TRIANGLE,
            .cubic_b_spline => c.STBIR_FILTER_CUBICBSPLINE,
            .catmull_rom => c.STBIR_FILTER_CATMULLROM,
            .mitchell => c.STBIR_FILTER_MITCHELL,
            .point_sample => c.STBIR_FILTER_POINT_SAMPLE,
        };
    }
};

pub const ResizeError = error{ StbResizeFailure, OutOfMemory };

pub const ResizeOptions = struct {
    width: u32,
    height: u32,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
    preserve_alpha_coverage_max_steps: u8 = 10,
};

/// Resizes this image.
pub fn rgbaF32Resize(self: *Image, options: ResizeOptions) ResizeError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();
    if (self.width != options.width or self.height != options.height) {
        const result = try self.rgbaF32Resized(options);
        self.deinit();
        self.* = result;
    }
}

/// Returns a resized copy of this image.
pub fn rgbaF32Resized(self: Image, options: ResizeOptions) ResizeError!Image {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();
    assert(options.width > 0 and options.height > 0); // XXX: ...

    const output_samples_len = @as(usize, options.width) * @as(usize, options.height) * 4;
    const output_samples_ptr: [*]f32 = @ptrCast(@alignCast(c.malloc(
        output_samples_len * @sizeOf(f32),
    ) orelse return error.OutOfMemory));
    const output_samples = output_samples_ptr[0..output_samples_len];
    errdefer c.free(output_samples.ptr);

    var stbr_options: c.STBIR_RESIZE = undefined;
    c.stbir_resize_init(
        &stbr_options,
        self.rgbaF32Samples().ptr,
        @intCast(self.width),
        @intCast(self.height),
        0,
        output_samples.ptr,
        @intCast(options.width),
        @intCast(options.height),
        0,
        // We always premultiply alpha channels ourselves if they represent transparency
        c.STBIR_RGBA_PM,
        c.STBIR_TYPE_FLOAT,
    );

    stbr_options.horizontal_edge = @intFromEnum(options.address_mode_u);
    stbr_options.vertical_edge = @intFromEnum(options.address_mode_v);
    stbr_options.horizontal_filter = options.filter_u.toStbFilter(self.hdr);
    stbr_options.vertical_filter = options.filter_v.toStbFilter(self.hdr);

    {
        const resize_zone = Zone.begin(.{ .name = "stbir_resize_extended", .src = @src() });
        defer resize_zone.end();
        if (c.stbir_resize_extended(&stbr_options) != 1) {
            return error.StbResizeFailure;
        }
    }

    // Sharpening filters can push values below zero. Clamp them before doing further processing.
    // We could alternatively use `STBIR_FLOAT_LOW_CLAMP`, see issue #18.
    if (options.filter_u.sharpens(self.hdr) or options.filter_v.sharpens(self.hdr)) {
        const clamp_zone = Zone.begin(.{ .name = "clamp", .src = @src() });
        defer clamp_zone.end();
        for (output_samples) |*d| {
            d.* = @max(d.*, 0.0);
        }
    }

    const buf = std.mem.sliceAsBytes(output_samples);
    const result: @This() = .{
        .width = options.width,
        .height = options.height,
        .uncompressed_byte_length = buf.len,
        .buf = buf,
        .hdr = self.hdr,
        .encoding = .rgba_f32,
        .supercompression = .none,
        .allocator = stb_allocator,
        .alpha = self.alpha,
    };

    self.rgbaF32PreserveAlphaCoverage(options.preserve_alpha_coverage_max_steps);

    return result;
}

pub const SizeToFitOptions = struct {
    max_size: u32 = std.math.maxInt(u32),
    max_width: u32 = std.math.maxInt(u32),
    max_height: u32 = std.math.maxInt(u32),
};

/// Returns the largest size that fits within `options` while preserving the aspect ratio.
pub fn rgbaF32SizeToFit(self: Image, options: SizeToFitOptions) struct { u32, u32 } {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();

    const self_width_f: f64 = @floatFromInt(self.width);
    const self_height_f: f64 = @floatFromInt(self.height);

    const max_width: u32 = @min(options.max_width, options.max_size, self.width);
    const max_height: u32 = @min(options.max_height, options.max_size, self.height);

    const max_width_f: f64 = @floatFromInt(max_width);
    const max_height_f: f64 = @floatFromInt(max_height);

    const x_scale = @min(max_width_f / self_width_f, 1.0);
    const y_scale = @min(max_height_f / self_height_f, 1.0);

    const scale = @min(x_scale, y_scale);
    const width = @min(@as(u32, @intFromFloat(scale * self_width_f)), max_width);
    const height = @min(@as(u32, @intFromFloat(scale * self_height_f)), max_height);

    return .{ width, height };
}

pub const ResizeToFitOptions = struct {
    max_size: u32 = std.math.maxInt(u32),
    max_width: u32 = std.math.maxInt(u32),
    max_height: u32 = std.math.maxInt(u32),
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

/// Resizes the image to fit within `options` while preserving the aspect ratio.
pub fn rgbaF32ResizeToFit(self: *Image, options: ResizeToFitOptions) ResizeError!void {
    self.assertIsUncompressedRgbaF32();
    const width, const height = self.rgbaF32SizeToFit(.{
        .max_size = options.max_size,
        .max_width = options.max_width,
        .max_height = options.max_height,
    });

    try self.rgbaF32Resize(.{
        .width = width,
        .height = height,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filter_u,
        .filter_v = options.filter_v,
    });
}

/// Resizes a copy of the image resized to fit within `options` while preserving the aspect ratio.
pub fn rgbaF32ResizedToFit(self: Image, options: ResizeToFitOptions) ResizeError!Image {
    self.assertIsUncompressedRgbaF32();
    const width, const height = self.sizeToFit(.{
        .max_size = options.max_size,
        .max_width = options.max_width,
        .max_height = options.max_height,
    });

    return self.resized(.{
        .width = width,
        .height = height,
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filter_u,
        .filter_v = options.filter_v,
    });
}

pub const GenerateMipMapsOptions = struct {
    block_size: u8,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

// XXX: move this logic to texture, document, and set max amount instead of block size, but assert
// on write that we got it right, and allow calculating max from block size
pub fn rgbaF32GenerateMipmaps(self: Image, options: GenerateMipMapsOptions) GenerateMipmaps {
    self.assertIsUncompressedRgbaF32();
    return .{
        .options = options,
        .image = self,
    };
}

pub const GenerateMipmaps = struct {
    options: GenerateMipMapsOptions,
    image: Image,

    pub fn next(self: *@This()) ResizeError!?Image {
        // Stop once we're below the block size, there's no benefit to further mipmaps
        if (self.image.width <= self.options.block_size and
            self.image.height <= self.options.block_size)
        {
            return null;
        }

        // Halve the image size
        self.image = try self.image.rgbaF32Resized(.{
            .width = @max(1, self.image.width / 2),
            .height = @max(1, self.image.height / 2),
            .address_mode_u = self.options.address_mode_u,
            .address_mode_v = self.options.address_mode_v,
            .filter_u = self.options.filter_u,
            .filter_v = self.options.filter_v,
        });
        return self.image;
    }
};

/// Calculates the ratio of pixels that would pass the given alpha test threshold if the given
/// scaling was applied.
pub fn rgbaF32AlphaCoverage(self: Image, threshold: f32, scale: f32) f32 {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();

    // Quantize the threshold to the output type
    const quantized_threshold = if (self.hdr) threshold else @round(threshold * 255.0) / 255.0;

    // Calculate the coverage
    var coverage: f32 = 0;
    const f32s = self.rgbaF32Samples();
    for (0..@as(usize, self.width) * @as(usize, self.height)) |i| {
        const alpha = f32s[i * 4 + 3];
        if (alpha * scale > quantized_threshold) coverage += 1.0;
    }
    coverage /= @floatFromInt(@as(usize, self.width) * @as(usize, self.height));
    return coverage;
}

/// Attempts to preserve the ratio of pixels that pass the alpha test. Automatically called on
/// resize for alpha tested images, exposed for use with custom image processing.
pub fn rgbaF32PreserveAlphaCoverage(self: Image, max_steps: u8) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();
    const alpha_test = switch (self.alpha) {
        .alpha_test => |at| at,
        else => return,
    };

    // Binary search for the best scale parameter
    var best_scale: f32 = 1.0;
    var best_dist = std.math.inf(f32);
    var upper_threshold: f32 = 1.0;
    var lower_threshold: f32 = 0.0;
    var curr_threshold: f32 = alpha_test.threshold;
    {
        const search_zone = Zone.begin(.{ .name = "search", .src = @src() });
        defer search_zone.end();
        for (0..max_steps) |_| {
            const curr_scale = alpha_test.threshold / curr_threshold;
            const coverage = self.rgbaF32AlphaCoverage(alpha_test.threshold, curr_scale);
            const dist_to_coverage = @abs(coverage - alpha_test.target_coverage);
            if (dist_to_coverage < best_dist) {
                best_dist = dist_to_coverage;
                best_scale = curr_scale;
            }

            if (coverage < alpha_test.target_coverage) {
                upper_threshold = curr_threshold;
            } else if (coverage > alpha_test.target_coverage) {
                lower_threshold = curr_threshold;
            } else {
                break;
            }

            curr_threshold = (lower_threshold + upper_threshold) / 2.0;
        }
    }

    // Apply the scaling
    if (best_scale != 1.0) {
        const search_zone = Zone.begin(.{ .name = "scale", .src = @src() });
        defer search_zone.end();
        const f32s = self.rgbaF32Samples();
        for (0..@as(usize, self.width) * @as(usize, self.height)) |i| {
            const a = &f32s[i * 4 + 3];
            a.* = @min(a.* * best_scale, 1.0);
        }
    }
}

// XXX: clean up usages of this and document
pub fn toOwned(self: *Image) Image {
    const owned: Image = self.*;
    // XXX: do we really need to clear this stuff? could just clear the data
    self.width = 0;
    self.height = 0;
    self.buf = &.{};
    self.allocator = moved_allocator;
    return owned;
}

pub const EncodeOptions = union(Encoding) {
    rgba_u8: void,
    rgba_srgb_u8: void,
    rgba_f32: void,
    bc7: Bc7Options,
    bc7_srgb: Bc7Options,
};

pub const EncodeError = EncodeRgbaU8Error || EncodeBc7Error;

// XXX: do we really need the general function for this? alternatively, do we really need the specific ones
// to be public? we only expose the general one on texture cause less boilerplate. if we get rid of
// the other ones publically, then we can consider name order again.
// XXX: make an encode function on texture that encodes all its levels
/// Transcodes from rgba-f32 to the given encoding.
pub fn rgbaF32Encode(
    self: *@This(),
    gpa: Allocator,
    max_threads: ?u16,
    options: EncodeOptions,
) EncodeError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    switch (options) {
        .rgba_u8 => try self.rgbaF32EncodeRgbaU8(gpa),
        .rgba_srgb_u8 => try self.rgbaF32EncodeRgbaSrgbU8(gpa),
        .rgba_f32 => {},
        .bc7 => |bc7_options| try self.rgbaF32EncodeBc7(max_threads, bc7_options),
        .bc7_srgb => |bc7_options| try self.rgbaF32EncodeBc7Srgb(max_threads, bc7_options),
    }
}

pub const EncodeRgbaU8Error = error{OutOfMemory};

pub fn rgbaF32EncodeRgbaU8(self: *@This(), gpa: Allocator) EncodeRgbaU8Error!void {
    try self.rgbaF32EncodeRgbaU8Ex(gpa, false);
}

pub fn rgbaF32EncodeRgbaSrgbU8(self: *@This(), gpa: Allocator) EncodeRgbaU8Error!void {
    try self.rgbaF32EncodeRgbaU8Ex(gpa, true);
}

fn rgbaF32EncodeRgbaU8Ex(self: *@This(), gpa: Allocator, srgb: bool) EncodeRgbaU8Error!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.assertIsUncompressedRgbaF32();

    const f32s = self.rgbaF32Samples();
    const buf = b: {
        const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });
        defer alloc_zone.end();
        break :b try gpa.alloc(u8, f32s.len);
    };

    {
        const encode_zone = Zone.begin(.{ .name = "encode", .src = @src() });
        defer encode_zone.end();
        for (0..f32s.len) |i| {
            var ldr = f32s[i];
            if (srgb and i % 4 != 3) {
                ldr = std.math.pow(f32, ldr, 1.0 / 2.2);
            }
            ldr = std.math.clamp(ldr * 255.0 + 0.5, 0.0, 255.0);
            buf[i] = @intFromFloat(ldr);
        }
    }

    self.allocator.free(self.rgbaF32Samples());
    self.* = .{
        .width = self.width,
        .height = self.height,
        .hdr = self.hdr,
        .encoding = if (srgb) .rgba_srgb_u8 else .rgba_u8,
        .alpha = self.alpha,
        .uncompressed_byte_length = buf.len,
        .buf = buf,
        .allocator = gpa,
        .supercompression = .none,
    };
}

pub const Bc7Options = struct {
    uber_level: u8 = Bc7Enc.Params.max_uber_level,
    reduce_entropy: bool = false,
    max_partitions_to_scan: u16 = Bc7Enc.Params.max_partitions,
    mode_6_only: bool = false,
    rdo: ?struct {
        lambda: f32 = 0.5,
        lookback_window: ?u17 = null,
        smooth_block_error_scale: ?f32 = 15.0,
        quantize_mode_6_endpoints: bool = true,
        weight_modes: bool = true,
        weight_low_frequency_partitions: bool = true,
        pbit1_weighting: bool = true,
        max_smooth_block_std_dev: f32 = 18.0,
        try_two_matches: bool = true,
        ultrasmooth_block_handling: bool = true,
    },
};

pub const EncodeBc7Error = error{ InvalidOption, EncoderFailed };

pub fn rgbaF32EncodeBc7(
    self: *@This(),
    max_threads: ?u16,
    options: Bc7Options,
) EncodeBc7Error!void {
    try self.encodeBc7Ex(max_threads, false, options);
}

pub fn rgbaF32EncodeBc7Srgb(
    self: *@This(),
    max_threads: ?u16,
    options: Bc7Options,
) EncodeBc7Error!void {
    try self.encodeBc7Ex(max_threads, true, options);
}

fn encodeBc7Ex(
    self: *@This(),
    max_threads: ?u16,
    srgb: bool,
    options: Bc7Options,
) EncodeBc7Error!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (self.encoding != .rgba_f32) @panic("can only encode from rgba-f32");
    if (self.supercompression != .none) @panic("can only encode uncompressed data");

    // Determine the bc7 params
    var params: Bc7Enc.Params = .{};
    {
        const params_zone = Zone.begin(.{ .name = "params", .src = @src() });
        defer params_zone.end();

        if (options.uber_level > Bc7Enc.Params.max_uber_level) {
            log.err("Invalid uber level.", .{});
            return error.InvalidOption;
        }
        params.bc7_uber_level = options.uber_level;

        params.reduce_entropy = options.reduce_entropy;

        if (options.max_partitions_to_scan > Bc7Enc.Params.max_partitions) {
            log.err("Invalid max partitions to scan.", .{});
            return error.InvalidOption;
        }
        params.max_partitions_to_scan = options.max_partitions_to_scan;
        // Ignored when using RDO. However, we use it in our bindings. The actual encoder
        // just clears it so it doesn't matter that we set it regardless.
        params.perceptual = srgb;
        params.mode6_only = options.mode_6_only;

        if (max_threads) |v| {
            if (v == 0) {
                log.err("Invalid max threads.", .{});
                return error.InvalidOption;
            }
            params.rdo_max_threads = v;
        } else {
            params.rdo_max_threads = @intCast(std.math.clamp(
                std.Thread.getCpuCount() catch 1,
                1,
                std.math.maxInt(u32),
            ));
        }
        params.rdo_multithreading = params.rdo_max_threads > 1;

        if (options.rdo) |rdo| {
            if ((rdo.lambda < 0.0) or (rdo.lambda > 500.0)) {
                log.err("Invalid RDO lambda.", .{});
                return error.InvalidOption;
            }
            params.rdo_lambda = rdo.lambda;

            if (rdo.lookback_window) |lookback_window| {
                if (lookback_window < Bc7Enc.Params.min_lookback_window_size) {
                    log.err("Invalid lookback window.", .{});
                    return error.InvalidOption;
                }
                params.lookback_window_size = lookback_window;
                params.custom_lookback_window_size = true;
            }

            if (rdo.smooth_block_error_scale) |v| {
                if ((v < 1.0) or (v > 500.0)) {
                    log.err("Invalid smooth block error scale.", .{});
                    return error.InvalidOption;
                }
                params.rdo_smooth_block_error_scale = v;
                params.custom_rdo_smooth_block_error_scale = true;
            }

            params.rdo_bc7_quant_mode6_endpoints = rdo.quantize_mode_6_endpoints;
            params.rdo_bc7_weight_modes = rdo.weight_modes;
            params.rdo_bc7_weight_low_frequency_partitions = rdo.weight_low_frequency_partitions;
            params.rdo_bc7_pbit1_weighting = rdo.pbit1_weighting;

            if ((rdo.max_smooth_block_std_dev) < 0.000125 or (rdo.max_smooth_block_std_dev > 256.0)) {
                log.err("Invalid smooth block standard deviation.", .{});
                return error.InvalidOption;
            }
            params.rdo_max_smooth_block_std_dev = rdo.max_smooth_block_std_dev;
            params.rdo_try_2_matches = rdo.try_two_matches;
            params.rdo_ultrasmooth_block_handling = rdo.ultrasmooth_block_handling;
        }
    }

    // Encode the image
    const bc7_encoder = b: {
        const init_zone = Zone.begin(.{ .name = "init", .src = @src() });
        defer init_zone.end();
        break :b Bc7Enc.init() orelse return error.EncoderFailed;
    };

    {
        const encode_zone = Zone.begin(.{ .name = "encode", .src = @src() });
        defer encode_zone.end();
        if (!bc7_encoder.encode(&params, self.width, self.height, self.rgbaF32Samples().ptr)) {
            return error.EncoderFailed;
        }
    }

    self.allocator.free(self.rgbaF32Samples());
    const buf = bc7_encoder.getBlocks();
    self.* = .{
        .width = self.width,
        .height = self.height,
        .uncompressed_byte_length = buf.len,
        .buf = buf,
        .encoding = if (srgb) .bc7_srgb else .bc7,
        .alpha = self.alpha,
        .allocator = bc7EncAllocator(bc7_encoder),
        .supercompression = .none,
        .hdr = self.hdr,
    };
}

pub const Bc7Enc = opaque {
    pub const Params = extern struct {
        pub const max_partitions = 64;
        pub const max_uber_level = 4;
        pub const max_level = 18;
        pub const min_lookback_window_size = 8;

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

        pub const DxgiFormat = enum(c_uint) {
            bc7_unorm = 98,
        };

        bc7_uber_level: c_int = max_uber_level,
        max_partitions_to_scan: c_int = max_partitions,
        perceptual: bool = false,
        bc45_channel0: u32 = 0,
        bc45_channel1: u32 = 1,

        bc1_mode: Bc1ApproxMode = .ideal,
        use_bc1_3color_mode: bool = true,

        use_bc1_3color_mode_for_black: bool = true,

        bc1_quality_level: c_int = max_level,

        dxgi_format: DxgiFormat = .bc7_unorm,

        rdo_lambda: f32 = 0.0,
        rdo_debug_output: bool = false,
        rdo_smooth_block_error_scale: f32 = 15.0,
        custom_rdo_smooth_block_error_scale: bool = false,
        lookback_window_size: u32 = 128,
        custom_lookback_window_size: bool = false,
        rdo_bc7_quant_mode6_endpoints: bool = true,
        rdo_bc7_weight_modes: bool = true,
        rdo_bc7_weight_low_frequency_partitions: bool = true,
        rdo_bc7_pbit1_weighting: bool = true,
        rdo_max_smooth_block_std_dev: f32 = 18.0,
        rdo_allow_relative_movement: bool = false,
        rdo_try_2_matches: bool = true,
        rdo_ultrasmooth_block_handling: bool = true,

        use_hq_bc345: bool = true,
        bc345_search_rad: c_int = 5,
        bc345_mode_mask: Bc345ModeMask = Bc345ModeMask.bc4_use_all_modes,

        mode6_only: bool = false,
        rdo_multithreading: bool = true,

        reduce_entropy: bool = false,

        m_use_bc7e: bool = false,
        status_output: bool = false,

        rdo_max_threads: u32 = 128,
    };

    pub const init = bc7enc_init;
    pub const deinit = bc7enc_deinit;
    pub const encode = bc7enc_encode;
    pub fn getBlocks(self: *@This()) []u8 {
        const bytes = bc7enc_getTotalBlocksSizeInBytes(self);
        return bc7enc_getBlocks(self)[0..bytes];
    }

    extern fn bc7enc_init() callconv(.c) ?*@This();
    extern fn bc7enc_deinit(self: *@This()) callconv(.c) void;
    extern fn bc7enc_encode(
        self: *@This(),
        params: *const Params,
        width: u32,
        height: u32,
        pixels: [*]const f32,
    ) callconv(.c) bool;
    extern fn bc7enc_getBlocks(self: *@This()) callconv(.c) [*]u8;
    extern fn bc7enc_getTotalBlocksSizeInBytes(self: *@This()) callconv(.c) u32;
};

pub const CompressZlibOptions = union(enum) {
    /// Only levels matching what Zig's std could previously handle are supported so we have the
    /// option to switch back to the std implementation when it's re-implemented.
    pub const Level = enum(u4) {
        @"4" = 4,
        @"5" = 5,
        @"6" = 6,
        @"7" = 7,
        @"8" = 8,
        @"9" = 9,
    };

    level: Level,
};

// XXX: make helper that dispatches to given one? don't think that's needed, remove from encode too?
pub const CompressZlibError = Allocator.Error || std.Io.Writer.Error;

pub fn compressZlib(
    self: *@This(),
    gpa: Allocator,
    options: CompressZlibOptions,
) CompressZlibError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (self.supercompression != .none) std.debug.panic("expected {} found {}", .{
        Ktx2.Header.SupercompressionScheme.none,
        self.supercompression,
    });

    const zlib_zone = Zone.begin(.{ .name = "zlib", .src = @src() });
    defer zlib_zone.end();

    var compressed_len = c.compressBound(self.buf.len);

    var compressed = b: {
        const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });
        defer alloc_zone.end();
        // XXX: can we start renaming these to ArrayList? infer type here?
        break :b try std.ArrayList(u8).initCapacity(gpa, compressed_len);
    };
    defer compressed.deinit(gpa);

    switch (c.compress2(
        compressed.items.ptr,
        &compressed_len,
        self.buf.ptr,
        self.buf.len,
        @intFromEnum(options.level),
    )) {
        c.Z_OK => {},
        c.Z_STREAM_END => @panic("Z_STREAM_END"),
        c.Z_NEED_DICT => @panic("Z_NEED_DICT"),
        c.Z_ERRNO => @panic("Z_ERRNO"),
        c.Z_STREAM_ERROR => @panic("Z_STREAM_ERROR"),
        c.Z_DATA_ERROR => @panic("Z_DATA_ERROR"),
        c.Z_MEM_ERROR => @panic("Z_MEM_ERROR"),
        c.Z_BUF_ERROR => @panic("Z_BUF_ERROR"),
        c.Z_VERSION_ERROR => @panic("Z_VERSION_ERROR"),
        else => |n| std.debug.panic("unknown zlib error: {}", .{n}),
    }
    compressed.items.len = compressed_len;

    const original = self.*; // XXX: annoying needing to do this
    self.deinit();
    self.* = .{
        .width = original.width,
        .height = original.height,
        .uncompressed_byte_length = original.uncompressed_byte_length,
        .buf = b: {
            const to_owned_zone = Zone.begin(.{ .name = "toOwnedSlice", .src = @src() });
            defer to_owned_zone.end();
            break :b try compressed.toOwnedSlice(gpa);
        },
        .hdr = original.hdr,
        .encoding = original.encoding,
        .alpha = original.alpha,
        .supercompression = .zlib,
        .allocator = gpa,
    };
}

fn remapNoop(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn unsupportedAlloc(
    ctx: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = len;
    _ = alignment;
    _ = ret_addr;
    @panic("unsupported");
}

fn unsupportedResize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    @panic("unsupported");
}

fn stbFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    c.stbi_image_free(buf.ptr);
}

fn movedFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    _ = buf;
}

const stb_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &unsupportedAlloc,
        .resize = &unsupportedResize,
        .free = &stbFree,
        .remap = &remapNoop,
    },
};

const moved_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &unsupportedAlloc,
        .resize = &unsupportedResize,
        .free = &movedFree,
        .remap = &remapNoop,
    },
};

fn bc7EncFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    _ = buf;
    const bc7_encoder: *Bc7Enc = @ptrCast(ctx);
    bc7_encoder.deinit();
}

fn bc7EncAllocator(bc7_encoder: *Bc7Enc) Allocator {
    return .{
        .ptr = bc7_encoder,
        .vtable = &.{
            .alloc = &unsupportedAlloc,
            .resize = &unsupportedResize,
            .free = &bc7EncFree,
            .remap = &remapNoop,
        },
    };
}
