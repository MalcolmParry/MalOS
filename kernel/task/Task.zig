const std = @import("std");
const mem = @import("../memory.zig");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const PageAllocator = @import("../heap/PageAllocator.zig");
const gpa = @import("../heap/gpa.zig");
const scheduler = @import("scheduler.zig");
const debug = @import("../debug.zig");
const vfs = @import("../fs/vfs/vfs.zig");
const abi = @import("abi");
const Object = @import("../object/Object.zig");
const AddressSpace = @import("AddressSpace.zig");
const Task = @This();
const assert = std.debug.assert;

state: State,
prev: OptTid,
next: OptTid,

/// null if this uses the global kernel table
addr_space: ?*AddressSpace,
handle_table: ?*HandleTable,
kernel_stack: ?[]mem.Page,
cpu_state: ?*align(1) arch.cpu.State,
arch_specific: arch.cpu.PerTask,

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

pub const HandleDesc = struct {
    obj: *Object,
    rights: abi.Rights,
};

pub const HandleTable = struct {
    ref_count: std.atomic.Value(u32),
    map: std.AutoHashMapUnmanaged(abi.Handle, HandleDesc),
    lock: Spinlock,
    bump: u32,

    pub fn acquire(table: *HandleTable) void {
        const prev = table.ref_count.fetchAdd(1, .monotonic);
        assert(prev != 0);
    }

    pub fn release(table: *HandleTable) void {
        const prev = table.ref_count.fetchSub(1, .acq_rel);
        assert(prev != 0);
        if (prev == 1) table.destroy();
    }

    pub fn create() !*HandleTable {
        const table = try gpa.allocator.create(HandleTable);
        table.* = .{
            .ref_count = .init(1),
            .map = .empty,
            .lock = .init,
            .bump = 0,
        };
        return table;
    }

    pub fn destroy(table: *HandleTable) void {
        assert(table.ref_count.load(.monotonic) == 0);

        var iter = table.map.iterator();
        while (iter.next()) |kv| {
            const desc = kv.value_ptr.*;
            desc.obj.release();
        }

        table.map.deinit(gpa.allocator);
        gpa.allocator.destroy(table);
    }

    pub fn getLocked(table: *HandleTable, handle: abi.Handle) ?HandleDesc {
        return table.map.get(handle);
    }

    pub fn putLocked(table: *HandleTable, desc: HandleDesc) !abi.Handle {
        const handle: abi.Handle = @enumFromInt(table.bump);
        table.bump +|= 1;

        const kv = try table.map.getOrPut(gpa.allocator, handle);
        if (kv.found_existing) return error.TooManyHandles;

        kv.value_ptr.* = desc;
        return handle;
    }

    pub fn fetchRemoveLocked(table: *HandleTable, handle: abi.Handle) ?HandleDesc {
        const kv = table.map.fetchRemove(handle) orelse return null;
        return kv.value;
    }
};

pub var spinlock: Spinlock = .init;
pub var current_tid: Tid = undefined;
var tasks: [64]Task = undefined;
var task_bump: Tid.BackingInt = 0;

pub var first_dead: OptTid = .none;
pub var first_zombie: OptTid = .none;

pub const Entry = fn (arg: usize) callconv(arch.cpu.task_callconv) noreturn;
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
    });

    t.* = .{
        .state = .ready,
        .next = .none,
        .prev = .none,

        .addr_space = null,
        .handle_table = null,
        .kernel_stack = stack,
        .cpu_state = state,
        .arch_specific = undefined,
    };
    t.arch_specific.init();

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
        .handle_table = undefined,
        .cpu_state = undefined,
        .kernel_stack = undefined,
        .arch_specific = undefined,
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
        if (t.handle_table) |table| table.release();
        if (t.addr_space) |addr_space| addr_space.release();
        t.arch_specific.deinit();
        freeTask(tid);
    }
}
