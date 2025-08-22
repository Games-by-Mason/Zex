const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const structopt = @import("structopt");
const zex = @import("zex");
pub const tracy = @import("tracy");

pub const tracy_impl = @import("tracy_impl");

const Command = structopt.Command;
const Zone = tracy.Zone;

const command: Command = .{
    .name = "zex",
    .description = "Converts images to KTX2 using config specified as a ZON file.",
    .named_args = &.{
        .init([]const u8, .{
            .long = "input",
            .short = 'i',
        }),
        .init([]const u8, .{
            .long = "config",
            .short = 'c',
        }),
        .init([]const u8, .{
            .long = "output",
            .short = 'o',
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
    var input_buf: [128]u8 = undefined;
    var input = input_file.readerStreaming(&input_buf);

    var config_file = cwd.openFile(args.named.config, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.named.config, @errorName(err) });
        std.process.exit(1);
    };
    defer config_file.close();

    var config_buf: [128]u8 = undefined;
    var config_reader = config_file.readerStreaming(&config_buf);
    const config_zon = b: {
        var config_zon: std.ArrayList(u8) = .{};
        errdefer config_zon.deinit(allocator);
        try config_reader.interface.appendRemainingUnlimited(
            allocator,
            .of(u8),
            &config_zon,
            config_buf.len,
        );
        break :b try config_zon.toOwnedSliceSentinel(allocator, 0);
    };
    defer allocator.free(config_zon);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    const config = std.zon.parse.fromSlice(
        zex.Options,
        allocator,
        config_zon,
        &diag,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            log.err("{s}: {f}", .{ args.named.config, diag });
            std.process.exit(1);
        },
    };

    var output_file = cwd.createFile(args.named.output, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.named.output, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    var output_buf: [128]u8 = undefined;
    var output = output_file.writerStreaming(&output_buf);

    try zex.process(allocator, &input.interface, &output.interface, config);
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
    const bold = "\x1b[1m";
    const color = switch (message_level) {
        .err => "\x1b[31m",
        .info => "\x1b[32m",
        .debug => "\x1b[34m",
        .warn => "\x1b[33m",
    };
    const reset = "\x1b[0m";
    const level_txt = comptime message_level.asText();

    var buffer: [64]u8 = undefined;
    var stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend {
        var wrote_prefix = false;
        if (message_level != .info) {
            stderr.writeAll(bold ++ color ++ level_txt ++ reset) catch return;
            wrote_prefix = true;
        }
        if (message_level == .err) stderr.writeAll(bold) catch return;
        if (wrote_prefix) {
            stderr.writeAll(": ") catch return;
        }
        stderr.print(format ++ "\n", args) catch return;
        stderr.writeAll(reset) catch return;
    }
}
