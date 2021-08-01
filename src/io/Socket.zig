const std = @import("std");
const os = std.os;
const EventLoop = @import("EventLoop.zig");

const Socket = @This();

// TODO: support more options
pub const Domain = enum(u32) { inet6 = os.AF_INET6 };
pub const Type = enum(u32) { stream = os.SOCK_STREAM };

loop: *EventLoop,
fd: os.socket_t,

pub fn open(loop: *EventLoop, addr: std.net.Address, opts: ConnectOptions) !Socket {
    const fd = try os.socket(@enumToInt(opts.domain), @enumToInt(opts.sock_type), opts.protocol);
    errdefer os.close(fd);
    try loop.connectRaw(fd, &addr.any, addr.getOsSockLen());
    return Socket{ .loop = loop, .fd = fd };
}
pub const ConnectOptions = struct {
    domain: Socket.Domain = .inet6,
    sock_type: Socket.Type = .stream,
    protocol: u32 = 0,
};

pub fn close(self: Socket) void {
    self.loop.close(self.fd);
}

pub fn read(self: Socket, buf: []u8) ReadError!usize {
    return try self.loop.recv(self.fd, buf);
}
pub fn write(self: Socket, buf: []const u8) WriteError!usize {
    return try self.loop.send(self.fd, buf);
}

pub const ReadError = EventLoop.RecvError;
pub const Reader = std.io.Reader(Socket, ReadError, read);
pub fn reader(self: Socket) Reader {
    return Reader{ .context = self };
}

pub const WriteError = EventLoop.SendError;
pub const Writer = std.io.Writer(Socket, WriteError, write);
pub fn writer(self: Socket) Writer {
    return Writer{ .context = self };
}
