const std = @import("std");
const io = @import("io.zig");

loop: *io.EventLoop,

const Server = @This();

pub fn mainLoop(self: *Server) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const sigf = try self.loop.signalOpen(&.{ .int, .hup });
    defer sigf.close();
    var sig_future = io.future(&async sigf.capture());

    const addr = try std.net.Address.resolveIp("::", 8080);
    const listener = try self.loop.listen(addr, .{ .backlog = 100, .reuseaddr = true });
    defer listener.close();

    var sock_frame: @Frame(io.Listener.accept) = undefined;
    while (true) {
        sock_frame = async listener.accept();
        var sock_future = io.future(&sock_frame);
        switch (try self.loop.any(.{ .sig = &sig_future, .sock = &sock_future })) {
            .sig => |sig| {
                _ = try sig;
                break;
            },
            .sock => |conn| {
                try self.loop.runDetached(allocator, clientTask, .{ allocator, try conn });
            },
        }
    }

    // TODO: cleanly terminate connections
    std.debug.print("Exiting\n", .{});
}

fn clientTask(allocator: *std.mem.Allocator, conn: io.Listener.Connection) void {
    handleClient(allocator, conn) catch |err| {
        std.debug.print("Error in client '{}': {s}\n", .{ conn.addr, @errorName(err) });
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
    defer buf.deinit();
    while (r.readUntilDelimiterArrayList(&buf, '\n', 1 << 20)) |_| {
        try buf.append('\n');
        try w.writeAll(buf.items);
    } else |err| switch (err) {
        error.WouldBlock => unreachable, // Not a non-blocking socket
        error.EndOfStream => {},
        else => |e| return e,
    }
}
