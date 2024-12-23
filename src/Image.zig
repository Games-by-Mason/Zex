const std = @import("std");
const log = std.log;
const c = @import("c.zig");

const Image = @This();

width: u32,
height: u32,
data: []f32,
hdr: bool,

pub const InitError = error{
    StbImageFailure,
    LdrAsHdr,
};

pub const InitOptions = struct {
    pub const ColorSpace = enum(c_uint) {
        linear,
        srgb,
        hdr,
    };

    bytes: []const u8,
    color_space: @This().ColorSpace,
};

pub fn init(options: InitOptions) InitError!Image {
    // Check if the input is HDR
    const hdr = c.stbi_is_hdr_from_memory(
        options.bytes.ptr,
        @intCast(options.bytes.len),
    ) == 1;

    // Don't allow upsampling LDR to HDR
    switch (options.color_space) {
        .linear, .srgb => {},
        .hdr => if (!hdr) return error.LdrAsHdr,
    }

    // All images are loaded as linear floats regardless of the source and dest formats.
    //
    // Rational:
    // - Increases precision of any manipulations done to the image (e.g. repeated downsampling
    //   for mipmap generation)
    // - Saves us from having separate branches for LDR and HDR processing
    //
    // There's no technical benefit in the case where no processing is done, but this is not the
    // common case.
    c.stbi_ldr_to_hdr_gamma(switch (options.color_space) {
        .srgb => 2.2,
        .linear, .hdr => 1.0,
    });
    var width: c_int = 0;
    var height: c_int = 0;
    var input_channels: c_int = 0;
    const data_ptr = c.stbi_loadf_from_memory(
        options.bytes.ptr,
        @intCast(options.bytes.len),
        &width,
        &height,
        &input_channels,
        4,
    ) orelse return error.StbImageFailure;

    // Create the image
    const data_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .data = data_ptr[0..data_len],
        .hdr = hdr,
    };
}

pub fn deinit(self: Image) void {
    c.stbi_image_free(self.data.ptr);
}

pub fn premultiply(self: Image) void {
    var px: usize = 0;
    while (px < @as(usize, self.width) * @as(usize, self.height) * 4) : (px += 4) {
        const a = self.data[px + 3];
        self.data[px + 0] = self.data[px + 0] * a;
        self.data[px + 1] = self.data[px + 1] * a;
        self.data[px + 2] = self.data[px + 2] * a;
    }
}

pub fn copy(self: Image) ?Image {
    const data_ptr: [*]f32 = @ptrCast(@alignCast(c.malloc(
        self.data.len * @sizeOf(f32),
    ) orelse return null));
    const data = data_ptr[0..self.data.len];
    @memcpy(data, self.data);
    return .{
        .width = self.width,
        .height = self.height,
        .data = data,
        .hdr = self.hdr,
    };
}

pub const ResizeOptions = struct {
    pub const AddressMode = enum(c_uint) {
        clamp = c.STBIR_EDGE_CLAMP,
        reflect = c.STBIR_EDGE_REFLECT,
        wrap = c.STBIR_EDGE_WRAP,
        zero = c.STBIR_EDGE_ZERO,
    };

    pub const Filter = enum(c_uint) {
        box = c.STBIR_FILTER_BOX,
        triangle = c.STBIR_FILTER_TRIANGLE,
        @"cubic-b-spline" = c.STBIR_FILTER_CUBICBSPLINE,
        @"catmull-rom" = c.STBIR_FILTER_CATMULLROM,
        mitchell = c.STBIR_FILTER_MITCHELL,
        @"point-sample" = c.STBIR_FILTER_POINT_SAMPLE,

        pub fn sharpens(self: @This()) bool {
            return switch (self) {
                .box, .triangle, .@"point-sample", .@"cubic-b-spline" => false,
                .mitchell, .@"catmull-rom" => true,
            };
        }
    };

    width: u32,
    height: u32,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    filter_u: Filter,
    filter_v: Filter,
};

pub fn resize(self: Image, options: ResizeOptions) ?Image {
    if (options.width == 0 or options.height == 0) return null;
    if (options.width == self.width and options.height == self.height) return self.copy();

    const output_samples = @as(usize, options.width) * @as(usize, options.height) * 4;
    const data_ptr: [*]f32 = @ptrCast(@alignCast(c.malloc(
        output_samples * @sizeOf(f32),
    ) orelse return null));
    const data = data_ptr[0..output_samples];

    var stbr_options: c.STBIR_RESIZE = undefined;
    c.stbir_resize_init(
        &stbr_options,
        self.data.ptr,
        @intCast(self.width),
        @intCast(self.height),
        0,
        data.ptr,
        @intCast(options.width),
        @intCast(options.height),
        0,
        // We always premultiply alpha channels ourselves if they represent transparency
        c.STBIR_RGBA_PM,
        c.STBIR_TYPE_FLOAT,
    );

    stbr_options.horizontal_edge = @intFromEnum(options.address_mode_u);
    stbr_options.vertical_edge = @intFromEnum(options.address_mode_v);
    stbr_options.horizontal_filter = @intFromEnum(options.filter_u);
    stbr_options.vertical_filter = @intFromEnum(options.filter_v);

    if (c.stbir_resize_extended(&stbr_options) != 1) {
        c.free(data.ptr);
        return null;
    }

    // Sharpening filters can push values below zero. Clamp them before doing further processing.
    // We could alternatively use `STBIR_FLOAT_LOW_CLAMP`, see issue #18.
    if (options.filter_u.sharpens() or options.filter_v.sharpens()) {
        for (data) |*d| {
            d.* = @max(d.*, 0.0);
        }
    }

    return .{
        .width = options.width,
        .height = options.height,
        .data = data,
        .hdr = self.hdr,
    };
}

pub fn alphaCoverage(self: Image, threshold: f32, scale: f32) f32 {
    var coverage: f32 = 0;
    for (0..@as(usize, self.width) * @as(usize, self.height)) |i| {
        const alpha = self.data[i * 4 + 3];
        if (alpha * scale > threshold) coverage += 1.0;
    }
    coverage /= @floatFromInt(@as(usize, self.width) * @as(usize, self.height));
    return coverage;
}

pub const GenerateMipMapsOptions = struct {
    block_size: u8,
    address_mode_u: ResizeOptions.AddressMode,
    address_mode_v: ResizeOptions.AddressMode,
    filter_u: ResizeOptions.Filter,
    filter_v: ResizeOptions.Filter,
};

pub fn generateMipmaps(self: Image, options: GenerateMipMapsOptions) GenerateMipmaps {
    return .{
        .options = options,
        .image = self,
    };
}

pub const GenerateMipmaps = struct {
    options: GenerateMipMapsOptions,
    image: Image,

    pub fn next(self: *@This()) ?Image {
        // Stop once we're below the block size, there's no benefit to further mipmaps
        if (self.image.width <= self.options.block_size and
            self.image.height <= self.options.block_size)
        {
            return null;
        }

        // Halve the image size
        self.image = self.image.resize(.{
            .width = @max(1, self.image.width / 2),
            .height = @max(1, self.image.height / 2),
            .address_mode_u = self.options.address_mode_u,
            .address_mode_v = self.options.address_mode_v,
            .filter_u = self.options.filter_u,
            .filter_v = self.options.filter_v,
        }) orelse {
            log.err("mipmap generation failed", .{});
            std.process.exit(1);
        };
        return self.image;
    }
};
