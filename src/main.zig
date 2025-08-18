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
    .description = "Converts images to KTX2.",
    .positional_args = &.{
        .init([]const u8, .{
            .meta = "INPUT",
        }),
        .init([]const u8, .{
            .meta = "OUTPUT",
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

    var input_file = cwd.openFile(args.positional.INPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.INPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer input_file.close();

    var input_buf: [1024]u8 = undefined;
    var input = input_file.readerStreaming(&input_buf);

    // XXX: make sure we flush writers!
    var output_file = cwd.createFile(args.positional.OUTPUT, .{}) catch |err| {
        log.err("{s}: {s}", .{ args.positional.OUTPUT, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        output_file.sync() catch |err| @panic(@errorName(err));
        output_file.close();
    }

    // XXX: share buf or no? size?
    var output_buf: [1024]u8 = undefined;
    var output = output_file.writerStreaming(&output_buf);

    // XXX: pass in options from zon (read from file/write default file if missing with all options
    // specified)
    // XXX: add deps file output to make it possible to actually use this as is from the build system?
    try zex.process(allocator, &input.interface, &output.interface, .{});
}
