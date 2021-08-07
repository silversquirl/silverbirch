const EventLoop = @import("EventLoop.zig");

loop: *EventLoop,
// TODO: thread
value: bool = false,

const Flag = @This();

pub fn init(loop: *EventLoop) Flag {
    return .{ .loop = loop };
}

/// Clear the flag. Returns true if it was changed, false otherwise
// TODO: thread
pub fn clear(self: *Flag) bool {
    const value = self.value;
    self.value = false;
    return value != self.value;
}

/// Set the flag. Returns true if it was changed, false otherwise
// TODO: thread
pub fn set(self: *Flag) bool {
    const value = self.value;
    self.value = true;
    return value != self.value;
}

/// Wait for the flag to become set
// TODO: thread
pub fn wait(self: *Flag) void {
    if (self.value) return;

    var waiter = self.loop.wait();
    waiter.start();
    while (!self.value) {
        waiter.retry();
    }
    waiter.finish();
}
