//! A texture utility for Zig. For more information, see README.md, or
//! [Stop Shipping PNGs In Your Games](https://gamesbymason.com/blog/2025/stop-shipping-pngs/).

const std = @import("std");
const tracy = @import("tracy");

const Allocator = std.mem.Allocator;
const Zone = tracy.Zone;

pub const Image = @import("Image.zig");
pub const Texture = @import("Texture.zig");
