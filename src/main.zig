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
        try loop.runDetached(allocator, clientTask, .{ allocator, conn });
    }
}

fn clientTask(allocator: *std.mem.Allocator, conn: io.Listener.Connection) void {
    handleClient(allocator, conn) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}
fn handleClient(allocator: *std.mem.Allocator, conn: io.Listener.Connection) !void {
    defer conn.sock.close();
    std.debug.print("{} connected\n", .{conn.addr});
    defer std.debug.print("{} disconnected\n", .{conn.addr});

    const r = std.io.bufferedReader(conn.sock.reader()).reader();
    const w = conn.sock.writer();

    var buf = std.ArrayList(u8).init(allocator);
    while (r.readUntilDelimiterArrayList(&buf, '\n', 1 << 20)) |_| {
        try buf.append('\n');
        try w.writeAll(buf.items);
    } else |err| switch (err) {
        error.WouldBlock => unreachable, // Not a non-blocking socket
        error.EndOfStream => {},
        else => |e| return e,
    }
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
