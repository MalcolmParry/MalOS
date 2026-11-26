const std = @import("std");
const PerCpu = @import("../PerCpu.zig");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const assert = std.debug.assert;
const Thread = @import("Thread.zig");
const boot_info = @import("../boot_info.zig");

pub var idle_mask: PerCpu.Mask = .empty;
pub var lock: Spinlock = .init;
var first_sleeping: ?*Thread = null;
var first_ready: ?*Thread = null;
var last_ready: ?*Thread = null;

pub fn init() !void {
    const idle_thread = try Thread.spawn(idleThread, .{});
    unlinkReady(idle_thread);
    PerCpu.bsp.thread.idle = idle_thread;

    const boot: *Thread = try .create(null);
    boot.state = .running;
    boot.stack = boot_info.boot_stack;
    PerCpu.bsp.thread.current = boot;
}

pub fn initAp(cpu_local: *Thread.CpuLocal) !void {
    const idle_thread = try Thread.spawn(idleThread, .{});
    unlinkReady(idle_thread);

    const boot: *Thread = try .create(null);
    try boot.maybeAllocStackLocked();
    boot.state = .running;

    cpu_local.* = .{
        .idle = idle_thread,
        .current = boot,
    };
}

pub fn sleepNs(ns: u64) void {
    schedule(.{ .sleeping = .{
        .until_ns = arch.time.getBootNsOrdered() +| ns,
    } });
}

pub fn preempt(state: *align(1) arch.cpu.State) noreturn {
    _ = lock.lock();
    const pc = PerCpu.get();
    const now = arch.time.getBootNsOrdered();
    wakeSleeping(now);

    const last = pc.thread.current;
    assert(last.state == .running);
    last.state = .ready;
    last.cpu_state = state;
    if (last != pc.thread.idle) linkReady(last);

    const next = chooseThread();
    next.state = .running;
    prepareThreadSwitch(now, last, next);

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
    const now = arch.time.getBootNsOrdered();
    wakeSleeping(now);

    const last = Thread.current();
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
    prepareThreadSwitch(now, last, next);

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
    rescheduleFirstIdle();
}

pub fn updateIdleState(next: *Thread) void {
    const pc = PerCpu.get();
    _ = idle_mask.unset(pc.id, .monotonic);
    rescheduleFirstIdle();
    if (next == pc.thread.idle) _ = idle_mask.set(pc.id, .monotonic);
}

pub fn rescheduleFirstIdle() void {
    if (first_ready == null) return;
    if (idle_mask.findFirstAndUnset()) |cpu| blk: {
        if (cpu == PerCpu.get().id) break :blk;
        arch.sendRescheduleIpi(cpu);
    }
}

pub fn prepareThreadSwitch(now: u64, prev: ?*Thread, next: *Thread) void {
    const pc = PerCpu.get();
    pc.thread.current = next;
    updateIdleState(next);

    if (prev) |x| if (x.proc) |proc| {
        _ = proc.running_cpu_mask.unset(pc.id, .monotonic);
    };

    if (next.proc) |proc| {
        _ = proc.running_cpu_mask.set(pc.id, .seq_cst);
    }

    arch.cpu.prepareThreadSwitch(next, prev);
    setPreemptionTimer(now, next == pc.thread.idle);
}

/// assumes lock is held
pub fn setPreemptionTimer(now: u64, is_idle: bool) void {
    if (is_idle) if (first_sleeping) |thread| {
        arch.time.setTimerNs(thread.state.sleeping.until_ns - now);
        return;
    };

    arch.time.setTimerNs(10 * std.time.ns_per_ms);
}

/// assumes lock is held
pub fn wakeSleeping(now: u64) void {
    while (true) {
        const thread = first_sleeping orelse break;
        if (thread.state.sleeping.until_ns > now) break;

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

    const thread = PerCpu.get().thread.idle;
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
    const ns = t.state.sleeping.until_ns;
    assert(t.next == null);
    assert(t.prev == null);

    var next = first_sleeping orelse {
        t.next = null;
        t.prev = null;
        first_sleeping = t;
        return;
    };

    while (true) {
        if (next.state.sleeping.until_ns <= ns) {
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
