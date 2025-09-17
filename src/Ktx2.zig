const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

header: *align(1) const Header,
levels: []align(1) const Level,
basic_descriptor_block: *align(1) const BasicDescriptorBlock,
samples: []align(1) const BasicDescriptorBlock.Sample,
key_value_data: []const u8,
supercompression_global_data: []const u8,

const Error = error{
    /// The KTX2 file is malformed.
    InvalidKtx2,
    /// The KTX2 file may be correct, but violates a Khronos recommendation in such a way that makes
    /// it unnecessarily difficult to parse.
    UnsupportedKtx2,
};

pub const Header = extern struct {
    identifier: [12]u8 = identifier,
    format: VkFormat,
    type_size: u32,
    pixel_width: u32,
    pixel_height: u32,
    pixel_depth: u32,
    layer_count: u32,
    face_count: u32,
    level_count: LevelCount,
    supercompression_scheme: SupercompressionScheme,
    index: Index,

    pub const VkFormat = enum(u32) {
        undefined = 0,
        r4g4_unorm_pack8 = 1,
        r4g4b4a4_unorm_pack16 = 2,
        b4g4r4a4_unorm_pack16 = 3,
        r5g6b5_unorm_pack16 = 4,
        b5g6r5_unorm_pack16 = 5,
        r5g5b5a1_unorm_pack16 = 6,
        b5g5r5a1_unorm_pack16 = 7,
        a1r5g5b5_unorm_pack16 = 8,
        r8_unorm = 9,
        r8_snorm = 10,
        r8_uint = 13,
        r8_sint = 14,
        r8_srgb = 15,
        r8g8_unorm = 16,
        r8g8_snorm = 17,
        r8g8_uint = 20,
        r8g8_sint = 21,
        r8g8_srgb = 22,
        r8g8b8_unorm = 23,
        r8g8b8_snorm = 24,
        r8g8b8_uint = 27,
        r8g8b8_sint = 28,
        r8g8b8_srgb = 29,
        b8g8r8_unorm = 30,
        b8g8r8_snorm = 31,
        b8g8r8_uint = 34,
        b8g8r8_sint = 35,
        b8g8r8_srgb = 36,
        r8g8b8a8_unorm = 37,
        r8g8b8a8_snorm = 38,
        r8g8b8a8_uint = 41,
        r8g8b8a8_sint = 42,
        r8g8b8a8_srgb = 43,
        b8g8r8a8_unorm = 44,
        b8g8r8a8_snorm = 45,
        b8g8r8a8_uint = 48,
        b8g8r8a8_sint = 49,
        b8g8r8a8_srgb = 50,
        a8b8g8r8_unorm_pack32 = 51,
        a8b8g8r8_snorm_pack32 = 52,
        a8b8g8r8_uint_pack32 = 55,
        a8b8g8r8_sint_pack32 = 56,
        a8b8g8r8_srgb_pack32 = 57,
        a2r10g10b10_unorm_pack32 = 58,
        a2r10g10b10_snorm_pack32 = 59,
        a2r10g10b10_uint_pack32 = 62,
        a2r10g10b10_sint_pack32 = 63,
        a2b10g10r10_unorm_pack32 = 64,
        a2b10g10r10_snorm_pack32 = 65,
        a2b10g10r10_uint_pack32 = 68,
        a2b10g10r10_sint_pack32 = 69,
        r16_unorm = 70,
        r16_snorm = 71,
        r16_uint = 74,
        r16_sint = 75,
        r16_sfloat = 76,
        r16g16_unorm = 77,
        r16g16_snorm = 78,
        r16g16_uint = 81,
        r16g16_sint = 82,
        r16g16_sfloat = 83,
        r16g16b16_unorm = 84,
        r16g16b16_snorm = 85,
        r16g16b16_uint = 88,
        r16g16b16_sint = 89,
        r16g16b16_sfloat = 90,
        r16g16b16a16_unorm = 91,
        r16g16b16a16_snorm = 92,
        r16g16b16a16_uint = 95,
        r16g16b16a16_sint = 96,
        r16g16b16a16_sfloat = 97,
        r32_uint = 98,
        r32_sint = 99,
        r32_sfloat = 100,
        r32g32_uint = 101,
        r32g32_sint = 102,
        r32g32_sfloat = 103,
        r32g32b32_uint = 104,
        r32g32b32_sint = 105,
        r32g32b32_sfloat = 106,
        r32g32b32a32_uint = 107,
        r32g32b32a32_sint = 108,
        r32g32b32a32_sfloat = 109,
        r64_uint = 110,
        r64_sint = 111,
        r64_sfloat = 112,
        r64g64_uint = 113,
        r64g64_sint = 114,
        r64g64_sfloat = 115,
        r64g64b64_uint = 116,
        r64g64b64_sint = 117,
        r64g64b64_sfloat = 118,
        r64g64b64a64_uint = 119,
        r64g64b64a64_sint = 120,
        r64g64b64a64_sfloat = 121,
        b10g11r11_ufloat_pack32 = 122,
        e5b9g9r9_ufloat_pack32 = 123,
        d16_unorm = 124,
        x8_d24_unorm_pack32 = 125,
        d32_sfloat = 126,
        s8_uint = 127,
        d16_unorm_s8_uint = 128,
        d24_unorm_s8_uint = 129,
        d32_sfloat_s8_uint = 130,
        bc1_rgb_unorm_block = 131,
        bc1_rgb_srgb_block = 132,
        bc1_rgba_unorm_block = 133,
        bc1_rgba_srgb_block = 134,
        bc2_unorm_block = 135,
        bc2_srgb_block = 136,
        bc3_unorm_block = 137,
        bc3_srgb_block = 138,
        bc4_unorm_block = 139,
        bc4_snorm_block = 140,
        bc5_unorm_block = 141,
        bc5_snorm_block = 142,
        bc6h_ufloat_block = 143,
        bc6h_sfloat_block = 144,
        bc7_unorm_block = 145,
        bc7_srgb_block = 146,
        etc2_r8g8b8_unorm_block = 147,
        etc2_r8g8b8_srgb_block = 148,
        etc2_r8g8b8a1_unorm_block = 149,
        etc2_r8g8b8a1_srgb_block = 150,
        etc2_r8g8b8a8_unorm_block = 151,
        etc2_r8g8b8a8_srgb_block = 152,
        eac_r11_unorm_block = 153,
        eac_r11_snorm_block = 154,
        eac_r11g11_unorm_block = 155,
        eac_r11g11_snorm_block = 156,
        astc_4x4_unorm_block = 157,
        astc_4x4_srgb_block = 158,
        astc_5x4_unorm_block = 159,
        astc_5x4_srgb_block = 160,
        astc_5x5_unorm_block = 161,
        astc_5x5_srgb_block = 162,
        astc_6x5_unorm_block = 163,
        astc_6x5_srgb_block = 164,
        astc_6x6_unorm_block = 165,
        astc_6x6_srgb_block = 166,
        astc_8x5_unorm_block = 167,
        astc_8x5_srgb_block = 168,
        astc_8x6_unorm_block = 169,
        astc_8x6_srgb_block = 170,
        astc_8x8_unorm_block = 171,
        astc_8x8_srgb_block = 172,
        astc_10x5_unorm_block = 173,
        astc_10x5_srgb_block = 174,
        astc_10x6_unorm_block = 175,
        astc_10x6_srgb_block = 176,
        astc_10x8_unorm_block = 177,
        astc_10x8_srgb_block = 178,
        astc_10x10_unorm_block = 179,
        astc_10x10_srgb_block = 180,
        astc_12x10_unorm_block = 181,
        astc_12x10_srgb_block = 182,
        astc_12x12_unorm_block = 183,
        astc_12x12_srgb_block = 184,
        g8b8g8r8_422_unorm = 1000156000,
        b8g8r8g8_422_unorm = 1000156001,
        r10x6_unorm_pack16 = 1000156007,
        r10x6g10x6_unorm_2pack16 = 1000156008,
        r10x6g10x6b10x6a10x6_unorm_4pack16 = 1000156009,
        g10x6b10x6g10x6r10x6_422_unorm_4pack16 = 1000156010,
        b10x6g10x6r10x6g10x6_422_unorm_4pack16 = 1000156011,
        r12x4_unorm_pack16 = 1000156017,
        r12x4g12x4_unorm_2pack16 = 1000156018,
        r12x4g12x4b12x4a12x4_unorm_4pack16 = 1000156019,
        g12x4b12x4g12x4r12x4_422_unorm_4pack16 = 1000156020,
        b12x4g12x4r12x4g12x4_422_unorm_4pack16 = 1000156021,
        g16b16g16r16_422_unorm = 1000156027,
        b16g16r16g16_422_unorm = 1000156028,
        a4r4g4b4_unorm_pack16 = 1000340000,
        a4b4g4r4_unorm_pack16 = 1000340001,
        astc_4x4_sfloat_block = 1000066000,
        astc_5x4_sfloat_block = 1000066001,
        astc_5x5_sfloat_block = 1000066002,
        astc_6x5_sfloat_block = 1000066003,
        astc_6x6_sfloat_block = 1000066004,
        astc_8x5_sfloat_block = 1000066005,
        astc_8x6_sfloat_block = 1000066006,
        astc_8x8_sfloat_block = 1000066007,
        astc_10x5_sfloat_block = 1000066008,
        astc_10x6_sfloat_block = 1000066009,
        astc_10x8_sfloat_block = 1000066010,
        astc_10x10_sfloat_block = 1000066011,
        astc_12x10_sfloat_block = 1000066012,
        astc_12x12_sfloat_block = 1000066013,
        pvrtc1_2bpp_unorm_block_img = 1000054000,
        pvrtc1_4bpp_unorm_block_img = 1000054001,
        pvrtc2_2bpp_unorm_block_img = 1000054002,
        pvrtc2_4bpp_unorm_block_img = 1000054003,
        pvrtc1_2bpp_srgb_block_img = 1000054004,
        pvrtc1_4bpp_srgb_block_img = 1000054005,
        pvrtc2_2bpp_srgb_block_img = 1000054006,
        pvrtc2_4bpp_srgb_block_img = 1000054007,
        astc_3x3x3_unorm_block_ext = 1000288000,
        astc_3x3x3_srgb_block_ext = 1000288001,
        astc_3x3x3_sfloat_block_ext = 1000288002,
        astc_4x3x3_unorm_block_ext = 1000288003,
        astc_4x3x3_srgb_block_ext = 1000288004,
        astc_4x3x3_sfloat_block_ext = 1000288005,
        astc_4x4x3_unorm_block_ext = 1000288006,
        astc_4x4x3_srgb_block_ext = 1000288007,
        astc_4x4x3_sfloat_block_ext = 1000288008,
        astc_4x4x4_unorm_block_ext = 1000288009,
        astc_4x4x4_srgb_block_ext = 1000288010,
        astc_4x4x4_sfloat_block_ext = 1000288011,
        astc_5x4x4_unorm_block_ext = 1000288012,
        astc_5x4x4_srgb_block_ext = 1000288013,
        astc_5x4x4_sfloat_block_ext = 1000288014,
        astc_5x5x4_unorm_block_ext = 1000288015,
        astc_5x5x4_srgb_block_ext = 1000288016,
        astc_5x5x4_sfloat_block_ext = 1000288017,
        astc_5x5x5_unorm_block_ext = 1000288018,
        astc_5x5x5_srgb_block_ext = 1000288019,
        astc_5x5x5_sfloat_block_ext = 1000288020,
        astc_6x5x5_unorm_block_ext = 1000288021,
        astc_6x5x5_srgb_block_ext = 1000288022,
        astc_6x5x5_sfloat_block_ext = 1000288023,
        astc_6x6x5_unorm_block_ext = 1000288024,
        astc_6x6x5_srgb_block_ext = 1000288025,
        astc_6x6x5_sfloat_block_ext = 1000288026,
        astc_6x6x6_unorm_block_ext = 1000288027,
        astc_6x6x6_srgb_block_ext = 1000288028,
        astc_6x6x6_sfloat_block_ext = 1000288029,
        r16g16_sfixed5_nv = 1000464000,
        a1b5g5r5_unorm_pack16_khr = 1000470000,
        a8_unorm_khr = 1000470001,
        _,
    };

    pub const LevelCount = enum(u32) {
        generate = 0,
        _,

        pub fn fromInt(count: u32) @This() {
            assert(count != 0);
            return @enumFromInt(count);
        }

        pub fn toInt(self: @This()) u32 {
            switch (self) {
                .generate => return 1,
                else => return @intFromEnum(self),
            }
        }
    };

    pub const SupercompressionScheme = enum(u32) {
        none = 0,
        basis_lz = 1,
        zstandard = 2,
        zlib = 3,
        _,
    };

    pub const Index = extern struct {
        pub const InitOptions = struct {
            levels: u8,
            samples: u8,
        };

        pub fn init(options: InitOptions) @This() {
            return .{
                .dfd_byte_offset = @sizeOf(Header) + @sizeOf(Level) * @as(u32, options.levels),
                .dfd_byte_length = @sizeOf(u32) +
                    @bitSizeOf(BasicDescriptorBlock) / 8 +
                    @as(u32, options.samples) * @sizeOf(BasicDescriptorBlock.Sample),
                .kvd_byte_offset = 0,
                .kvd_byte_length = 0,
                .sgd_byte_offset = 0,
                .sgd_byte_length = 0,
            };
        }

        dfd_byte_offset: u32,
        dfd_byte_length: u32,
        kvd_byte_offset: u32,
        kvd_byte_length: u32,
        sgd_byte_offset: u64,
        sgd_byte_length: u64,
    };
};

