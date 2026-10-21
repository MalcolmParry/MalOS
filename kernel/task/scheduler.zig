const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const assert = std.debug.assert;
const pit = @import("../drivers/x86/pit.zig");
const Task = @import("Task.zig");

pub const Tid = Task.Tid;
pub const OptTid = Task.OptTid;

var idle_tid: Tid = undefined;
var first_sleeping: OptTid = .none;
var first_ready: OptTid = .none;
var last_ready: OptTid = .none;

pub fn init() void {
    idle_tid = Task.spawnKernelTask(idleTask, .{}) catch @panic("cant spawn idle task");
    unlinkReady(idle_tid);

    const tid = Task.allocTask() catch @panic("cant alloc boot task");
    const t = tid.get();

    t.* = .{
        .state = .running,
        .prev = .none,
        .next = .none,

        .addr_space = null,
        // null bc i dont want this to get deallocated when the boot task exits
        .kernel_stack = null,
        .cpu_state = undefined,
        .ext_cpu_state = .zero,
    };
    Task.current_tid = tid;
}

pub fn sleepTicks(ticks: u64) void {
    schedule(.{ .sleeping = .{
        .until_ticks = pit.ticks.load(.monotonic) + ticks + 1,
    } });
}

pub fn sleepNs(ns: u64) void {
    sleepTicks((ns + pit.period_ns - 1) / pit.period_ns);
}

