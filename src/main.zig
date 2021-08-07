const std = @import("std");
const io = @import("io.zig");
const Server = @import("Server.zig");

pub fn main() !u8 {
    var loop = io.EventLoop.init() catch |err| switch (err) {
        error.SystemOutdated => {
            std.debug.print("io_uring unsupported. Please upgrade to Linux 5.1 or greater.\n", .{});
            return 1;
        },
        else => |e| return e,
    };
    defer loop.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    try loop.run(ioMain, .{ allocator, &loop });

    return 0;
}

fn ioMain(allocator: *std.mem.Allocator, loop: *io.EventLoop) !void {
    var server = try Server.init(allocator, loop);
    defer server.deinit();
    try server.mainLoop();
}
