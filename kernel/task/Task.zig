const std = @import("std");
const mem = @import("../memory.zig");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const PageAllocator = @import("../heap/PageAllocator.zig");
const gpa = @import("../heap/gpa.zig");
const scheduler = @import("scheduler.zig");
const debug = @import("../debug.zig");
const Task = @This();
const assert = std.debug.assert;

state: State,
prev: OptTid,
next: OptTid,

/// null if this uses the global kernel table
addr_space: ?*AddressSpace,
kernel_stack: ?[]mem.Page,
cpu_state: *align(1) arch.cpu.State,
ext_cpu_state: arch.cpu.ExtendedState,

pub fn kernelStackTop(t: *Task) usize {
    return if (t.kernel_stack) |x| @intFromPtr(x.ptr + x.len) else 0;
}

pub const State = union(enum) {
    dead,
    zombie,
    ready,
    running,
    blocked,
    sleeping: struct {
        until_ticks: u64,
    },
};

// u29 bc mutex stores tid + 3 bits in u32
pub const Tid = enum(u29) {
    _,

    pub const BackingInt = u29;
    pub fn get(tid: Tid) *Task {
        return &tasks[@intFromEnum(tid)];
    }
};

pub const OptTid = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn wrap(x: ?Tid) OptTid {
        return if (x) |y| @enumFromInt(@intFromEnum(y)) else .none;
    }

    pub fn unwrap(x: OptTid) ?Tid {
        if (x == .none) return null;
        return @enumFromInt(@intFromEnum(x));
    }
};

pub const Entry = fn (arg: usize) callconv(arch.cpu.task_callconv) noreturn;

pub const AddressSpace = struct {
    table: *arch.paging.Table,
    ref_count: std.atomic.Value(u32),

    pub fn acquire(as: *AddressSpace) void {
        const prev = as.ref_count.fetchAdd(1, .monotonic);
        std.debug.assert(prev != 0);
    }

    pub fn release(as: *AddressSpace) void {
        const prev = as.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev == 1) as.destroy();
    }

    pub fn destroy(as: *AddressSpace) void {
        _ = as;
        @panic("not implemented");
    }
};

pub var spinlock: Spinlock = .init;
pub var current_tid: Tid = undefined;
var tasks: [64]Task = undefined;
var task_bump: Tid.BackingInt = 0;

pub var first_dead: OptTid = .none;
pub var first_zombie: OptTid = .none;

fn WrapTaskFunc(func: anytype) Task.Entry {
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
                    scheduler.exitTask();
                },
                .error_union => |eu| {
                    if (eu.payload != void)
                        @compileError("bad return value for task function");

                    @call(.auto, func, args) catch |err| debug.dumpErrorAndPanic(err);
                    scheduler.exitTask();
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

pub fn spawnKernelTaskRaw(func: ?*const Task.Entry, arg: usize, stack: []mem.Page) !Tid {
    const lock = spinlock.lock();
    defer lock.unlock();

    const tid = try allocTask();
    errdefer freeTask(tid);
    const t = tid.get();

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

        .addr_space = null,
        .kernel_stack = stack,
        .ext_cpu_state = .zero,
        .cpu_state = state,
    };

    scheduler.makeReady(tid);
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
    const t = tid.get();

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

        // TODO: fix this
        .addr_space = null,
        .kernel_stack = stack,
        .ext_cpu_state = .zero,
        .cpu_state = state,
    };

    scheduler.makeReady(tid);
    return tid;
}

/// assumes task list lock is held
pub fn allocTask() !Tid {
    if (task_bump < Task.tasks.len) {
        const tid = task_bump;
        task_bump += 1;
        return @enumFromInt(tid);
    }

    const tid = first_dead.unwrap() orelse return error.OutOfTasks;
    const t = tid.get();
    assert(t.state == .dead);
    assert(t.prev == .none);

    if (t.next.unwrap()) |other_tid| {
        const other = other_tid.get();
        assert(other.state == .dead);
        assert(other.prev.unwrap() == tid);
        other.prev = .none;
    }
    first_dead = t.next;

    t.* = .{
        .state = .dead,
        .prev = .none,
        .next = .none,
        .addr_space = undefined,
        .cpu_state = undefined,
        .ext_cpu_state = undefined,
        .kernel_stack = undefined,
    };

    return tid;
}

/// assumes task list lock is held
pub fn freeTask(tid: Tid) void {
    const t = tid.get();
    t.state = .dead;

    if (first_dead.unwrap()) |other_tid| {
        const other = other_tid.get();
        assert(other.state == .dead);
        assert(other.prev == .none);
        other.prev = .wrap(tid);
    }

    t.prev = .none;
    t.next = first_dead;
    first_dead = .wrap(tid);
}

/// assumes task list lock is held
pub fn reapZombies() void {
    while (true) {
        const tid = first_zombie.unwrap() orelse return;
        const t = tid.get();
        first_zombie = t.next;

        if (t.kernel_stack) |stack| PageAllocator.global.free(stack);
        freeTask(tid);
    }
}
