const std = @import("std");
const arch = @import("arch/arch.zig").current;
const mem = @import("memory.zig");
const Spinlock = @import("sync/Spinlock.zig");
const PageAllocator = @import("heap/PageAllocator.zig");
const gpa = @import("heap/gpa.zig");
const debug = @import("debug.zig");
const assert = std.debug.assert;
const pit = @import("drivers/x86/pit.zig");

// u29 bc mutex stores tid + 3 bits in u32
pub const Tid = u29;
pub const OptTid = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn wrap(x: ?Tid) OptTid {
        return if (x) |y| @enumFromInt(y) else .none;
    }

    pub fn unwrap(x: OptTid) ?Tid {
        if (x == .none) return null;
        return @intCast(@intFromEnum(x));
    }
};

pub const TaskEntry = fn (arg: usize) callconv(arch.cpu.task_callconv) noreturn;
const Task = struct {
    state: State,
    prev: OptTid,
    next: OptTid,

    kernel_stack: ?[]mem.Page,
    cpu_state: *align(1) arch.cpu.State,
    ext_cpu_state: arch.cpu.ExtendedState,

    fn kernelStackTop(t: *Task) usize {
        return if (t.kernel_stack) |x| @intFromPtr(x.ptr + x.len) else 0;
    }

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

var tasks: [64]Task = undefined;
var task_bump: Tid = 0;
var first_dead_task: OptTid = .none;
var first_zombie_task: OptTid = .none;
var first_sleeping_task: OptTid = .none;

var first_ready_task: OptTid = .none;
var last_ready_task: OptTid = .none;

pub fn init() void {
    idle_tid = spawnKernelTask(idleTask, .{}) catch @panic("cant spawn idle task");
    unlinkTask(idle_tid);

    const tid = allocTask() catch @panic("cant alloc boot task");
    const t = &tasks[tid];

    t.* = .{
        .state = .running,
        .prev = .none,
        .next = .none,

        // null bc i dont want this to get deallocated when the boot task exits
        .kernel_stack = null,
        .cpu_state = undefined,
        .ext_cpu_state = .zero,
    };
    current_tid = tid;
}

fn WrapTaskFunc(func: anytype) TaskEntry {
    return struct {
        const Func = @TypeOf(func);
        const Ret = @typeInfo(Func).@"fn".return_type.?;
        const Args = std.meta.ArgsTuple(Func);

        fn wrapTaskEntry(arg: usize) callconv(arch.cpu.task_callconv) noreturn {
            const args_ptr: *Args = @ptrFromInt(arg);
            const args = args_ptr.*;
            gpa.allocator.destroy(args_ptr);

            switch (@typeInfo(Ret)) {
                .noreturn => {
                    @call(.auto, func, args);
                },
                .void => {
                    @call(.auto, func, args);
                    exitTask();
                },
                .error_union => |eu| {
                    if (eu.payload != void)
                        @compileError("bad return value for task function");

                    @call(.auto, func, args) catch |err| debug.dumpErrorAndPanic(err);
                    exitTask();
                },
                else => @compileError("bad return value for task function"),
            }
        }
    }.wrapTaskEntry;
}

pub fn spawnKernelTask(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !Tid {
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

    return spawnKernelTaskRaw(&WrapTaskFunc(func), @intFromPtr(args_ptr), stack);
}

pub fn spawnKernelTaskRaw(func: ?*const TaskEntry, arg: usize, stack: []mem.Page) !Tid {
    const lock = spinlock.lock();
    defer lock.unlock();

    const tid = try allocTask();
    errdefer freeTask(tid);
    const t = &tasks[tid];

    const state = arch.cpu.pushInitTaskFrame(.{
        .entry = @intFromPtr(func),
        .arg = arg,
        .stack_top = @intFromPtr(stack.ptr + stack.len),
        .phys_page_table = @intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base,
    });

    t.* = .{
        .state = .ready,
        .next = .none,
        .prev = .none,

        .kernel_stack = stack,
        .ext_cpu_state = .zero,
        .cpu_state = state,
    };

    linkReadyTask(tid);
    return tid;
}

pub fn spawnUserTask(func: u64, table: *arch.paging.Table) !Tid {
    const stack_size = 32 * 1024;
    const stack = try PageAllocator.global.alloc(stack_size / mem.page_size, .{
        .cache_mode = .full,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    errdefer PageAllocator.global.free(stack);

    const lock = spinlock.lock();
    defer lock.unlock();

    const tid = try allocTask();
    errdefer freeTask(tid);
    const t = &tasks[tid];

    const state = arch.cpu.pushUserTaskFrame(.{
        .entry = func,
        .arg = 0,
        .stack_top = @intFromPtr(stack.ptr + stack.len),
        .phys_page_table = @intFromPtr(table) - @intFromPtr(mem.direct_map.ptr),
    });

    t.* = .{
        .state = .ready,
        .next = .none,
        .prev = .none,

        .kernel_stack = stack,
        .ext_cpu_state = .zero,
        .cpu_state = state,
    };

    linkReadyTask(tid);
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

pub fn exitTask() noreturn {
    _ = spinlock.lock();
    reapZombies();
    wakeSleeping();

    const last_tid = current_tid;
    const last = &tasks[last_tid];
    std.debug.assert(last.state == .running);
    std.debug.assert(last.prev == .none);
    std.debug.assert(last.next == .none);
    last.state = .zombie;
    last.next = first_zombie_task;
    first_zombie_task = .wrap(last_tid);

    const next_tid = chooseTask();
    const next = &tasks[next_tid];
    next.state = .running;

    current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn preempt() noreturn {
    _ = spinlock.lock();
    reapZombies();
    wakeSleeping();

    const last_tid = current_tid;
    const last = &tasks[last_tid];
    std.debug.assert(last.state == .running);

    last.state = .ready;
    if (last_tid != idle_tid) linkReadyTask(last_tid);

    const next_tid = chooseTask();
    const next = &tasks[next_tid];
    next.state = .running;

    current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.restore();
}

pub fn saveState(state: *align(1) arch.cpu.State) void {
    const t = &tasks[current_tid];
    t.ext_cpu_state.save();
    t.cpu_state = state;
}

pub fn schedule(next_state: Task.State) void {
    const lock = spinlock.lock();
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

    const last_tid = current_tid;
    const last = &tasks[last_tid];
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
    const next = &tasks[next_tid];
    next.state = .running;
    if (next_tid == last_tid) return false;

    current_tid = next_tid;
    arch.setKernelStackPtr(next.kernelStackTop());
    next.ext_cpu_state.load();
    next.cpu_state.saveAndRestore(last.cpu_state);
    return true;
}

pub fn wake(tid: Tid) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    const t = &tasks[tid];
    std.debug.assert(t.state == .blocked);
    t.state = .ready;
    linkReadyTask(tid);
}

/// assumes scheduler lock is held
fn wakeSleeping() void {
    const ticks = pit.ticks.load(.monotonic);
    while (true) {
        const tid = first_sleeping_task.unwrap() orelse break;
        const t = &tasks[tid];
        if (t.state.sleeping.until_ticks > ticks) break;

        assert(t.prev == .none);
        first_sleeping_task = t.next;
        if (t.next.unwrap()) |next_tid| {
            tasks[next_tid].prev = .none;
        }
        t.next = .none;

        t.state = .ready;
        linkReadyTask(tid);
    }
}

/// assumes scheduler lock is held
fn chooseTask() Tid {
    if (first_ready_task.unwrap()) |tid| {
        const t = &tasks[tid];
        assert(t.state == .ready);

        if (t.next.unwrap()) |next_tid| {
            tasks[next_tid].prev = .none;
        } else {
            last_ready_task = .none;
        }

        first_ready_task = t.next;
        t.prev = .none;
        t.next = .none;
        return tid;
    }

    const t = &tasks[idle_tid];
    assert(t.state == .ready);
    assert(t.prev == .none);
    assert(t.next == .none);
    return idle_tid;
}

/// assumes scheduler lock is held
fn reapZombies() void {
    while (true) {
        const tid = first_zombie_task.unwrap() orelse return;
        const t = &tasks[tid];
        first_zombie_task = t.next;

        if (t.kernel_stack) |stack| PageAllocator.global.free(stack);
        freeTask(tid);
    }
}

/// assumes scheduler lock is held
fn allocTask() !Tid {
    if (task_bump < tasks.len) {
        const tid = task_bump;
        task_bump += 1;
        return tid;
    }

    const tid = first_dead_task.unwrap() orelse return error.OutOfTasks;
    const t = &tasks[tid];
    assert(t.state == .dead);
    assert(t.prev == .none);

    if (t.next.unwrap()) |other_tid| {
        const other = &tasks[other_tid];
        assert(other.state == .dead);
        assert(other.prev.unwrap() == tid);
        other.prev = .none;
    }
    first_dead_task = t.next;

    t.* = .{
        .state = .dead,
        .prev = .none,
        .next = .none,
        .cpu_state = undefined,
        .ext_cpu_state = undefined,
        .kernel_stack = undefined,
    };

    return tid;
}

/// assumes scheduler lock is held
fn freeTask(tid: Tid) void {
    const t = &tasks[tid];
    t.state = .dead;

    unlinkTask(tid);

    if (first_dead_task.unwrap()) |other_tid| {
        const other = &tasks[other_tid];
        assert(other.state == .dead);
        assert(other.prev == .none);
        other.prev = .wrap(tid);
    }

    t.prev = .none;
    t.next = first_dead_task;
    first_dead_task = .wrap(tid);
}

/// assumes scheduler lock is held
fn unlinkTask(tid: Tid) void {
    const t = &tasks[tid];
    switch (t.state) {
        .ready, .dead => {},
        else => unreachable,
    }

    if (t.prev.unwrap()) |prev_tid| {
        const prev = &tasks[prev_tid];
        prev.next = t.next;
    } else if (t.state == .ready) {
        first_ready_task = t.next;
    }

    if (t.next.unwrap()) |next_tid| {
        const next = &tasks[next_tid];
        next.prev = t.prev;
    } else if (t.state == .ready) {
        last_ready_task = t.prev;
    }

    t.prev = .none;
    t.next = .none;
}

/// assumes scheduler lock is held
fn linkReadyTask(tid: Tid) void {
    const t = &tasks[tid];
    assert(t.state == .ready);
    assert(t.next == .none);
    assert(t.prev == .none);

    t.prev = last_ready_task;
    if (last_ready_task.unwrap()) |other_tid| {
        const other = &tasks[other_tid];
        assert(other.state == .ready);
        assert(other.next == .none);
        other.next = .wrap(tid);
    } else {
        first_ready_task = .wrap(tid);
    }

    last_ready_task = .wrap(tid);
}

fn linkSleepingTask(tid: Tid) void {
    const t = &tasks[tid];
    const ticks = t.state.sleeping.until_ticks;
    assert(t.next == .none);
    assert(t.prev == .none);

    var next_tid = first_sleeping_task.unwrap() orelse {
        t.next = .none;
        t.prev = .none;
        first_sleeping_task = .wrap(tid);
        return;
    };

    while (true) {
        const next = &tasks[next_tid];
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
            tasks[prev_tid].next = .wrap(tid);
        } else {
            first_sleeping_task = .wrap(tid);
        }

        next.prev = .wrap(tid);
        return;
    }
}

fn idleTask() noreturn {
    arch.spinWait();
}

pub const testing = struct {
    const serial = @import("drivers/x86/serial.zig");
    const Mutex = @import("sync/Mutex.zig");

    var in_buffer: [8]u8 = undefined;
    var in_head: std.atomic.Value(u64) = .init(0);
    var in_tail: std.atomic.Value(u64) = .init(0);
    var mutex: Mutex = .init;

    pub fn run() !void {
        _ = try spawnKernelTask(task1, .{});
        _ = try spawnKernelTask(task2, .{});
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