pub const identifier = .{
    '«',
    'K',
    'T',
    'X',
    ' ',
    '2',
    '0',
    '»',
    '\r',
    '\n',
    '\x1A',
    '\n',
};

/// The max levels possible in a valid KTX file.
pub const max_levels = 31;

pub const Level = extern struct {
    byte_offset: u64,
    byte_length: u64,
    uncompressed_byte_length: u64,
};

pub const BasicDescriptorBlock = packed struct(u192) {
    vendor_id: VendorId = .khronos,
    descriptor_type: DescriptorType = .basic_format,
    version_number: VersionNumber = .@"1.3",
    descriptor_block_size: u16,
    model: ColorModel,
    primaries: ColorPrimaries,
    transfer: TransferFunction,
    flags: Flags,
    texel_block_dimension_0: TexelBlockDimension,
    texel_block_dimension_1: TexelBlockDimension,
    texel_block_dimension_2: TexelBlockDimension,
    texel_block_dimension_3: TexelBlockDimension,
    bytes_plane_0: u8,
    bytes_plane_1: u8,
    bytes_plane_2: u8,
    bytes_plane_3: u8,
    bytes_plane_4: u8,
    bytes_plane_5: u8,
    bytes_plane_6: u8,
    bytes_plane_7: u8,

    const VendorId = enum(u17) {
        khronos = 0,
        _,
    };

    const DescriptorType = enum(u15) {
        basic_format = 0,
        additional_planes = 0x6001,
        additional_dimensions = 0x6002,
        needed_for_write_bit = 0x2000,
        needed_for_decode_bit = 0x4000,
        _,
    };

    const VersionNumber = enum(u16) {
        pub const @"1.1": @This() = .@"1.0";

        @"1.0" = 0,
        @"1.2" = 1,
        @"1.3" = 2,
        _,
    };

    pub const ColorModel = enum(u8) {
        pub const dxt1a: @This() = .bc1a;
        pub const dxt2: @This() = .bc2;
        pub const dxt3: @This() = .bc2;
        pub const dxt4: @This() = .bc3;
        pub const dxt5: @This() = .bc3;

        unspecified = 0,
        rgbsda = 1,
        yuvsda = 2,
        yiqsda = 3,
        labsda = 4,
        cmyka = 5,
        xyzw = 6,
        hsva_ang = 7,
        hsla_ang = 8,
        hsva_hex = 9,
        hsla_hex = 10,
        ycgcoa = 11,
        yccbccrc = 12,
        ictcp = 13,
        ciexyz = 14,
        ciexyy = 15,
        bc1a = 128,
        bc2 = 129,
        bc3 = 130,
        bc4 = 131,
        bc5 = 132,
        bc6h = 133,
        bc7 = 134,
        etc1 = 160,
        etc2 = 161,
        astc = 162,
        etc1s = 163,
        pvrtc = 164,
        pvrtc2 = 165,
        uastc = 166,
        _,
    };

    pub const ColorPrimaries = enum(u8) {
        pub const srgb: @This() = .bt709;
        unspecified = 0,
        bt709 = 1,
        bt601_ebu = 2,
        bt601_smpte = 3,
        bt2020 = 4,
        ciexyz = 5,
        aces = 6,
        acescc = 7,
        ntsc1953 = 8,
        pal525 = 9,
        displayp3 = 10,
        adobergb = 11,
        _,
    };

    pub const TransferFunction = enum(u8) {
        pub const smtpe170m: @This() = .itu;
        unspecified = 0,
        linear = 1,
        srgb = 2,
        itu = 3,
        ntsc = 4,
        slog = 5,
        slog2 = 6,
        bt1886 = 7,
        hlg_oetf = 8,
        hlg_eotf = 9,
        pq_eotf = 10,
        pq_oetf = 11,
        dcip3 = 12,
        pal_oetf = 13,
        pal625_eotf = 14,
        st240 = 15,
        acescc = 16,
        acescct = 17,
        adobergb = 18,
        _,
    };

    pub const Flags = packed struct(u8) {
        alpha_premultiplied: bool,
        _padding0: u7 = 0,
    };

    pub const TexelBlockDimension = enum(u8) {
        _,

        pub fn fromInt(i: u8) @This() {
            return @enumFromInt(i - 1);
        }

        pub fn toInt(self: @This()) u8 {
            return @intFromEnum(self) + 1;
        }
    };

    pub const Sample = packed struct(u128) {
        bit_offset: BitOffset,
        bit_length: BitLength,
        channel_type: ChannelType(.unspecified),
        linear: bool,
        exponent: bool,
        signed: bool,
        float: bool,
        sample_position_0: u8,
        sample_position_1: u8,
        sample_position_2: u8,
        sample_position_3: u8,
        lower: u32,
        upper: u32,

        pub const BitOffset = enum(u16) {
            constant_sampler_lower = std.math.maxInt(u16),
            _,

            pub fn fromInt(i: u16) @This() {
                const result: @This() = @enumFromInt(i);
                assert(result != .constant_sampler_lower);
                return result;
            }

            pub fn toInt(self: @This()) u16 {
                assert(self != .constant_sampler_lower);
                return @intFromEnum(self);
            }
        };

        pub const BitLength = enum(u8) {
            _,

            pub fn fromInt(i: u8) @This() {
                return @enumFromInt(i - 1);
            }

            pub fn toInt(self: @This()) u8 {
                return @intFromEnum(self) + 1;
            }
        };

        pub fn ChannelType(model: ColorModel) type {
            return switch (model) {
                .rgbsda => enum(u4) {
                    red = 0,
                    green = 1,
                    blue = 2,
                    stencil = 13,
                    depth = 14,
                    alpha = 15,
                    _,
                },
                .yuvsda => enum(u4) {
                    pub const cb: @This() = .u;
                    pub const cr: @This() = .v;

                    y = 0,
                    u = 1,
                    v = 2,
                    stencil = 13,
                    depth = 14,
                    alpha = 15,
                    _,
                },
                .yiqsda => enum(u4) {
                    y = 0,
                    i = 1,
                    q = 2,
                    stencil = 13,
                    depth = 14,
                    alpha = 15,
                    _,
                },
                .labsda => enum(u4) {
                    l = 0,
                    a = 1,
                    b = 2,
                    stencil = 13,
                    depth = 14,
                    alpha = 15,
                    _,
                },
                .cmyka => enum(u4) {
                    pub const black: @This() = .key;
                    cyan = 0,
                    magenta = 1,
                    yellow = 2,
                    key = 3,
                    alpha = 15,
                    _,
                },
                .xyzw => enum(u4) {
                    x = 0,
                    y = 1,
                    z = 2,
                    w = 3,
                    _,
                },
                .hsva_ang => enum(u4) {
                    value = 0,
                    saturation = 1,
                    hue = 2,
                    alpha = 15,
                    _,
                },
                .hsla_ang => enum(u4) {
                    lightness = 0,
                    saturation = 1,
                    hue = 2,
                    alpha = 15,
                    _,
                },
                .hsva_hex => enum(u4) {
                    value = 0,
                    saturation = 1,
                    hue = 2,
                    alpha = 15,
                    _,
                },
                .hsla_hex => enum(u4) {
                    lightness = 0,
                    saturation = 1,
                    hue = 2,
                    alpha = 15,
                    _,
                },
                .ycgcoa => enum(u4) {
                    y = 0,
                    cg = 1,
                    co = 2,
                    alpha = 15,
                    _,
                },
                .ciexyz => enum(u4) {
                    x = 0,
                    y = 1,
                    z = 2,
                    _,
                },
                .ciexyy => enum(u4) {
                    x = 0,
                    ychroma = 1,
                    yluma = 2,
                    _,
                },
                .bc1a => enum(u4) {
                    color = 0,
                    alpha_present = 1,
                    _,
                },
                .bc2 => enum(u4) {
                    color = 0,
                    alpha = 15,
                    _,
                },
                .bc3 => enum(u4) {
                    color = 0,
                    alpha = 15,
                    _,
                },
                .bc4 => enum(u4) {
                    data = 0,
                    _,
                },
                .bc5 => enum(u4) {
                    red = 0,
                    green = 1,
                    _,
                },
                .bc6h => enum(u4) {
                    data = 0,
                    _,
                },
                .bc7 => enum(u4) {
                    data = 0,
                    _,
                },
                .etc1 => enum(u4) {
                    data = 0,
                    _,
                },
                .etc2 => enum(u4) {
                    red = 0,
                    green = 1,
                    color = 2,
                    alpha = 15,
                    _,
                },
                .astc => enum(u4) {
                    data = 0,
                    _,
                },
                .etc1s => enum(u4) {
                    rgb = 0,
                    rrr = 3,
                    ggg = 4,
                    aaa = 15,
                    _,
                },
                .pvrtc => enum(u4) {
                    data = 0,
                    _,
                },
                .pvrtc2 => enum(u4) {
                    data = 0,
                    _,
                },
                .uastc => enum(u4) {
                    rgb = 0,
                    rgba = 3,
                    rrr = 4,
                    rrrg = 5,
                    rg = 6,
                    _,
                },
                else => enum(u4) { _ },
            };
        }
    };

    pub fn descriptorBlockSize(samples: u8) u16 {
        return @bitSizeOf(BasicDescriptorBlock) / 8 + @sizeOf(BasicDescriptorBlock.Sample) * samples;
    }
};

