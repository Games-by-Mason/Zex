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

Planned features for 1.0 can be found [here](https://github.com/Games-by-Mason/Zex/milestone/1).

# WIP
* Pull out any more steps? e.g. be able to call compress on a texture? Generate mips?
	* Maybe not gen mips, but, could take mips vs take single image
	* If we take mips...take arg for first image coverage, and whether first level is match, fold in threshold into here
* Also do we really need from reader on texture?
* Current:
	* I think encoded and compressed image could be combined--that way you can do encoding and compression later. The default encoding is just encoding as hdr basically. That way the steps can be separate.
		* Start by making initFromImage2 that just creates a texture with default encoding and no mipmaps from an image
		* Then create one that creates it from mipmaps, and also one that generates the mipmaps
		* Then add a function that changes the encoding, and one that compresses
		* This will be way better, not even sure whether the default pipeline is needed or not if the API is this nice, can just be up to the caller possibly
* Current:
	* Update encoded image to have separate "encode" function, but return an error if not currently f32 right?
		* Alternatively could keep it happening on init, think through the tradeoffs
		* We DO want compress to be separate, so, I think it makes sense to just do this
* We may want to do these operations on the whole texture instead of per level, since it never makes sense for them to vary. If we don't make sure to assert that they match when writing. Sizes should also be calculable from lowest mip level. It's nice having it separate for threading, but that could also be done internally, idk.
* CURRENT: use the new way it's broken up to allow calling gen mipmaps and encode on the texture
	* can't yet cause of compressed image
	* merge with encoded image then do that
* Note on animated textures: not useful if you want to reuse frames between animations. Then again you probably don't?
* CURRENT:
	* can't call generate mipmaps cause that's on image, not on encoded image
	* we don't want to completely merge these types, because it's confusing what stuff is available where
	* two ideas:
		1. merge the types, but have a child object that is the encoding that exposes extra methods and uses fieldparentptr to access the parent data
			* works is just a little weird for the end user
		2. have a way to get a rgbaf32 view from an image
			* if you call resize or something, how do we update the parent object?
			* maybe we actually store an image inside of the rgbaf32? kinda weird that it has encoding and such on it though
			* we could have it be that you always move out of it to operate on it but that's kinda annoying i'd rather just have the asserts in that case
			* on some level we can't prevent this issue right? like even if you don't own the image, if you can also point to it through a image pointer, that can then call compress on it out from under you
			* we may wanna go with the simpler solution of just adopting a naming convention and using asserts, e.g. instead of resize rgbaF32Resize and instead of generateMipmaps it's rgbaF32GenerateMipmaps and so on. Or could be at the end like resizeRgbaF32 and generateMipmapsRgbaF32.
			* I think that's simplest
			* Let's just do that, we can add more type safety later if we want, best way involves not really changing what actually happens under the hood imo so this is a good start regardless
			* [ ] need to start moving encoding stuff onto image now
				* need to change data into anyopaque and have getters for getting as the right type
			* [ ] update docs to explain convention
			* [ ] CURRENT: moved the compression function to image, need to move other encoding stuff! naming convention may need to change for the encode function to not be confusing
		3. merge everything, have an optional type arg for the encoding, and comptime assert on that on some methods
	* solution: somehow allow viewing an Image as an ImageRgbaF32 if it's uncompressed and encoded as rgbaf32
	* issue is that 