const std = @import("std");
const arch = @import("arch/arch.zig").current;
const mem = @import("memory.zig");
const Spinlock = @import("sync/Spinlock.zig");
const PageAllocator = @import("heap/PageAllocator.zig");
const gpa = @import("heap/gpa.zig");
const debug = @import("debug.zig");
const assert = std.debug.assert;
const pit = @import("drivers/x86/pit.zig");

pub const Tid = u32;
pub const OptTid = enum(Tid) {
    none = std.math.maxInt(Tid),
    _,

    pub fn wrap(x: ?Tid) OptTid {
        return if (x) |y| @enumFromInt(y) else .none;
    }

    pub fn unwrap(x: OptTid) ?Tid {
        if (x == .none) return null;
        return @intFromEnum(x);
    }
};

pub const ThreadEntry = fn (arg: usize) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 8 } }) noreturn;
const Thread = struct {
    state: State,
    prev: OptTid,
    next: OptTid,

    stack: ?[]mem.Page,
    cpu_state: *align(1) arch.cpu.State,
    ext_cpu_state: arch.cpu.ExtendedState,

    const State = union(enum) {
        dead,
        zombie,
        ready,
        running,
        blocked,
        sleeping: struct {
            until_ticks: u64,
        },
    };
};

pub var spinlock: Spinlock = .init;
pub var current_tid: Tid = undefined;
var idle_tid: Tid = undefined;

var threads: [64]Thread = undefined;
var thread_bump: Tid = 0;
var first_dead_thread: OptTid = .none;
var first_zombie_thread: OptTid = .none;
var first_sleeping_thread: OptTid = .none;

var first_ready_thread: OptTid = .none;
var last_ready_thread: OptTid = .none;

pub fn init() void {
    idle_tid = spawnKernelThread(idleThread, .{}) catch @panic("cant spawn idle thread");
    unlinkThread(idle_tid);

    const tid = allocThread() catch @panic("cant alloc boot thread");
    const t = &threads[tid];

    t.* = .{
        .state = .running,
        .prev = .none,
        .next = .none,

        // null bc i dont want this to get deallocated when the boot thread exits
        .stack = null,
        .cpu_state = undefined,
        .ext_cpu_state = .zero,
    };
    current_tid = tid;
}

fn WrapThreadFunc(func: anytype) ThreadEntry {
    return struct {
        const Func = @TypeOf(func);
        const Ret = @typeInfo(Func).@"fn".return_type.?;
        const Args = std.meta.ArgsTuple(Func);

        fn raw(arg: usize) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 8 } }) noreturn {
            const args_ptr: *Args = @ptrFromInt(arg);
            const args = args_ptr.*;
            gpa.allocator.destroy(args_ptr);

            switch (@typeInfo(Ret)) {
                .noreturn => @call(.auto, func, args),
                .void => {
                    @call(.auto, func, args);
                    exitThread();
                },
                .error_union => |eu| {
                    if (eu.payload != void)
                        @compileError("bad return value for thread function");

                    @call(.auto, func, args) catch |err| debug.dumpErrorAndPanic(err);
                    exitThread();
                },
                else => @compileError("bad return value for thread function"),
            }
        }
    }.raw;
}

