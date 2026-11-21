const std = @import("std");
const mem = @import("../memory.zig");
const debug = @import("../debug.zig");
const boot_info = @import("../boot_info.zig");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const Object = @import("../object/Object.zig");
const Process = @import("Process.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const scheduler = @import("scheduler.zig");
const stack_alloc = @import("../heap/stack_alloc.zig");
const PerCpu = @import("../PerCpu.zig");
const Thread = @This();
const assert = std.debug.assert;

obj: Object,
/// owned by scheduler lock
state: State,
/// owned by scheduler lock
prev: ?*Thread,
/// owned by scheduler lock
next: ?*Thread,

/// null if this is kernel thread
proc: ?*Process,
/// owned by proc.lock
prev_sibling: ?*Thread,
/// owned by proc.lock
next_sibling: ?*Thread,

/// owned by scheduler lock
stack: ?[]mem.Page,
/// owned by scheduler lock
cpu_state: ?*align(1) arch.cpu.State,
/// owned by scheduler lock
arch_specific: arch.cpu.PerTask,

pub const State = union(enum) {
    initial,
    /// deinited but still has refs
    dead,

    ready,
    running,
    blocked,
    sleeping: struct {
        /// uses arch.time.getBootNs
        until_ns: u64,
    },
};

pub const CpuLocal = struct {
    current: *Thread,
    idle: *Thread,
    last_stack: ?[]mem.Page = null,
};

pub fn current() *Thread {
    return PerCpu.get().thread.current;
}

pub fn create(maybe_proc: ?*Process) !*Thread {
    const thread = try gpa.create(Thread);
    thread.* = .{
        .obj = .{
            .kind = .thread,
            .ref_count = .init(1),
        },
        .state = .initial,
        .prev = null,
        .next = null,

        .proc = maybe_proc,
        .prev_sibling = null,
        .next_sibling = null,

        .stack = null,
        .cpu_state = null,
        .arch_specific = .init,
    };

    if (maybe_proc) |proc| proc.obj.acquire();
    return thread;
}

pub fn destroy(thread: *Thread) void {
    assert(thread.obj.ref_count.load(.monotonic) == 0);
    assert(thread.state == .initial or thread.state == .dead);

    if (thread.stack) |x| stack_alloc.free(x);
    const maybe_proc = thread.proc;
    gpa.destroy(thread);
    if (maybe_proc) |proc| proc.obj.release();
}

pub fn maybeAllocStackLocked(thread: *Thread) !void {
    if (thread.stack != null) return;
    thread.stack = try stack_alloc.alloc();
}

pub fn start(thread: *Thread, state: *align(1) const arch.cpu.State) !void {
    const l = scheduler.lock.lock();
    defer l.unlock();
    try thread.startLocked(state);
}

pub fn startLocked(thread: *Thread, state: *align(1) const arch.cpu.State) !void {
    if (thread.state != .initial) return error.BadState;
    try thread.maybeAllocStackLocked();

    assert(thread.cpu_state == null);
    assert(thread.prev == null);
    assert(thread.next == null);
    if (thread.proc) |proc| try proc.linkLiveThread(thread);

    const stack = thread.stack.?;
    const base = @intFromPtr(stack.ptr + stack.len);
    const pushed_state: *align(1) arch.cpu.State = @ptrFromInt(base - @sizeOf(arch.cpu.State));
    pushed_state.* = state.*;
    thread.cpu_state = pushed_state;

    // running threads hold a ref on themselves
    thread.obj.acquire();
    thread.state = .ready;
    scheduler.linkReady(thread);
}

pub fn startWrapped(thread: *Thread, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const args_ptr = try gpa.create(@TypeOf(args));
    errdefer gpa.destroy(args_ptr);
    args_ptr.* = args;

    const l = scheduler.lock.lock();
    defer l.unlock();

    try thread.maybeAllocStackLocked();
    const stack = thread.stack.?;
    const state = arch.cpu.getInitThreadFrame(.{
        .entry = @intFromPtr(&WrapThreadFunc(func)),
        .arg = @intFromPtr(args_ptr),
        .stack_top = @intFromPtr(stack.ptr + stack.len),
    });

    try thread.startLocked(&state);
}

pub fn exitCurrent() noreturn {
    const l = scheduler.lock.lock();
    arch.paging.getGlobalKernelTable().use();
    var pc = PerCpu.get();
    const thread = pc.thread.current;

    assert(thread.state == .running);
    if (thread.proc) |proc| {
        thread.proc = null;
        l.unlock();
        proc.unlinkLiveThread(thread);
        proc.obj.release();
        _ = scheduler.lock.lock();
        pc = PerCpu.get();
    }

    if (pc.thread.last_stack) |last| stack_alloc.free(last);
    pc.thread.last_stack = if (thread.stack.?.ptr == boot_info.boot_stack.ptr) null else thread.stack;
    thread.stack = null;

    thread.state = .dead;
    thread.obj.release();

    const now = arch.time.getBootNsOrdered();
    scheduler.wakeSleeping(now);
    const next = scheduler.chooseThread();
    pc.thread.current = next;
    next.state = .running;
    arch.cpu.prepareThreadSwitch(next, null);

    scheduler.setPreemptionTimer(now, next == pc.thread.idle);
    const s = next.cpu_state.?;
    next.cpu_state = null;
    s.restore();
}

const ThreadFn = fn (arg: usize) callconv(arch.cpu.thread_callconv) noreturn;
pub fn spawnRaw(func: *const ThreadFn, arg: usize) !*Thread {
    const l = scheduler.lock.lock();
    defer l.unlock();

    const thread = try create(null);
    errdefer thread.obj.release();
    try thread.maybeAllocStackLocked();

    const stack = thread.stack.?;
    const state = arch.cpu.getInitThreadFrame(.{
        .entry = @intFromPtr(func),
        .arg = arg,
        .stack_top = @intFromPtr(stack.ptr + stack.len),
    });

    thread.startLocked(&state) catch unreachable;
    return thread;
}

pub fn spawn(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !*Thread {
    const Args = @TypeOf(args);
    const args_ptr = try gpa.create(Args);
    errdefer gpa.destroy(args_ptr);
    args_ptr.* = args;

    return spawnRaw(&WrapThreadFunc(func), @intFromPtr(args_ptr));
}

fn WrapThreadFunc(func: anytype) ThreadFn {
    return struct {
        const Func = @TypeOf(func);
        const Ret = @typeInfo(Func).@"fn".return_type.?;
        const Args = std.meta.ArgsTuple(Func);

        fn wrapThreadEntry(arg: usize) callconv(arch.cpu.thread_callconv) noreturn {
            const args_ptr: *Args = @ptrFromInt(arg);
            const args = args_ptr.*;
            gpa.destroy(args_ptr);

            switch (@typeInfo(Ret)) {
                .noreturn => {
                    @call(.auto, func, args);
                },
                .void => {
                    @call(.auto, func, args);
                    exitCurrent();
                },
                .error_union => |eu| {
                    switch (eu.payload) {
                        void, noreturn => {},
                        else => @compileError("bad return value for thread function"),
                    }

                    @call(.auto, func, args) catch |err| debug.dumpErrorAndPanic(err);
                    exitCurrent();
                },
                else => @compileError("bad return value for thread function"),
            }
        }
    }.wrapThreadEntry;
}
