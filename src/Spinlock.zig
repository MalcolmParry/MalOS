const std = @import("std");
const arch = @import("arch.zig");
const builtin = @import("builtin");
const Spinlock = @This();

status: std.atomic.Value(Status),

pub const init: Spinlock = .{ .status = .init(.unlocked) };

const Status = enum(u8) {
    unlocked,
    locked,
};

pub fn tryLock(sl: *Spinlock) ?Lock {
    const int = arch.interrupt.popDisable();

    if (sl.status.cmpxchgStrong(.unlocked, .locked, .acquire, .monotonic) == null) {
        return .{
            .sl = sl,
            .int_enable = int,
        };
    } else {
        if (int) arch.interrupt.enable();
        return null;
    }
}

pub fn lock(sl: *Spinlock) Lock {
    while (true) {
        const int = arch.interrupt.popDisable();
        if (sl.status.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) {
            @branchHint(.likely);

            return .{
                .sl = sl,
                .int_enable = int,
            };
        }

        if (int) arch.interrupt.enable();
        while (sl.status.load(.monotonic) == .locked) {
            if (builtin.is_test) @panic("");
            std.atomic.spinLoopHint();
        }
    }
}

pub const Lock = struct {
    sl: *Spinlock,
    int_enable: bool,

    pub fn unlock(l: Lock) void {
        std.debug.assert(l.sl.status.load(.monotonic) == .locked);
        l.sl.status.store(.unlocked, .release);
        if (l.int_enable) arch.interrupt.enable();
    }
};
