# Zex

A texture utility for Zig.

## Rationale

Games typically ship with a lot of texture data. It may be tempting to ship texture data as images, but image formats are typically a poor representation for texture data:

* Image formats typically must be uncompressed before being uploaded to the GPU
* Image formats typically can't contain prebaked [mipmaps](https://en.wikipedia.org/wiki/Mipmap)
* Image formats typically can't contain [cubemaps](https://en.wikipedia.org/wiki/Cube_mapping)
* Image formats typically do not indicate if their alpha is [premultiplied](https://tomforsyth1000.github.io/blog.wiki.html#%5B%5BPremultiplied%20alpha%5D%5D)
* etc...

Texture formats like Khronos' [KTX](https://www.khronos.org/ktx/) and Microsoft's [DDS](https://learn.microsoft.com/en-us/windows/win32/direct3ddds/dx-graphics-dds-pguide) are designed for exactly this use case.

Not only do these texture formats support the aforementioned features, they also support lossy GPU compression formats that don't need to be decompressed because the GPU can sample from the compressed data, increasing performance while decreasing memory usage.

While convenient, these formats do not provide compression ratios competitive with normal image formats, so it is typical to apply additional lossless compression in a strategy called "supercompression". Typically one would attempt to apply the former lossy compression in such a way as to reduce entropy increasing the effectiveness of the lossless compression.

This high level strategy is effective, but it's hard to come by tools that make employing it easy, so it's typical for small games to either reinvent the wheel, or miss out on the benefits of these formats entirely. This library aims to fill that gap.

In particular, Zig is uniquely suited to make this process easy via its build system which can be extended with tools like Zex to compress textures at build time, automatically providing caching and parallelism.

## Documentation

Documentation available [here](https://docs.gamesbymason.com/zex/), you can generate up to date docs yourself with `zig build docs`.

## What's Provided

### Command Line Tool

The command line tool encodes can be called manually, or automatically from Zig's build system.

It can read any image format supported by [STB Image](https://github.com/nothings/stb/blob/master/stb_image.h), and encode it to the following formats:

* `r8g8b8a8_uint`
* `r8g8b8a8_srgb`
* `r32g32b32a32_sfloat`
* `bc7_srgb_block`
* `bc7_unorm_block`

BC7 compression is achieved with [bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo/). Bc7 encoding optionally supports a reduced entropy mode, and rate distortion optimization, both of which typically increase the effectiveness of lossless compression.

Supports premultiplying alpha while encoding.

Output files are stored as [KTX2](https://www.khronos.org/ktx/).

Supercompression with KTX2's zlib mode is supported.

### Library

This package exports a Ktx2 library for loading KTX2 files in engine.

## Viewing Textures

Zex is not a texture viewer, and KTX2 files can't be opened in typical image editors. This is to be expected since textures store a lot of data normal image editors don't expect, in formats that don't make sense for normal interchange.

I recommend [Tacent View](https://github.com/bluescan/tacentview) for inspecting textures.

## Development Links

* [KTX2 spec](https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#prohibitedFormats)
* [Data Format Descriptor spec](https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.html)
* [Reference KTX implementation and validator](https://github.com/KhronosGroup/KTX-Software)

## Zex is a work in progress

See the issues tracker for features that are tentatively planned but currently missing.
