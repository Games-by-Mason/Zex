const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const Ktx2 = @import("Ktx2");
const Image = @import("Image.zig");
const Texture = @This();
const Allocator = std.mem.Allocator;

pub const capacity = Ktx2.max_levels;

buf: [capacity]Image = undefined,
len: u8 = 0,

comptime {
    assert(std.math.maxInt(@FieldType(@This(), "len")) >= capacity);
}

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

/// High level helper for texture creation. Feel free to fork this function into your codebase if
/// you need to customize it further, it only calls into the public API.
pub fn init(gpa: Allocator, input: *std.Io.Reader, options: Options) !@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Create the texture
    var texture: Texture = .{};
    errdefer texture.deinit();

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

    return texture;
}

pub fn deinit(self: *@This()) void {
    for (self.levels()) |*compressed_level| {
        compressed_level.deinit();
    }
    self.* = undefined;
}

pub fn appendLevel(self: *@This(), level: Image) error{OutOfBounds}!void {
    if (capacity - self.len == 0) return error.OutOfBounds;
    self.buf[self.len] = level;
    self.len += 1;
}

pub fn levels(self: *@This()) []Image {
    return @constCast(self.levelsConst());
}

pub fn levelsConst(self: *const @This()) []const Image {
    return self.buf[0..self.len];
}

pub const GenerateMipMapsOptions = struct {
    address_mode_u: Image.AddressMode,
    address_mode_v: Image.AddressMode,
    filter: Image.Filter = .mitchell,
    filter_u: ?Image.Filter = null,
    filter_v: ?Image.Filter = null,
    block_size: u8,

    fn filterU(self: @This()) Image.Filter {
        return self.filter_u orelse self.filter;
    }

    fn filterV(self: @This()) Image.Filter {
        return self.filter_v orelse self.filter;
    }
};

pub fn rgbaF32GenerateMipmaps(self: *@This(), options: GenerateMipMapsOptions) Image.ResizeError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (self.len != 1) @panic("generate mipmaps requires exactly one level");
    const source = self.levels()[0];
    source.assertIsUncompressedRgbaF32();

    var generate_mipmaps = source.rgbaF32GenerateMipmaps(.{
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filterU(),
        .filter_v = options.filterV(),
        .block_size = options.block_size,
    });

    while (try generate_mipmaps.next()) |mipmap| {
        self.appendLevel(mipmap) catch @panic("OOB");
    }
}

pub fn rgbaF32Encode(
    self: *@This(),
    gpa: std.mem.Allocator,
    max_threads: ?u16,
    options: Image.EncodeOptions,
) Image.EncodeError!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    for (self.levels()) |*slice| {
        try slice.rgbaF32Encode(gpa, max_threads, options);
    }
}

pub fn compressZlib(
    self: *@This(),
    allocator: std.mem.Allocator,
    options: Image.CompressZlibOptions,
) Image.CompressZlibError!void {
    for (self.levels()) |*level| {
        try level.compressZlib(allocator, options);
    }
}

