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
    var server = Server{ .loop = &loop };
    try loop.run(Server.mainLoop, .{&server});

    return 0;
}
