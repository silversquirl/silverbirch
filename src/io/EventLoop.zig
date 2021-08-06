// Purely single-threaded event loop
// TODO: multithreading

const std = @import("std");
const os = std.os;

uring: os.linux.IO_Uring, // For IO-bound tasks
// TODO: thread
waiting: bool = false, // Whether the last resumed wait task is still waiting
wait_q: TaskQueue = .{}, // For task-bound tasks
cpu_q: TaskQueue = .{}, // For CPU-bound tasks
debug: if (std.debug.runtime_safety) struct {
    io_count: usize = 0,

    fn submitIo(db: *@This()) void {
        db.io_count += 1;
    }
    fn completeIo(db: *@This()) void {
        db.io_count -= 1;
    }
    fn assertThereAreTasks(db: *const @This()) void {
        const self = @fieldParentPtr(EventLoop, "debug", db);
        std.debug.assert(self.debug.io_count > 0 or
            self.wait_q.len > 0 or
            self.cpu_q.len > 0);
    }
} else struct {
    fn submitIo(_: @This()) void {}
    fn completeIo(_: @This()) void {}
    fn assertThereAreTasks(_: @This()) void {}
} = .{},

const EventLoop = @This();
const TaskQueue = std.TailQueue(anyframe);

pub fn init() !EventLoop {
    const uring = try os.linux.IO_Uring.init(4096, 0);
    return EventLoop{ .uring = uring };
}
pub fn deinit(self: *EventLoop) void {
    std.debug.assert(self.wait_q.len == 0);
    std.debug.assert(self.cpu_q.len == 0);
    self.uring.deinit();
}

pub fn run(self: *EventLoop, comptime func: anytype, args: anytype) !void {
    var done = false; // TODO: thread
    var frame = async struct {
        fn wrapper(wargs: anytype, wdone: *bool) !void {
            try @call(.{}, func, wargs);
            wdone.* = true;
        }
    }.wrapper(args, &done);

    // TODO: thread - this will probably need a lot of work
    while (!done) {
        // This could trigger if a function suspends without informing the event loop
        self.debug.assertThereAreTasks();

        // Prioritize whichever queue is longest
        switch (longest(.{
            .io = self.uring.cq_ready(),
            .wait = if (!self.waiting) self.wait_q.len else 0,
            .cpu = self.cpu_q.len,
        })) {
            .io => {
                const cqe = try self.uring.copy_cqe();
                const data = @intToPtr(*SubmissionData, cqe.user_data);
                data.res = cqe.res;
                resume data.frame;
            },
            .wait => {
                var node_opt = self.wait_q.first;
                while (node_opt) |node| {
                    resume node.data;
                    if (self.waiting) {
                        node_opt = node.next;
                    } else {
                        break;
                    }
                }
                continue; // We've not run any tasks so skip to the next loop iteration
            },
            .cpu => resume self.cpu_q.pop().?.data,
        }

        self.waiting = false; // We've run a task, so we can retry waiting tasks now
    }
    nosuspend {
        try await frame;
    }
}
fn longest(queues: anytype) std.meta.FieldEnum(@TypeOf(queues)) {
    const T = @TypeOf(queues);
    const E = std.meta.FieldEnum(T);
    const fields = comptime std.meta.fieldNames(T);

    var n: usize = @field(queues, fields[0]);
    var q = @field(E, fields[0]);

    inline for (fields[1..]) |field| {
        if (n < @field(queues, field)) {
            n = @field(queues, field);
            q = @field(E, field);
        }
    }

    return q;
}

/// Yield to the event loop, allowing other tasks to run.
/// Can be used by CPU-bound tasks to run concurrently with other tasks.
pub fn yield(self: *EventLoop) void {
    var node = TaskQueue.Node{ .data = @frame() };
    self.cpu_q.prepend(&node);
    suspend {}
}

/// Yield to the event loop, waiting for at least one other task to progress.
/// Can be used by task-bound tasks to wait on one or more other tasks.
pub fn wait(self: *EventLoop) Waiter {
    return .{ .loop = self };
}
// TODO: thread
pub const Waiter = struct {
    loop: *EventLoop,
    node: TaskQueue.Node = .{ .data = undefined },

    pub fn start(self: *Waiter) void {
        self.node.data = @frame();
        self.loop.wait_q.prepend(&self.node);
        suspend {}
    }
    pub fn retry(self: *Waiter) void {
        self.loop.waiting = true;
        self.node.data = @frame();
        suspend {}
    }
    pub fn finish(self: *Waiter) void {
        self.loop.waiting = false;
        self.loop.wait_q.remove(&self.node);
    }
};

