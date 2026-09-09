const std = @import("std");
const Spinlock = @import("Spinlock.zig");
const scheduler = @import("../scheduler.zig");
const Mutex = @This();

spinlock: Spinlock,
state: State,
first_waiter: ?*Waiter,

pub const init: Mutex = .{
    .spinlock = .init,
    .state = .unlocked,
    .first_waiter = null,
};

const State = enum {
    unlocked,
    locked,
};

const Waiter = struct {
    tid: scheduler.Thread.Id,
    next: ?*Waiter,
};

pub fn lock(mutex: *Mutex) void {
    while (true) {
        const sl = mutex.spinlock.lock();

        if (mutex.state == .unlocked) {
            mutex.state = .locked;
            sl.unlock();
            return;
        }

        const tid = scheduler.current_tid;
        const thread = &scheduler.threads.items[tid];

        var waiter: Waiter = .{
            .tid = tid,
            .next = mutex.first_waiter,
        };

        mutex.first_waiter = &waiter;
        std.debug.assert(thread.state == .running);
        thread.state = .blocked;

        sl.unlock();
        scheduler.yield();
    }
}

pub fn unlock(mutex: *Mutex) void {
    const sl = mutex.spinlock.lock();
    defer sl.unlock();

    std.debug.assert(mutex.state == .locked);
    mutex.state = .unlocked;

    if (mutex.first_waiter) |waiter| {
        mutex.first_waiter = waiter.next;
        const thread = &scheduler.threads.items[waiter.tid];
        std.debug.assert(thread.state == .blocked);
        thread.state = .asleep;
    }
}
