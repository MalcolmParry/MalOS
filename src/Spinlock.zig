const std = @import("std");
const arch = @import("arch/arch.zig").current;
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
        arch.interrupt.set(int);
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

        arch.interrupt.set(int);
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
        arch.interrupt.set(l.int_enable);
    }
};
