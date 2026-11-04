const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const assert = std.debug.assert;
const pit = @import("../drivers/x86/pit.zig");
const Thread = @import("Thread.zig");

pub var lock: Spinlock = .init;
var idle_thread: *Thread = undefined;
var first_sleeping: ?*Thread = null;
var first_ready: ?*Thread = null;
var last_ready: ?*Thread = null;

pub fn init() !void {
    idle_thread = try .spawn(idleThread, .{});
    unlinkReady(idle_thread);

    const boot: *Thread = try .create(null, null);
    boot.state = .running;
    Thread.current = boot;
}

pub fn sleepTicks(ticks: u64) void {
    schedule(.{ .sleeping = .{
        .until_ticks = pit.ticks.load(.monotonic) + ticks + 1,
    } });
}

pub fn sleepNs(ns: u64) void {
    sleepTicks((ns + pit.period_ns - 1) / pit.period_ns);
}

pub fn preempt(state: *align(1) arch.cpu.State) noreturn {
    _ = lock.lock();
    wakeSleeping();

    const last = Thread.current;
    assert(last.state == .running);
    last.state = .ready;
    last.cpu_state = state;
    if (last != idle_thread) linkReady(last);

    const next = chooseThread();
    next.state = .running;
    Thread.current = next;

    if (last != next) {
        arch.cpu.prepareThreadSwitch(next, last);
    }

    const s = next.cpu_state.?;
    next.cpu_state = null;
    s.restore();
}

pub fn schedule(next_state: Thread.State) void {
    const l = lock.lock();
    if (scheduleLockHeld(next_state)) {
        // arch.cpu.State.saveAndRestore already released the lock
        arch.interrupt.set(l.int_enable);
    } else {
        l.unlock();
    }
}

/// returns true if the context switch happened
pub fn scheduleLockHeld(next_state: Thread.State) bool {
    wakeSleeping();

    const last = Thread.current;
    assert(last.state == .running);

    last.state = next_state;
    switch (next_state) {
        .dead, .running, .initial => unreachable,
        .blocked => {},
        .sleeping => linkSleeping(last),
        .ready => linkReady(last),
    }

    const next = chooseThread();
    next.state = .running;
    if (next == last) return false;

    Thread.current = next;
    arch.cpu.prepareThreadSwitch(next, last);

    const s = next.cpu_state.?;
    next.cpu_state = null;
    s.saveAndRestore(&last.cpu_state);
    return true;
}

pub fn wake(thread: *Thread) void {
    const l = lock.lock();
    defer l.unlock();

    assert(thread.state == .blocked);
    thread.state = .ready;
    linkReady(thread);
}

/// assumes lock is held
pub fn wakeSleeping() void {
    const ticks = pit.ticks.load(.monotonic);
    while (true) {
        const thread = first_sleeping orelse break;
        if (thread.state.sleeping.until_ticks > ticks) break;

        assert(thread.prev == null);
        first_sleeping = thread.next;
        if (thread.next) |next| next.prev = null;
        thread.next = null;

        thread.state = .ready;
        linkReady(thread);
    }
}

/// assumes lock is held
pub fn chooseThread() *Thread {
    if (first_ready) |thread| {
        assert(thread.state == .ready);

        if (thread.next) |next| {
            next.prev = null;
        } else {
            last_ready = null;
        }

        first_ready = thread.next;
        thread.prev = null;
        thread.next = null;
        return thread;
    }

    const thread = idle_thread;
    assert(thread.state == .ready);
    assert(thread.prev == null);
    assert(thread.next == null);
    return thread;
}

/// assumes lock is held
pub fn linkReady(t: *Thread) void {
    assert(t.state == .ready);
    assert(t.next == null);
    assert(t.prev == null);

    t.prev = last_ready;
    if (last_ready) |prev| {
        assert(prev.state == .ready);
        assert(prev.next == null);
        prev.next = t;
    } else {
        first_ready = t;
    }

    last_ready = t;
}

/// assumes task list lock is held
fn unlinkReady(t: *Thread) void {
    assert(t.state == .ready);

    if (t.prev) |prev| {
        prev.next = t.next;
    } else {
        first_ready = t.next;
    }

    if (t.next) |next| {
        next.prev = t.prev;
    } else {
        last_ready = t.prev;
    }

    t.prev = null;
    t.next = null;
}

/// assumes task list lock is held
fn linkSleeping(t: *Thread) void {
    const ticks = t.state.sleeping.until_ticks;
    assert(t.next == null);
    assert(t.prev == null);

    var next = first_sleeping orelse {
        t.next = null;
        t.prev = null;
        first_sleeping = t;
        return;
    };

    while (true) {
        if (next.state.sleeping.until_ticks <= ticks) {
            if (next.next) |x| {
                next = x;
                continue;
            }

            next.next = t;
            t.prev = next;
            t.next = null;
            return;
        }

        t.next = next;
        t.prev = next.prev;

        if (next.prev) |prev| {
            prev.next = t;
        } else {
            first_sleeping = t;
        }

        next.prev = t;
        return;
    }
}

fn idleThread() noreturn {
    arch.spinWait();
}
