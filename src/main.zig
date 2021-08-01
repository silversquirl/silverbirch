const std = @import("std");
const io = @import("io.zig");

fn mainLoop(loop: *io.EventLoop) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    const addr = try std.net.Address.resolveIp("::", 8080);
    const listener = try loop.listen(addr, .{ .backlog = 100, .reuseaddr = true });
    defer listener.close();

    while (true) {
        const conn = try listener.accept();
        try loop.runDetached(allocator, handleClient, .{conn});
    }
}

fn handleClient(conn: io.Listener.Connection) void {
    defer conn.sock.close();
    const w = conn.sock.writer();

    w.writeAll("Hello, world!\n") catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

pub fn main() !u8 {
    var loop = io.EventLoop.init() catch |err| switch (err) {
        error.SystemOutdated => {
            std.debug.print("io_uring unsupported. Please upgrade to Linux 5.1 or greater.\n", .{});
            return 1;
        },
        else => |e| return e,
    };
    defer loop.deinit();

    nosuspend {
        var frame = async mainLoop(&loop);
        try await frame;
    }

    return 0;
}
