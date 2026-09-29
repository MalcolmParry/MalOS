const std = @import("std");
const Spinlock = @import("Spinlock.zig");
const scheduler = @import("../scheduler.zig");
const RwMutex = @This();

spinlock: Spinlock,
status: Status,
reader_count: u16,
first_waiting_reader: ?*Waiter,
first_waiting_writer: ?*Waiter,

pub const init: RwMutex = .{
    .spinlock = .init,
    .status = .unlocked,
    .reader_count = 0,
    .first_waiting_reader = null,
    .first_waiting_writer = null,
};

const Status = enum {
    unlocked,
    locked,
    locked_shared,
};

const Waiter = struct {
    tid: scheduler.Thread.Id,
    next: ?*Waiter,
};

pub fn lock(mutex: *RwMutex) void {
    while (true) {
        const l = mutex.spinlock.lock();

        switch (mutex.status) {
            .unlocked => {
                mutex.status = .locked;
                l.unlock();
                return;
            },
            .locked, .locked_shared => {
                var waiter: Waiter = .{
                    .tid = scheduler.current_tid,
                    .next = mutex.first_waiting_writer,
                };

                mutex.first_waiting_writer = &waiter;
                l.unlock();
                scheduler.block();
            },
        }
    }
}

pub fn unlock(mutex: *RwMutex) void {
    const l = mutex.spinlock.lock();
    defer l.unlock();
    std.debug.assert(mutex.status == .locked);

    if (mutex.first_waiting_writer) |waiter| {
        mutex.first_waiting_writer = waiter.next;
        scheduler.wake(waiter.tid);
    } else {
        var maybe_waiter = mutex.first_waiting_reader;
        while (maybe_waiter) |waiter| {
            maybe_waiter = waiter.next;
            scheduler.wake(waiter.tid);
        }

        mutex.first_waiting_reader = null;
    }

    mutex.status = .unlocked;
}

pub fn lockShared(mutex: *RwMutex) void {
    while (true) {
        const l = mutex.spinlock.lock();

        blk: switch (mutex.status) {
            .unlocked => {
                mutex.status = .locked_shared;
                mutex.reader_count += 1;
                l.unlock();
                return;
            },
            .locked => {
                var waiter: Waiter = .{
                    .tid = scheduler.current_tid,
                    .next = mutex.first_waiting_reader,
                };

                mutex.first_waiting_reader = &waiter;
                l.unlock();
                scheduler.block();
            },
            .locked_shared => {
                if (mutex.first_waiting_writer != null) continue :blk .locked;
                continue :blk .unlocked;
            },
        }
    }
}

pub fn unlockShared(mutex: *RwMutex) void {
    const l = mutex.spinlock.lock();
    defer l.unlock();
    std.debug.assert(mutex.status == .locked_shared);
    mutex.reader_count -= 1;

    if (mutex.reader_count == 0) {
        mutex.status = .unlocked;

        if (mutex.first_waiting_writer) |waiter| {
            mutex.first_waiting_writer = waiter.next;
            scheduler.wake(waiter.tid);
        }
    }
}