pub fn spawnKernelThread(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !Tid {
    const Args = @TypeOf(args);
    const args_ptr = try gpa.allocator.create(Args);
    errdefer gpa.allocator.destroy(args_ptr);
    args_ptr.* = args;

    const stack_size = 32 * 1024;
    const stack = try PageAllocator.global.alloc(stack_size / mem.page_size, .{
        .cache_mode = .full,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    errdefer PageAllocator.global.free(stack);

    return spawnKernelThreadRaw(&WrapThreadFunc(func), @intFromPtr(args_ptr), stack);
}

pub fn spawnKernelThreadRaw(func: ?*const ThreadEntry, arg: usize, stack: []mem.Page) !Tid {
    const lock = spinlock.lock();
    defer lock.unlock();

    const tid = try allocThread();
    errdefer freeThread(tid);
    const t = &threads[tid];

    const top = @intFromPtr(stack.ptr + stack.len);
    const state: *align(1) arch.cpu.State = @ptrFromInt(top - @sizeOf(arch.cpu.State));
    state.* = .init(.{
        .entry = @intFromPtr(func),
        .arg = arg,
        .stack_ptr = top,
        .phys_page_table = @intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base,
    });

    t.* = .{
        .state = .ready,
        .next = .none,
        .prev = .none,

        .stack = stack,
        .ext_cpu_state = .zero,
        .cpu_state = state,
    };

    linkReadyThread(tid);
    return tid;
}

pub fn sleepTicks(ticks: u64) void {
    schedule(.{ .sleeping = .{
        .until_ticks = pit.ticks.load(.monotonic) + ticks + 1,
    } });
}

pub fn sleepNs(ns: u64) void {
    sleepTicks((ns + pit.period_ns - 1) / pit.period_ns);
}

pub fn exitThread() noreturn {
    _ = spinlock.lock();
    reapZombies();
    wakeSleeping();

    const last_tid = current_tid;
    const last = &threads[last_tid];
    std.debug.assert(last.state == .running);
    std.debug.assert(last.prev == .none);
    std.debug.assert(last.next == .none);
    last.state = .zombie;
    last.next = first_zombie_thread;
    first_zombie_thread = .wrap(last_tid);

    const next_tid = chooseThread();
    const next = &threads[next_tid];
    next.state = .running;

    current_tid = next_tid;
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn preempt() noreturn {
    _ = spinlock.lock();
    reapZombies();
    wakeSleeping();

    const last_tid = current_tid;
    const last = &threads[last_tid];
    std.debug.assert(last.state == .running);

    last.state = .ready;
    if (last_tid != idle_tid) linkReadyThread(last_tid);

    const next_tid = chooseThread();
    const next = &threads[next_tid];
    next.state = .running;

    current_tid = next_tid;
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn saveState(state: *align(1) arch.cpu.State) void {
    const t = &threads[current_tid];
    t.ext_cpu_state.save();
    t.cpu_state = state;
}

pub fn schedule(next_state: Thread.State) void {
    const lock = spinlock.lock();
    if (scheduleLockHeld(next_state)) {
        // arch.cpu.State.saveAndRestore already released the lock
        arch.interrupt.set(lock.int_enable);
    } else {
        lock.unlock();
    }
}

/// returns true if the context switch happened
pub fn scheduleLockHeld(next_state: Thread.State) bool {
    wakeSleeping();

    const last_tid = current_tid;
    const last = &threads[last_tid];
    assert(last.state == .running);

    var last_state: arch.cpu.State = undefined;
    last.cpu_state = &last_state;

    last.state = next_state;
    switch (next_state) {
        .dead, .zombie, .running => unreachable,
        .blocked => {},
        .sleeping => linkSleepingThread(last_tid),
        .ready => linkReadyThread(last_tid),
    }

    const next_tid = chooseThread();
    const next = &threads[next_tid];
    next.state = .running;
    if (next_tid == last_tid) return false;

    current_tid = next_tid;
    next.ext_cpu_state.load();
    next.cpu_state.saveAndRestore(last.cpu_state);
    return true;
}

/// assumes scheduler lock is held
fn wakeSleeping() void {
    const ticks = pit.ticks.load(.monotonic);
    while (true) {
        const tid = first_sleeping_thread.unwrap() orelse break;
        const t = &threads[tid];
        if (t.state.sleeping.until_ticks > ticks) break;

        assert(t.prev == .none);
        first_sleeping_thread = t.next;
        if (t.next.unwrap()) |next_tid| {
            threads[next_tid].prev = .none;
        }
        t.next = .none;

        t.state = .ready;
        linkReadyThread(tid);
    }
}

/// assumes scheduler lock is held
fn chooseThread() Tid {
    if (first_ready_thread.unwrap()) |tid| {
        const t = &threads[tid];
        assert(t.state == .ready);

        if (t.next.unwrap()) |next_tid| {
            threads[next_tid].prev = .none;
        } else {
            last_ready_thread = .none;
        }

        first_ready_thread = t.next;
        t.prev = .none;
        t.next = .none;
        return tid;
    }

    const t = &threads[idle_tid];
    assert(t.state == .ready);
    assert(t.prev == .none);
    assert(t.next == .none);
    return idle_tid;
}

/// assumes scheduler lock is held
fn reapZombies() void {
    while (true) {
        const tid = first_zombie_thread.unwrap() orelse return;
        const t = &threads[tid];
        first_zombie_thread = t.next;

        if (t.stack) |stack| PageAllocator.global.free(stack);
        freeThread(tid);
    }
}

/// assumes scheduler lock is held
fn allocThread() !Tid {
    if (thread_bump < threads.len) {
        const tid = thread_bump;
        thread_bump += 1;
        return tid;
    }

    const tid = first_dead_thread.unwrap() orelse return error.OutOfThreads;
    const t = &threads[tid];
    assert(t.state == .dead);
    assert(t.prev == .none);

    if (t.next.unwrap()) |other_tid| {
        const other = &threads[other_tid];
        assert(other.state == .dead);
        assert(other.prev.unwrap() == tid);
        other.prev = .none;
    }
    first_dead_thread = t.next;

    t.* = .{
        .state = .dead,
        .prev = .none,
        .next = .none,
        .cpu_state = undefined,
        .ext_cpu_state = undefined,
        .stack = undefined,
    };

    return tid;
}

/// assumes scheduler lock is held
fn freeThread(tid: Tid) void {
    const t = &threads[tid];
    t.state = .dead;

    unlinkThread(tid);

    if (first_dead_thread.unwrap()) |other_tid| {
        const other = &threads[other_tid];
        assert(other.state == .dead);
        assert(other.prev == .none);
        other.prev = .wrap(tid);
    }

    t.prev = .none;
    t.next = first_dead_thread;
    first_dead_thread = .wrap(tid);
}

/// assumes scheduler lock is held
fn unlinkThread(tid: Tid) void {
    const t = &threads[tid];
    switch (t.state) {
        .ready, .dead => {},
        else => unreachable,
    }

    if (t.prev.unwrap()) |prev_tid| {
        const prev = &threads[prev_tid];
        prev.next = t.next;
    } else if (t.state == .ready) {
        first_ready_thread = t.next;
    }

    if (t.next.unwrap()) |next_tid| {
        const next = &threads[next_tid];
        next.prev = t.prev;
    } else if (t.state == .ready) {
        last_ready_thread = t.prev;
    }

    t.prev = .none;
    t.next = .none;
}

/// assumes scheduler lock is held
fn linkReadyThread(tid: Tid) void {
    const t = &threads[tid];
    assert(t.state == .ready);
    assert(t.next == .none);
    assert(t.prev == .none);

    t.prev = last_ready_thread;
    if (last_ready_thread.unwrap()) |other_tid| {
        const other = &threads[other_tid];
        assert(other.state == .ready);
        assert(other.next == .none);
        other.next = .wrap(tid);
    } else {
        first_ready_thread = .wrap(tid);
    }

    last_ready_thread = .wrap(tid);
}

fn linkSleepingThread(tid: Tid) void {
    const t = &threads[tid];
    const ticks = t.state.sleeping.until_ticks;
    assert(t.next == .none);
    assert(t.prev == .none);

    var next_tid = first_sleeping_thread.unwrap() orelse {
        t.next = .none;
        t.prev = .none;
        first_sleeping_thread = .wrap(tid);
        return;
    };

    while (true) {
        const next = &threads[next_tid];
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
            threads[prev_tid].next = .wrap(tid);
        } else {
            first_sleeping_thread = .wrap(tid);
        }

        next.prev = .wrap(tid);
        return;
    }
}

fn idleThread() noreturn {
    arch.spinWait();
}

pub const testing = struct {
    const serial = @import("drivers/x86/serial.zig");
    var in_buffer: [8]u8 = undefined;
    var in_head: std.atomic.Value(u64) = .init(0);
    var in_tail: std.atomic.Value(u64) = .init(0);

    pub fn run() !void {
        _ = try spawnKernelThread(thread1, .{});
        _ = try spawnKernelThread(thread2, .{});
    }

    fn thread1() noreturn {
        std.log.info("thread 1", .{});

        while (true) {
            const byte = serial.read();
            while (in_head.load(.monotonic) >= in_tail.load(.monotonic) + in_buffer.len) {
                std.atomic.spinLoopHint();
            }

            in_buffer[in_head.load(.monotonic) % in_buffer.len] = byte;
            _ = in_head.fetchAdd(1, .release);
        }
    }

    fn thread2() noreturn {
        std.log.info("thread 2", .{});

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
