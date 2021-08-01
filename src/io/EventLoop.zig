// Purely single-threaded event loop
// TODO: multithreading

const std = @import("std");
const os = std.os;

uring: os.linux.IO_Uring,
cpu_q: CpuQueue = .{},

const EventLoop = @This();
const CpuQueue = std.TailQueue(anyframe->void);

pub fn init() !EventLoop {
    return EventLoop{
        .uring = try os.linux.IO_Uring.init(4096, 0),
    };
}
pub fn deinit(self: *EventLoop) void {
    std.debug.assert(self.cpu_q.len == 0);
    self.uring.deinit();
}

pub fn runDetached(self: *EventLoop, allocator: *std.mem.Allocator, comptime func: anytype, args: anytype) !void {
    _ = self;
    const Args = @TypeOf(args);
    const wrapper = struct {
        fn wrapper(loop: *EventLoop, walloc: *std.mem.Allocator, wargs: Args) void {
            var node = CpuQueue.Node{ .data = @frame() };
            loop.cpu_q.prepend(&node);
            suspend {}
            @call(.{}, func, wargs);
            suspend {
                walloc.destroy(@frame());
            }
        }
    }.wrapper;
    const frame = try allocator.create(@Frame(wrapper));
    frame.* = async wrapper(self, allocator, args);
}

pub const listen = @import("Listener.zig").open;
pub const connect = @import("Socket.zig").open;

//// For internal use ////

pub fn close(self: *EventLoop, fd: os.fd_t) void {
    if (self.submit(.close, .{fd})) |ret| {
        _ = ret; // TODO
    } else |_| {
        os.close(fd); // We want to close even if it means blocking
    }
}

pub fn recv(self: *EventLoop, fd: os.socket_t, buf: []u8) RecvError!u31 {
    const res = try self.submit(.recv, .{ fd, buf, 0 });
    switch (errno(res)) {
        0 => return @intCast(u31, res),

        os.EBADF => unreachable, // always a race condition
        os.EFAULT => unreachable,
        os.EINVAL => unreachable,
        os.ENOTCONN => unreachable,
        os.ENOTSOCK => unreachable,
        os.EAGAIN => return error.WouldBlock,
        os.ENOMEM => return error.SystemResources,
        os.ECONNREFUSED => return error.ConnectionRefused,
        os.ECONNRESET => return error.ConnectionResetByPeer,
        else => |err| return os.unexpectedErrno(err),
    }
}
pub const RecvError = error{
    WouldBlock,
    SystemResources,
    ConnectionRefused,
    ConnectionResetByPeer,
} || SubmitError;

pub fn send(self: *EventLoop, fd: os.socket_t, buf: []const u8) SendError!u31 {
    const res = try self.submit(.send, .{ fd, buf, 0 });
    return switch (errno(res)) {
        0 => @intCast(u31, res),

        os.EACCES => error.AccessDenied,
        os.EAGAIN => error.WouldBlock,
        os.EALREADY => error.FastOpenAlreadyInProgress,
        os.EBADF => unreachable, // always a race condition
        os.ECONNRESET => error.ConnectionResetByPeer,
        os.EDESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
        os.EFAULT => unreachable, // An invalid user space address was specified for an argument.
        os.EINVAL => unreachable, // Invalid argument passed.
        os.EISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
        os.EMSGSIZE => error.MessageTooBig,
        os.ENOBUFS => error.SystemResources,
        os.ENOMEM => error.SystemResources,
        os.ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        os.EOPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
        os.EPIPE => error.BrokenPipe,
        os.EHOSTUNREACH => error.NetworkUnreachable,
        os.ENETUNREACH => error.NetworkUnreachable,
        os.ENETDOWN => error.NetworkSubsystemFailed,
        else => |err| os.unexpectedErrno(err),
    };
}
pub const SendError = os.SendError || SubmitError;

pub fn accept(self: *EventLoop, fd: os.socket_t, addr: *os.sockaddr, addrlen: *os.socklen_t) !os.socket_t {
    return self.submit(.accept, .{ fd, addr, addrlen, 0 });
}

pub fn connectRaw(self: *EventLoop, fd: os.socket_t, addr: *const os.sockaddr, addrlen: os.socklen_t) !void {
    const ret = try self.submit(.connect, .{ fd, addr, addrlen });
    _ = ret; // TODO
}

//// Functions internal to the event loop itself ////

const SubmitError = @typeInfo(@typeInfo(@TypeOf(os.linux.IO_Uring.submit)).Fn.return_type.?).ErrorUnion.error_set;
fn submit(self: *EventLoop, comptime op: DeclEnum(os.linux.IO_Uring), args: anytype) SubmitError!i32 {
    var data = SubmissionData{ .frame = @frame() };
    suspend {
        _ = @call(.{}, @field(self.uring, @tagName(op)), .{@ptrToInt(&data)} ++ args) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                @panic("TODO");
            },
        };
        _ = try self.uring.submit(); // TODO: batch submissions?
        try self.runStep();
    }
    return data.res;
}

const SubmissionData = struct {
    frame: anyframe->SubmitError!i32,
    res: i32 = undefined,
};

fn DeclEnum(comptime T: type) type {
    const decls = std.meta.declarations(T);
    var fields: [decls.len]std.builtin.TypeInfo.EnumField = undefined;
    for (decls) |decl, i| {
        fields[i] = .{ .name = decl.name, .value = i };
    }
    return @Type(.{ .Enum = .{
        .layout = .Auto,
        .tag_type = std.math.IntFittingRange(0, fields.len - 1),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

fn runStep(self: *EventLoop) !void {
    while (true) {
        // Prioritize whichever queue is longer
        if (self.uring.cq_ready() < self.cpu_q.len) {
            resume self.cpu_q.pop().?.data;
        } else {
            const cqe = try self.uring.copy_cqe();
            const data = @intToPtr(*SubmissionData, cqe.user_data);
            data.res = cqe.res;
            resume data.frame;
        }

        // TODO: unreachable if there are no tasks (IO or CPU) to perform
        // This could happen if a function suspends without informing the event loop
    }
}

fn errno(res: i32) u12 {
    return if (-4096 < res and res < 0)
        @intCast(u12, -res)
    else
        0;
}
