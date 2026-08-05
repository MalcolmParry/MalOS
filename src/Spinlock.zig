const std = @import("std");
const builtin = @import("builtin");
const Spinlock = @This();

status: std.atomic.Value(Status),

pub const init: Spinlock = .{ .status = .init(.unlocked) };

const Status = enum(u8) {
    unlocked,
    locked,
};

pub fn tryLock(sl: *Spinlock) bool {
    return sl.status.cmpxchgStrong(.unlocked, .locked, .acquire, .monotonic) == null;
}

pub fn lock(sl: *Spinlock) void {
    while (true) {
        while (sl.status.load(.monotonic) == .locked) {
            if (builtin.is_test) @panic("");
            std.atomic.spinLoopHint();
        }

        if (sl.status.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) break;
    }
}

pub fn unlock(sl: *Spinlock) void {
    std.debug.assert(sl.status.load(.unordered) == .locked);
    sl.status.store(.unlocked, .release);
}
