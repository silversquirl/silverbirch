const std = @import("std");
const io = @import("io.zig");

allocator: *std.mem.Allocator,
loop: *io.EventLoop,
sigf: io.SignalFile,
listener: io.Listener,
quit: io.Flag,
group: io.WaitGroup,

const Server = @This();

pub fn init(allocator: *std.mem.Allocator, loop: *io.EventLoop) !Server {
    const sigf = try loop.signalOpen(&.{ .int, .hup });
    errdefer sigf.close();

    const addr = try std.net.Address.resolveIp("::", 8080);
    const listener = try loop.listen(addr, .{ .backlog = 100, .reuseaddr = true });
    errdefer listener.close();

    return Server{
        .allocator = allocator,
        .loop = loop,
        .sigf = sigf,
        .listener = listener,
        .quit = loop.flag(),
        .group = loop.waitGroup(),
    };
}

pub fn deinit(self: Server) void {
    self.listener.close();
    self.sigf.close();
}

pub fn mainLoop(self: *Server) !void {
    var sig_future = io.future(&async self.sigf.capture());

    var sock_frame: @Frame(io.Listener.accept) = undefined;
    while (true) {
        sock_frame = async self.listener.accept();
        var sock_future = io.future(&sock_frame);
        switch (try self.loop.any(.{ .sig = &sig_future, .sock = &sock_future })) {
            .sig => |sig| {
                _ = try sig;
                break;
            },
            .sock => |conn| {
                self.group.add(1);
                try self.loop.runDetached(self.allocator, clientTask, .{ self, try conn });
            },
        }
    }

    std.debug.assert(self.quit.set());
    std.debug.print("Exiting\n", .{});
    self.group.wait();
}

fn clientTask(self: *Server, conn: io.Listener.Connection) void {
    defer self.group.done();
    self.handleClient(conn) catch |err| {
        std.debug.print("Error in client '{}': {s}\n", .{ conn.addr, @errorName(err) });
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}
fn handleClient(self: *Server, conn: io.Listener.Connection) !void {
    defer conn.sock.close();
    std.debug.print("{} connected\n", .{conn.addr});
    defer std.debug.print("{} disconnected\n", .{conn.addr});

    const r = std.io.bufferedReader(conn.sock.reader()).reader();
    const w = conn.sock.writer();

    var buf = std.ArrayList(u8).init(self.allocator);
    defer buf.deinit();
    var read_frame: @Frame(@TypeOf(r).readUntilDelimiterArrayList) = undefined;

    while (true) {
        read_frame = async r.readUntilDelimiterArrayList(&buf, '\n', 1 << 20);
        var read_future = io.future(&read_frame);
        switch (try self.loop.any(.{ .quit = &self.quit, .read = &read_future })) {
            .quit => return,
            .read => |res| {
                res catch |err| switch (err) {
                    error.WouldBlock => unreachable, // Not a non-blocking socket
                    error.EndOfStream => return,
                    else => |e| return e,
                };

                try buf.append('\n');
                try w.writeAll(buf.items);
            },
        }
    }
}