pub fn writeKtx2(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    assert(self.len > 0);
    const first_level = self.levelsConst()[0];
    const encoding = first_level.encoding;
    const supercompression = first_level.supercompression;
    const premultiplied = first_level.premultiplied;
    {
        var level_width = first_level.width;
        var level_height = first_level.height;
        for (self.levelsConst()) |level| {
            assert(level.encoding == encoding);
            assert(level.supercompression == supercompression);
            assert(level.premultiplied == premultiplied);
            const block_size = level.encoding.blockSize();
            assert(level.width >= block_size and level.height >= block_size);
            assert(level.width == level_width);
            assert(level.height == level_height);

            level_width = @max(1, level_width / 2);
            level_height = @max(1, level_height / 2);
        }
    }

    // Serialization assumes little endian
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Write the header
    const samples = encoding.samples();
    const index = Ktx2.Header.Index.init(.{
        .levels = self.len,
        .samples = samples,
    });
    {
        const header_zone = Zone.begin(.{ .name = "header", .src = @src() });
        defer header_zone.end();
        try writer.writeStruct(Ktx2.Header{
            .format = encoding.vkFormat(),
            .type_size = encoding.typeSize(),
            .pixel_width = first_level.width,
            .pixel_height = first_level.height,
            .pixel_depth = 0,
            .layer_count = 0,
            .face_count = 1,
            .level_count = .fromInt(self.len),
            .supercompression_scheme = supercompression,
            .index = index,
        }, .little);
    }

    // Write the level index
    const level_alignment: u8 = if (supercompression != .none) 1 else switch (encoding) {
        .r8g8b8a8_unorm, .r8g8b8a8_srgb => 4,
        .r32g32b32_sfloat => 16,
        .bc7_unorm_block, .bc7_srgb_block => 16,
    };
    {
        const level_index_zone = Zone.begin(.{ .name = "level index", .src = @src() });
        defer level_index_zone.end();

        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse_buf: [Ktx2.max_levels]usize = undefined;
        var byte_offsets_reverse: std.ArrayList(usize) = .initBuffer(&byte_offsets_reverse_buf);
        {
            var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..self.len) |i| {
                byte_offset = std.mem.alignForward(usize, byte_offset, level_alignment);
                const compressed_level = self.levelsConst()[self.len - i - 1];
                byte_offsets_reverse.appendBounded(byte_offset) catch @panic("OOB");
                byte_offset += compressed_level.buf.len;
            }
        }

        // Write the level index data, this is done from largest to smallest, only the actual data
        // is stored in reverse order.
        for (self.levelsConst(), 0..) |level, i| {
            try writer.writeStruct(Ktx2.Level{
                .byte_offset = byte_offsets_reverse.items[self.len - i - 1],
                .byte_length = level.buf.len,
                .uncompressed_byte_length = level.uncompressed_byte_length,
            }, .little);
        }
    }

    // Write the data descriptor
    {
        const dfd_zone = Zone.begin(.{ .name = "dfd", .src = @src() });
        defer dfd_zone.end();

        try writer.writeInt(u32, index.dfd_byte_length, .little);
        try writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock{
            .descriptor_block_size = Ktx2.BasicDescriptorBlock.descriptorBlockSize(samples),
            .model = switch (encoding) {
                .r8g8b8a8_unorm, .r8g8b8a8_srgb, .r32g32b32_sfloat => .rgbsda,
                .bc7_unorm_block, .bc7_srgb_block => .bc7,
            },
            .primaries = .bt709,
            .transfer = switch (encoding.colorSpace()) {
                .linear, .hdr => .linear,
                .srgb => .srgb,
            },
            .flags = .{
                .alpha_premultiplied = premultiplied,
            },
            .texel_block_dimension_0 = .fromInt(encoding.blockSize()),
            .texel_block_dimension_1 = .fromInt(encoding.blockSize()),
            .texel_block_dimension_2 = .fromInt(1),
            .texel_block_dimension_3 = .fromInt(1),
            .bytes_plane_0 = if (supercompression != .none) 0 else switch (encoding) {
                .r8g8b8a8_unorm, .r8g8b8a8_srgb => 4,
                .r32g32b32_sfloat => 16,
                .bc7_unorm_block, .bc7_srgb_block => 16,
            },
            .bytes_plane_1 = 0,
            .bytes_plane_2 = 0,
            .bytes_plane_3 = 0,
            .bytes_plane_4 = 0,
            .bytes_plane_5 = 0,
            .bytes_plane_6 = 0,
            .bytes_plane_7 = 0,
        })[0 .. @bitSizeOf(Ktx2.BasicDescriptorBlock) / 8]);
        switch (encoding) {
            .r8g8b8a8_unorm, .r8g8b8a8_srgb => for (0..4) |i| {
                const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                    .bit_offset = .fromInt(8 * @as(u16, @intCast(i))),
                    .bit_length = .fromInt(8),
                    .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                    .linear = switch (encoding.colorSpace()) {
                        .linear, .hdr => false,
                        .srgb => i == 3,
                    },
                    .exponent = false,
                    .signed = false,
                    .float = false,
                    .sample_position_0 = 0,
                    .sample_position_1 = 0,
                    .sample_position_2 = 0,
                    .sample_position_3 = 0,
                    .lower = 0,
                    .upper = switch (encoding.colorSpace()) {
                        .hdr => 1,
                        .srgb, .linear => 255,
                    },
                })) catch unreachable;
            },
            .r32g32b32_sfloat => for (0..4) |i| {
                const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.rgbsda);
                const channel_type: ChannelType = if (i == 3) .alpha else @enumFromInt(i);
                writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                    .bit_offset = .fromInt(32 * @as(u16, @intCast(i))),
                    .bit_length = .fromInt(32),
                    .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                    .linear = false,
                    .exponent = false,
                    .signed = true,
                    .float = true,
                    .sample_position_0 = 0,
                    .sample_position_1 = 0,
                    .sample_position_2 = 0,
                    .sample_position_3 = 0,
                    .lower = @bitCast(@as(f32, -1.0)),
                    .upper = @bitCast(@as(f32, 1.0)),
                })) catch unreachable;
            },
            .bc7_unorm_block, .bc7_srgb_block => {
                const ChannelType = Ktx2.BasicDescriptorBlock.Sample.ChannelType(.bc7);
                const channel_type: ChannelType = .data;
                writer.writeAll(std.mem.asBytes(&Ktx2.BasicDescriptorBlock.Sample{
                    .bit_offset = .fromInt(0),
                    .bit_length = .fromInt(128),
                    .channel_type = @enumFromInt(@intFromEnum(channel_type)),
                    .linear = false,
                    .exponent = false,
                    .signed = false,
                    .float = false,
                    .sample_position_0 = 0,
                    .sample_position_1 = 0,
                    .sample_position_2 = 0,
                    .sample_position_3 = 0,
                    .lower = 0,
                    .upper = std.math.maxInt(u32),
                })) catch unreachable;
            },
        }
    }

    // Write the compressed level data. Note that KTX2 requires mips be stored form smallest to
    // largest for streaming purposes.
    {
        const level_data = Zone.begin(.{ .name = "level data", .src = @src() });
        defer level_data.end();

        var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
        for (0..self.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(usize, byte_offset, level_alignment);
            try writer.splatByteAll(0, padded - byte_offset);
            byte_offset = padded;

            // Write the level
            const compressed_level = self.levelsConst()[self.len - i - 1];
            try writer.writeAll(compressed_level.buf);
            byte_offset += compressed_level.buf.len;
        }
    }

    try writer.flush();
}
