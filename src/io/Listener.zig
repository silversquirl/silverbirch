const std = @import("std");
const os = std.os;
const EventLoop = @import("EventLoop.zig");
const Socket = @import("Socket.zig");

const Listener = @This();

loop: *EventLoop,
fd: os.socket_t,

pub fn open(loop: *EventLoop, addr: std.net.Address, opts: ListenOptions) !Listener {
    const fd = try os.socket(@enumToInt(opts.domain), @enumToInt(opts.sock_type), opts.protocol);
    errdefer os.close(fd);
    if (opts.reuseaddr) {
        try os.setsockopt(fd, os.SOL_SOCKET, os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }
    try os.bind(fd, &addr.any, addr.getOsSockLen());
    try os.listen(fd, opts.backlog);
    return Listener{ .loop = loop, .fd = fd };
}
pub const ListenOptions = struct {
    domain: Socket.Domain = .inet6,
    sock_type: Socket.Type = .stream,
    protocol: u32 = 0,
    backlog: u31 = 0,

    reuseaddr: bool = false,
};

pub fn close(self: Listener) void {
    self.loop.close(self.fd);
}

pub fn accept(self: Listener) !Connection {
    var addr: os.sockaddr_storage = undefined;
    var len: os.socklen_t = @sizeOf(os.sockaddr_storage);
    const fd = try self.loop.accept(self.fd, @ptrCast(*os.sockaddr, &addr), &len);
    std.debug.assert(len <= @sizeOf(os.sockaddr_storage));
    return Connection{
        .addr = std.net.Address.initPosix(@ptrCast(*os.sockaddr, &addr)),
        .sock = .{ .loop = self.loop, .fd = fd },
    };
}
pub const Connection = struct {
    addr: std.net.Address,
    sock: Socket,
};