pub fn runDetached(self: *EventLoop, allocator: *std.mem.Allocator, comptime func: anytype, args: anytype) !void {
    _ = self;
    const Args = @TypeOf(args);
    const wrapper = struct {
        fn wrapper(loop: *EventLoop, walloc: *std.mem.Allocator, wargs: Args) void {
            loop.yield();
            @call(.{}, func, wargs);
            suspend {
                walloc.destroy(@frame());
            }
        }
    }.wrapper;
    const frame = try allocator.create(@Frame(wrapper));
    frame.* = async wrapper(self, allocator, args);
}

/// Wait for completion of any of the provided futures
// TODO: allow anyframe instead of needing Future. See ziglang/zig#3164
// TODO: thread
pub fn any(self: *EventLoop, alternatives: anytype) !AnyRet(@TypeOf(alternatives)) {
    const Alts = @TypeOf(alternatives);
    const Ret = AnyRet(Alts);
    const fields = comptime std.meta.fieldNames(Alts);

    // Launch waiters
    inline for (fields) |field| {
        const future = @field(alternatives, field);
        if (future.value) |value| {
            return @unionInit(Ret, field, value);
        }
        if (!future.waiting) {
            _ = async @field(alternatives, field).wait();
        }
    }

    // Wait for completion
    var w = self.wait();
    w.start();
    while (true) {
        // Slow for large numbers of alternatives, might be worth using a flag
        inline for (fields) |field| {
            const future = @field(alternatives, field);
            if (future.value) |value| {
                w.finish();
                return @unionInit(Ret, field, value);
            }
        }

        w.retry();
    }
}
// TODO: support pointer to struct as well as struct of pointers
pub fn AnyRet(comptime Alts: type) type {
    var fields: [std.meta.fields(Alts).len]std.builtin.TypeInfo.UnionField = undefined;
    for (std.meta.fields(Alts)) |field, i| {
        const ptr = @typeInfo(field.field_type).Pointer;
        if (ptr.is_const or !@hasDecl(ptr.child, "Value")) {
            @compileError(std.fmt.comptimePrint("Expected pointer to future, got {s} (field '{}')", .{
                @typeName(field.field_type),
                std.fmt.fmtSliceEscapeLower(field.name),
            }));
        }
        const T = ptr.child.Value;
        fields[i] = .{ .name = field.name, .field_type = T, .alignment = @alignOf(T) };
    }

    // Workaround for ziglang/zig#8114. Why does it work? No clue!
    var ti = @typeInfo(union { _: void });
    ti.Union.tag_type = std.meta.FieldEnum(Alts);
    ti.Union.fields = &fields;
    return @Type(ti);
}

pub const listen = @import("Listener.zig").open;
pub const connect = @import("Socket.zig").open;
pub const signalOpen = @import("SignalFile.zig").open;

//// For internal use ////

pub fn close(self: *EventLoop, fd: os.fd_t) void {
    const res = self.submit(.close, .{fd}) catch {
        os.close(fd); // We want to close even if it means blocking
        return;
    };
    switch (errno(res)) {
        os.EBADF => unreachable, // Always a race condition.
        os.EINTR => {}, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => {},
    }
}

pub fn read(self: *EventLoop, fd: os.fd_t, buf: []u8) ReadError!u31 {
    const res = try self.submit(.read, .{ fd, buf, 0 });
    switch (errno(res)) {
        0 => return @intCast(u31, res),

        os.EINVAL => unreachable,
        os.EFAULT => unreachable,
        os.EAGAIN => return error.WouldBlock,
        os.EBADF => return error.NotOpenForReading, // Can be a race condition.
        os.EIO => return error.InputOutput,
        os.EISDIR => return error.IsDir,
        os.ENOBUFS => return error.SystemResources,
        os.ENOMEM => return error.SystemResources,
        else => |err| return os.unexpectedErrno(err),
    }
}
pub const ReadError = error{
    WouldBlock,
    NotOpenForReading,
    InputOutput,
    IsDir,
    SystemResources,
} || SubmitError;

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

const SubmitError = @typeInfo(@typeInfo(@TypeOf(os.linux.IO_Uring.submit)).Fn.return_type.?).ErrorUnion.error_set;
fn submit(self: *EventLoop, comptime op: DeclEnum(os.linux.IO_Uring), args: anytype) SubmitError!i32 {
    var data = SubmissionData{ .frame = @frame() };
    _ = @call(.{}, @field(self.uring, @tagName(op)), .{@ptrToInt(&data)} ++ args) catch |err| switch (err) {
        error.SubmissionQueueFull => {
            @panic("TODO");
        },
    };

    self.debug.submitIo();
    defer self.debug.completeIo();
    suspend _ = try self.uring.submit(); // TODO: batch submissions?

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

fn errno(res: i32) u12 {
    return if (-4096 < res and res < 0)
        @intCast(u12, -res)
    else
        0;
}
