const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const Ktx2 = @import("Ktx2");
const Image = @import("Image.zig");
const Texture = @This();

levels: std.BoundedArray(Image, Ktx2.max_levels) = .{},

pub fn deinit(self: *@This()) void {
    for (self.levels.slice()) |*compressed_level| {
        compressed_level.deinit();
    }
    self.* = undefined;
}

pub const GenerateMipMapsOptions = struct {
    address_mode_u: Image.AddressMode,
    address_mode_v: Image.AddressMode,
    filter: Image.Filter = .mitchell,
    filter_u: ?Image.Filter = null,
    filter_v: ?Image.Filter = null,
    // XXX: allow limiting count, and calculating optimal count for final encoding instead?
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

    if (self.levels.len != 1) @panic("generate mipmaps requires exactly one level");
    const source = self.levels.get(0);
    source.assertIsUncompressedRgbaF32();

    // XXX: do we really need this iterator to be built into image?
    var generate_mipmaps = source.rgbaF32GenerateMipmaps(.{
        .address_mode_u = options.address_mode_u,
        .address_mode_v = options.address_mode_v,
        .filter_u = options.filterU(),
        .filter_v = options.filterV(),
        .block_size = options.block_size,
    });

    while (try generate_mipmaps.next()) |mipmap| {
        self.levels.appendAssumeCapacity(mipmap);
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
    for (self.levels.slice()) |*slice| {
        try slice.rgbaF32Encode(gpa, max_threads, options);
    }
}

pub fn compressZlib(
    self: *@This(),
    allocator: std.mem.Allocator,
    options: Image.CompressZlibOptions,
) Image.CompressZlibError!void {
    for (self.levels.slice()) |*level| {
        try level.compressZlib(allocator, options);
    }
}

// XXX: assert levels are right size, and encoded/compressed the same way, document
pub fn writeKtx2(self: @This(), writer: anytype) @TypeOf(writer).Error!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    assert(self.levels.len > 0);
    const first_level = self.levels.get(0);
    const encoding = first_level.encoding;
    const supercompression = first_level.supercompression;
    const premultiplied = first_level.alpha.premultiplied();
    {
        var level_width = first_level.width;
        var level_height = first_level.height;
        for (self.levels.constSlice()) |level| {
            // XXX: be consistent with panics vs asserts, may want to use panics here so that we can do
            // release fast to elide expensive in loop checks but still check cheap interface guarantees
            assert(level.encoding == encoding);
            assert(level.supercompression == supercompression);
            assert(level.alpha.premultiplied() == premultiplied);
            assert(level.width == level_width);
            assert(level.height == level_height);
            // XXX: check against block size?
            assert(level.width > 0 and level.height > 0);

            level_width /= 2;
            level_height /= 2;
        }
    }

    // Serialization assumes little endian
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Write the header
    const samples = encoding.samples();
    const index = Ktx2.Header.Index.init(.{
        .levels = @intCast(self.levels.len),
        .samples = samples,
    });
    {
        const header_zone = Zone.begin(.{ .name = "header", .src = @src() });
        defer header_zone.end();
        try writer.writeStruct(Ktx2.Header{
            .format = switch (encoding) {
                .rgba_u8 => .r8g8b8a8_uint,
                .rgba_srgb_u8 => .r8g8b8a8_srgb,
                .rgba_f32 => .r32g32b32a32_sfloat,
                .bc7 => .bc7_unorm_block,
                .bc7_srgb => .bc7_srgb_block,
            },
            .type_size = encoding.typeSize(),
            .pixel_width = first_level.width,
            .pixel_height = first_level.height,
            .pixel_depth = 0,
            .layer_count = 0,
            .face_count = 1,
            .level_count = .fromInt(@intCast(self.levels.len)),
            .supercompression_scheme = supercompression,
            .index = index,
        });
    }

    // Write the level index
    const level_alignment: u8 = if (supercompression != .none) 1 else switch (encoding) {
        .rgba_u8, .rgba_srgb_u8 => 4,
        .rgba_f32 => 16,
        .bc7, .bc7_srgb => 16,
    };
    {
        const level_index_zone = Zone.begin(.{ .name = "level index", .src = @src() });
        defer level_index_zone.end();

        // Calculate the byte offsets, taking into account that KTX2 requires mipmaps be stored from
        // largest to smallest for streaming purposes
        var byte_offsets_reverse: std.BoundedArray(usize, Ktx2.max_levels) = .{};
        {
            var byte_offset: usize = index.dfd_byte_offset + index.dfd_byte_length;
            for (0..self.levels.len) |i| {
                byte_offset = std.mem.alignForward(usize, byte_offset, level_alignment);
                const compressed_level = self.levels.get(self.levels.len - i - 1);
                byte_offsets_reverse.appendAssumeCapacity(byte_offset);
                byte_offset += compressed_level.buf.len;
            }
        }

        // Write the level index data, this is done from largest to smallest, only the actual data
        // is stored in reverse order.
        for (0..self.levels.len) |i| {
            try writer.writeStruct(Ktx2.Level{
                .byte_offset = byte_offsets_reverse.get(self.levels.len - i - 1),
                .byte_length = self.levels.get(i).buf.len,
                .uncompressed_byte_length = self.levels.get(i).uncompressed_byte_length,
            });
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
                .rgba_u8, .rgba_srgb_u8, .rgba_f32 => .rgbsda,
                .bc7, .bc7_srgb => .bc7,
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
                .rgba_u8, .rgba_srgb_u8 => 4,
                .rgba_f32 => 16,
                .bc7, .bc7_srgb => 16,
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
            .rgba_u8, .rgba_srgb_u8 => for (0..4) |i| {
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
            .rgba_f32 => for (0..4) |i| {
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
            .bc7, .bc7_srgb => {
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
        for (0..self.levels.len) |i| {
            // Write padding
            const padded = std.mem.alignForward(usize, byte_offset, level_alignment);
            try writer.writeByteNTimes(0, padded - byte_offset);
            byte_offset = padded;

            // Write the level
            const compressed_level = self.levels.get(self.levels.len - i - 1);
            try writer.writeAll(compressed_level.buf);
            byte_offset += compressed_level.buf.len;
        }
    }
}
