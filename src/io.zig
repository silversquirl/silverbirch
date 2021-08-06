pub const EventLoop = @import("io/EventLoop.zig");
pub const Future = @import("io/future.zig").Future;
pub const Listener = @import("io/Listener.zig");
pub const SignalFile = @import("io/SignalFile.zig");
pub const Socket = @import("io/Socket.zig");

pub fn future(frame: anytype) Future(@TypeOf(frame)) {
    return Future(@TypeOf(frame)){ .frame = frame };
}
