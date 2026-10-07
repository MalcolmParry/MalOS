const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch/arch.zig").current;
const scheduler = @import("../scheduler.zig");
const Mutex = @This();

const debug_info = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

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
const owner_shift = 3;
const flags_mask: u32 = (1 << owner_shift) - 1;

comptime {
    std.debug.assert(@bitSizeOf(scheduler.Tid) <= 32 - owner_shift);
}

pub fn lock(m: *Mutex) void {
    std.debug.assert(arch.interrupt.isEnabled());
    const me = if (debug_info) @as(u32, scheduler.current_tid) << owner_shift else 0;

    if (m.state.cmpxchgStrong(0, locked | me, .acquire, .monotonic) == null) {
        @branchHint(.likely);
        return;
    }

    arch.interrupt.disable();
    const s = m.acquireWorking();

    if (s & locked == 0) {
        m.state.store(locked | me, .release);
        arch.interrupt.enable();
        return;
    }

    if (debug_info and s & ~flags_mask == me) {
        @panic("mutex deadlocked");
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
    m.state.store(locked | contended | (s & ~flags_mask), .release);
    std.debug.assert(scheduler.scheduleLockHeld(.blocked));
    arch.interrupt.enable();
}

pub fn unlock(m: *Mutex) void {
    std.debug.assert(arch.interrupt.isEnabled());
    const me = if (debug_info) @as(u32, scheduler.current_tid) << owner_shift else 0;

    if (debug_info) {
        const s = m.state.load(.monotonic);
        if (s & locked == 0 or s & ~flags_mask != me)
            @panic("mutex unlocked by non owning thread");
    }

    if (m.state.cmpxchgStrong(locked | me, 0, .release, .monotonic) == null) {
        @branchHint(.likely);
        return;
    }

    arch.interrupt.disable();
    _ = acquireWorking(m);
    const w = m.first_waiter.?;

    m.first_waiter = w.next;
    if (w.next == null)
        m.last_waiter = null;

    const c_bit = if (w.next != null) contended else 0;
    const owner = if (debug_info) @as(u32, w.tid) << owner_shift else 0;

    m.state.store(locked | c_bit | owner, .release);
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