pub fn exitTask() noreturn {
    _ = Task.spinlock.lock();
    Task.reapZombies();
    wakeSleeping();

    const last_tid = Task.current_tid;
    const last = last_tid.get();
    std.debug.assert(last.state == .running);
    std.debug.assert(last.prev == .none);
    std.debug.assert(last.next == .none);
    last.state = .zombie;
    last.next = Task.first_zombie;
    Task.first_zombie = .wrap(last_tid);

    const next_tid = chooseTask();
    const next = next_tid.get();
    next.state = .running;

    Task.current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn preempt() noreturn {
    _ = Task.spinlock.lock();
    Task.reapZombies();
    wakeSleeping();

    const last_tid = Task.current_tid;
    const last = last_tid.get();
    std.debug.assert(last.state == .running);

    last.state = .ready;
    if (last_tid != idle_tid) linkReadyTask(last_tid);

    const next_tid = chooseTask();
    const next = next_tid.get();
    next.state = .running;

    Task.current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn saveState(state: *align(1) arch.cpu.State) void {
    const t = Task.current_tid.get();
    t.ext_cpu_state.save();
    t.cpu_state = state;
}

pub fn schedule(next_state: Task.State) void {
    const lock = Task.spinlock.lock();
    if (scheduleLockHeld(next_state)) {
        // arch.cpu.State.saveAndRestore already released the lock
        arch.interrupt.set(lock.int_enable);
    } else {
        lock.unlock();
    }
}

/// returns true if the context switch happened
pub fn scheduleLockHeld(next_state: Task.State) bool {
    wakeSleeping();

    const last_tid = Task.current_tid;
    const last = last_tid.get();
    assert(last.state == .running);

    var last_state: arch.cpu.State = undefined;
    last.cpu_state = &last_state;

    last.state = next_state;
    switch (next_state) {
        .dead, .zombie, .running => unreachable,
        .blocked => {},
        .sleeping => linkSleepingTask(last_tid),
        .ready => linkReadyTask(last_tid),
    }

    const next_tid = chooseTask();
    const next = next_tid.get();
    next.state = .running;
    if (next_tid == last_tid) return false;

    Task.current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.saveAndRestore(last.cpu_state);
    return true;
}

pub fn wake(tid: Tid) void {
    const lock = Task.spinlock.lock();
    defer lock.unlock();

    const t = tid.get();
    std.debug.assert(t.state == .blocked);
    t.state = .ready;
    linkReadyTask(tid);
}

/// assumes task list lock is held
pub fn makeReady(tid: Tid) void {
    const t = tid.get();
    assert(t.prev == .none);
    assert(t.next == .none);
    t.state = .ready;
    linkReadyTask(tid);
}

/// assumes task list lock is held
fn wakeSleeping() void {
    const ticks = pit.ticks.load(.monotonic);
    while (true) {
        const tid = first_sleeping.unwrap() orelse break;
        const t = tid.get();
        if (t.state.sleeping.until_ticks > ticks) break;

        assert(t.prev == .none);
        first_sleeping = t.next;
        if (t.next.unwrap()) |next_tid| {
            next_tid.get().prev = .none;
        }
        t.next = .none;

        t.state = .ready;
        linkReadyTask(tid);
    }
}

/// assumes task list lock is held
fn chooseTask() Tid {
    if (first_ready.unwrap()) |tid| {
        const t = tid.get();
        assert(t.state == .ready);

        if (t.next.unwrap()) |next_tid| {
            next_tid.get().prev = .none;
        } else {
            last_ready = .none;
        }

        first_ready = t.next;
        t.prev = .none;
        t.next = .none;
        return tid;
    }

    const t = idle_tid.get();
    assert(t.state == .ready);
    assert(t.prev == .none);
    assert(t.next == .none);
    return idle_tid;
}

/// assumes task list lock is held
fn linkReadyTask(tid: Tid) void {
    const t = tid.get();
    assert(t.state == .ready);
    assert(t.next == .none);
    assert(t.prev == .none);

    t.prev = last_ready;
    if (last_ready.unwrap()) |other_tid| {
        const other = other_tid.get();
        assert(other.state == .ready);
        assert(other.next == .none);
        other.next = .wrap(tid);
    } else {
        first_ready = .wrap(tid);
    }

    last_ready = .wrap(tid);
}

/// assumes task list lock is held
fn unlinkReady(tid: Tid) void {
    const t = tid.get();
    assert(t.state == .ready);

    if (t.prev.unwrap()) |prev_tid| {
        const prev = prev_tid.get();
        prev.next = t.next;
    } else {
        first_ready = t.next;
    }

    if (t.next.unwrap()) |next_tid| {
        const next = next_tid.get();
        next.prev = t.prev;
    } else {
        last_ready = t.prev;
    }

    t.prev = .none;
    t.next = .none;
}

/// assumes task list lock is held
fn linkSleepingTask(tid: Tid) void {
    const t = tid.get();
    const ticks = t.state.sleeping.until_ticks;
    assert(t.next == .none);
    assert(t.prev == .none);

    var next_tid = first_sleeping.unwrap() orelse {
        t.next = .none;
        t.prev = .none;
        first_sleeping = .wrap(tid);
        return;
    };

    while (true) {
        const next = next_tid.get();
        if (next.state.sleeping.until_ticks <= ticks) {
            if (next.next.unwrap()) |x| {
                next_tid = x;
                continue;
            }

            next.next = .wrap(tid);
            t.prev = .wrap(next_tid);
            t.next = .none;
            return;
        }

        t.next = .wrap(next_tid);
        t.prev = next.prev;

        if (next.prev.unwrap()) |prev_tid| {
            prev_tid.get().next = .wrap(tid);
        } else {
            first_sleeping = .wrap(tid);
        }

        next.prev = .wrap(tid);
        return;
    }
}

fn idleTask() noreturn {
    arch.spinWait();
}

pub const testing = struct {
    const serial = @import("../drivers/x86/serial.zig");
    const Mutex = @import("../sync/Mutex.zig");

    var in_buffer: [8]u8 = undefined;
    var in_head: std.atomic.Value(u64) = .init(0);
    var in_tail: std.atomic.Value(u64) = .init(0);
    var mutex: Mutex = .init;

    pub fn run() !void {
        _ = try Task.spawnKernelTask(task1, .{});
        _ = try Task.spawnKernelTask(task2, .{});
    }

    fn task1() noreturn {
        sleepNs(std.time.ns_per_ms * 50);
        mutex.lock();
        mutex.unlock();
        std.log.info("task 1", .{});

        while (true) {
            const byte = serial.read();
            while (in_head.load(.monotonic) >= in_tail.load(.monotonic) + in_buffer.len) {
                std.atomic.spinLoopHint();
            }

            in_buffer[in_head.load(.monotonic) % in_buffer.len] = byte;
            _ = in_head.fetchAdd(1, .release);
        }
    }

    fn task2() noreturn {
        mutex.lock();
        sleepNs(std.time.ns_per_ms * 100);
        mutex.unlock();

        std.log.info("task 2", .{});

        while (true) {
            while (in_head.load(.monotonic) == in_tail.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }

            const tail = in_tail.fetchAdd(1, .acquire);
            const byte = in_buffer[tail % in_buffer.len];
            serial.writer.print("\x1b[2K\r{d: >3}   0x{x:0>2}   '{c}'", .{ byte, byte, byte }) catch {};
        }
    }
};