pub fn init(bytes: []align(@alignOf(u64)) const u8) Error!@This() {
    comptime assert(builtin.cpu.arch.endian() == .little);

    // Parse the header
    if (bytes.len < @sizeOf(Header)) return error.InvalidKtx2;
    const header: *const Header = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &header.identifier, &identifier)) {
        return error.InvalidKtx2;
    }

    // Check that we don't have too many levels
    const max_levels_for_size = std.math.log2_int(u32, @max(
        header.pixel_width,
        header.pixel_height,
        header.pixel_depth,
    ));
    if (header.level_count.toInt() > max_levels_for_size) {
        return error.InvalidKtx2;
    }

    // Parse the level index.
    //
    // The multiplication here can't overflow because we already verified level count (it can
    // never exceed 32.)
    const levels_bytes = @sizeOf(Level) * header.level_count.toInt();
    if (bytes.len < @sizeOf(Header) + levels_bytes) {
        return error.InvalidKtx2;
    }
    const levels_unsized: [*]align(1) const Level = @ptrCast(&bytes[@sizeOf(Header)]);
    const levels: []align(1) const Level = levels_unsized[0..header.level_count.toInt()];
    for (levels) |level| {
        if (level.byte_offset + level.byte_length > bytes.len) {
            return error.InvalidKtx2;
        }
    }

    // Parse the DFD
    if (bytes.len < header.index.dfd_byte_offset + header.index.dfd_byte_length) {
        return error.InvalidKtx2;
    }
    if (header.index.dfd_byte_length < @sizeOf(u32) + @bitSizeOf(BasicDescriptorBlock) / 8) {
        return error.UnsupportedKtx2;
    }
    const dfd_total_size: *align(1) const u32 = @ptrCast(&bytes[header.index.dfd_byte_offset]);
    if (header.index.dfd_byte_length != dfd_total_size.*) {
        return error.InvalidKtx2;
    }
    const basic_df: *align(1) const BasicDescriptorBlock = @ptrCast(
        &bytes[header.index.dfd_byte_offset + @sizeOf(u32)],
    );
    if (basic_df.vendor_id != .khronos) return error.UnsupportedKtx2;
    if (basic_df.descriptor_type != .basic_format) return error.UnsupportedKtx2;
    if (basic_df.version_number != .@"1.3") return error.UnsupportedKtx2;
    const basic_descriptor_block_remaining_bytes = std.math.sub(
        u32,
        basic_df.descriptor_block_size,
        @bitSizeOf(BasicDescriptorBlock) / 8,
    ) catch {
        return error.InvalidKtx2;
    };
    const sample_count = std.math.divExact(
        u32,
        basic_descriptor_block_remaining_bytes,
        @sizeOf(BasicDescriptorBlock.Sample),
    ) catch {
        return error.InvalidKtx2;
    };
    const samples_unsized: [*]align(1) const BasicDescriptorBlock.Sample = @ptrCast(&bytes[
        header.index.dfd_byte_offset +
            header.index.dfd_byte_length -
            sample_count * @sizeOf(BasicDescriptorBlock.Sample)
    ]);
    const samples = samples_unsized[0..sample_count];

    // Parse key and value data
    if (header.index.kvd_byte_offset + header.index.kvd_byte_length > bytes.len) {
        return error.InvalidKtx2;
    }
    const kv_data = bytes[header.index.kvd_byte_offset..][0..header.index.kvd_byte_length];

    // Parse global supercompression data
    if (header.index.sgd_byte_offset + header.index.sgd_byte_length > bytes.len) {
        return error.InvalidKtx2;
    }
    const sg_data = bytes[header.index.sgd_byte_offset..][0..header.index.sgd_byte_length];

    return .{
        .header = header,
        .levels = levels,
        .basic_descriptor_block = basic_df,
        .samples = samples,
        .key_value_data = kv_data,
        .supercompression_global_data = sg_data,
    };
}

