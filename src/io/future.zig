const std = @import("std");

pub fn Future(comptime Frame: type) type {
    _ = Frame;
    return struct {
        frame: Frame,
        value: ?Value = null,
        waiting: bool = false,

        pub const Value = FrameRet(Frame);

        const Self = @This();

        pub fn wait(self: *Self) Value {
            // TODO: thread
            if (self.value == null) {
                std.debug.assert(self.waiting == false);
                self.waiting = true;
                const value = await self.frame;
                self.value = value;
            }
            return self.value.?;
        }
    };
}

fn FrameRet(comptime Frame: type) type {
    switch (@typeInfo(Frame)) {
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Frame => |f| {
                const Fn = @TypeOf(f.function);
                return @typeInfo(Fn).Fn.return_type.?;
            },
            else => {},
        },
        .AnyFrame => |a| return a.child.?,
        else => {},
    }
    @compileError("Expected pointer to frame, got " ++ @typeName(Frame));
}
