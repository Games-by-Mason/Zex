const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const structopt = @import("structopt");
const zex = @import("zex");
const zon = @import("zon.zig");

pub const tracy = @import("tracy");

pub const tracy_impl = @import("tracy_impl");

const Io = std.Io;
const Command = structopt.Command;
const Zone = tracy.Zone;

const command: Command = .{
    .name = "zex",
    .description = "Converts images to KTX2 using config specified as a ZON file.",
    .named_args = &.{
        .init([]const u8, .{
            .long = "input",
        }),
        .initAccum([]const u8, .{
            .long = "config",
        }),
        .init([]const u8, .{
            .long = "output",
        }),
    },
};

pub fn main() !void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    tracy.frameMarkStart("main");
    tracy.appInfo("Zex");
    defer tracy.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var threaded_io: Io.Threaded = .init_single_threaded;
    const io = threaded_io.io();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const cwd = std.fs.cwd();

    var input_file = cwd.openFile(args.named.input, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.named.input, @errorName(err) });
        std.process.exit(1);
    };
    defer input_file.close();
    var input_buf: [4096]u8 = undefined;
    var input = input_file.readerStreaming(io, &input_buf);

    // Read the config file(s)
    var config: zex.Texture.Options = .{};
    for (args.named.config.items) |path| {
        // Get the config source file
        const src = cwd.readFileAllocOptions(
            path,
            allocator,
            .unlimited,
            .@"1",
            0,
        ) catch |err| {
            log.err("{s}: {s}", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(src);

        // Parse the ZON and update the config
        var diag: zon.Diagnostics = .{};
        defer diag.deinit(allocator);
        config = zon.fromSliceDefaults(
            zex.Texture.Options,
            allocator,
            src,
            &diag,
            &config,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                log.err("{s}: {f}", .{ path, diag });
                std.process.exit(1);
            },
        };
    }

    // Create the texture
    var texture = zex.Texture.init(
        allocator,
        &input.interface,
        config,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.exit(1),
    };
    defer texture.deinit();

    var output_file = cwd.createFile(args.named.output, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.named.output, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    var output_buf: [4096]u8 = undefined;
    var output = output_file.writerStreaming(&output_buf);

    // Write the texture
    try texture.writeKtx2(&output.interface);
    try output.interface.flush();
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();

    var buffer: [64]u8 = undefined;
    var stderr, const tty_config = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend {
        var wrote_prefix = false;
        if (message_level != .info) {
            tty_config.setColor(stderr, .bold) catch {};
            tty_config.setColor(stderr, switch (message_level) {
                .err => .red,
                .warn => .yellow,
                .info => .green,
                .debug => .blue,
            }) catch {};
            stderr.writeAll(level_txt) catch {};
            tty_config.setColor(stderr, .reset) catch {};
            wrote_prefix = true;
        }
        if (message_level == .err) tty_config.setColor(stderr, .bold) catch {};
        if (wrote_prefix) {
            stderr.writeAll(": ") catch return;
        }
        stderr.print(format ++ "\n", args) catch return;
        tty_config.setColor(stderr, .reset) catch {};
    }
}

test {
    _ = @import("zon.zig");
}