pub const KeyValueIter = struct {
    pub const Item = struct {
        key: [:0]const u8,
        value: []const u8,
    };

    data: []const u8,

    pub fn next(self: *@This()) error{InvalidKtx2}!?Item {
        // Stop if we're out of data
        if (self.data.len == 0) return null;

        // Get the length of this key value pair
        if (self.data.len < @sizeOf(u32)) return error.InvalidKtx2;
        const length: *align(1) const u32 = @ptrCast(self.data.ptr);
        if (length.* < 2) return error.InvalidKtx2;

        // Get the keyrgbsda value pair
        if (@as(usize, @sizeOf(u32)) + length.* > self.data.len) return error.InvalidKtx2;
        const kv = self.data[@sizeOf(u32)..][0..length.*];

        // Advance the iterator
        const offset = std.mem.alignForward(u32, @sizeOf(u32) + length.*, 4);
        if (offset > self.data.len) return error.InvalidKtx2;
        self.data = self.data[offset..];

        // Split the key and value out
        const null_index = std.mem.indexOfScalar(u8, kv, 0) orelse return error.InvalidKtx2;
        return .{
            .key = @ptrCast(kv[0..null_index]),
            .value = kv[null_index + 1 ..],
        };
    }
};

pub fn keyValueIter(self: *const @This()) KeyValueIter {
    return .{ .data = self.key_value_data };
}

pub fn levelBytes(self: *const @This(), index: u8) ?[]const u8 {
    // Check that the level exists. If it does, the offsets inside of it were already bounds checked
    // on init. Otherwise fail.
    if (index >= self.levels.len) return null;
    const level = self.levels[index];

    const all_bytes: [*]const u8 = @ptrCast(self.header);
    return all_bytes[level.byte_offset..][0..level.byte_length];
}
