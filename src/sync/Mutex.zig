const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("Spinlock.zig");
const scheduler = @import("../scheduler.zig");
const Mutex = @This();

state: std.atomic.Value(u32),
first_waiter: ?*Waiter,
last_waiter: ?*Waiter,

pub const init: Mutex = .{
    .state = .init(0),
    .first_waiter = null,
    .last_waiter = null,
};

const Waiter = struct {
    tid: scheduler.Tid,
    next: ?*Waiter,
};

const locked: u32 = 1 << 0;
const contended: u32 = 1 << 1;
const working: u32 = 1 << 2;

pub fn lock(m: *Mutex) void {
    std.debug.assert(arch.interrupt.isEnabled());

    if (m.state.cmpxchgStrong(0, locked, .acquire, .monotonic) == null) {
        @branchHint(.likely);
        return;
    }

    arch.interrupt.disable();
    const s = m.acquireWorking();
    if (s & locked == 0) {
        m.state.store(locked, .release);
        arch.interrupt.enable();
        return;
    }

    var waiter: Waiter = .{
        .tid = scheduler.current_tid,
        .next = null,
    };

    if (m.last_waiter) |w| {
        w.next = &waiter;
    } else {
        m.first_waiter = &waiter;
    }
    m.last_waiter = &waiter;

    _ = scheduler.spinlock.lock();
    m.state.store(locked | contended, .release);
    std.debug.assert(scheduler.scheduleLockHeld(.blocked));
    arch.interrupt.enable();
}

pub fn unlock(m: *Mutex) void {
    std.debug.assert(arch.interrupt.isEnabled());

    if (m.state.cmpxchgStrong(locked, 0, .release, .monotonic) == null) {
        @branchHint(.likely);
        return;
    }

    arch.interrupt.disable();
    _ = acquireWorking(m);
    const w = m.first_waiter.?;

    m.first_waiter = w.next;
    if (w.next == null)
        m.last_waiter = null;

    m.state.store(locked | if (w.next != null) contended else 0, .release);
    scheduler.wake(w.tid);
    arch.interrupt.enable();
}

fn acquireWorking(m: *Mutex) u32 {
    while (true) {
        const last = m.state.fetchOr(working, .acquire);
        if (last & working == 0) return last;
        while (m.state.load(.monotonic) & working != 0) std.atomic.spinLoopHint();
    }
}
