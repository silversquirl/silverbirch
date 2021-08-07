const EventLoop = @import("EventLoop.zig");

loop: *EventLoop,
// TODO: thread
count: usize = 0,

const WaitGroup = @This();

pub fn init(loop: *EventLoop) WaitGroup {
    return .{ .loop = loop };
}

/// Add a number of tasks to the wait group
// TODO: thread
pub fn add(self: *WaitGroup, n: usize) void {
    self.count += n;
}

/// Mark one task as completed
// TODO: thread
pub fn done(self: *WaitGroup) void {
    self.count -= 1;
}

/// Wait for all tasks to complete
// TODO: thread
pub fn wait(self: *WaitGroup) void {
    if (self.count == 0) return;

    var waiter = self.loop.wait();
    waiter.start();
    while (self.count > 0) {
        waiter.retry();
    }
    waiter.finish();
}
