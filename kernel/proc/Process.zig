const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const Spinlock = @import("../sync/Spinlock.zig");
const Object = @import("../object/Object.zig");
const HandleTable = @import("HandleTable.zig");
const AddressSpace = @import("AddressSpace.zig");
const Thread = @import("Thread.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Process = @This();

obj: Object,
handle_table: HandleTable,
addr_space: AddressSpace,
arch_specific: arch.cpu.PerProcess,

lock: Spinlock,
/// owned by lock
state: State,
/// owned by lock
first_thread: ?*Thread,

pub const State = enum {
    initial,
    running,
    dead,
};

pub fn create() !*Process {
    const proc = try gpa.create(Process);
    errdefer gpa.destroy(proc);

    proc.* = .{
        .obj = .{
            .kind = .process,
            .ref_count = .init(1),
        },
        .handle_table = .init,
        .addr_space = undefined,
        .arch_specific = undefined,

        .lock = .init,
        .state = .initial,
        .first_thread = null,
    };

    proc.arch_specific.init();
    errdefer proc.arch_specific.deinit();
    try proc.addr_space.init();
    return proc;
}

pub fn destroy(proc: *Process) void {
    std.debug.assert(proc.obj.ref_count.load(.monotonic) == 0);

    if (proc.state == .initial) {
        proc.handle_table.deinit();
        proc.addr_space.deinit();
        proc.arch_specific.deinit();
    }

    gpa.destroy(proc);
}

/// must be holding scheduler.lock
pub fn linkLiveThread(proc: *Process, thread: *Thread) !void {
    const l = proc.lock.lock();
    defer l.unlock();
    if (proc.state == .dead) return error.Dead;

    if (proc.state == .initial) proc.state = .running;
    if (proc.first_thread) |next| next.prev_sibling = thread;
    thread.next_sibling = proc.first_thread;
    proc.first_thread = thread;
}

pub fn unlinkLiveThread(proc: *Process, thread: *Thread) void {
    const l = proc.lock.lock();
    std.debug.assert(proc.state == .running);

    if (thread.next_sibling) |next| next.prev_sibling = thread.prev_sibling;
    if (thread.prev_sibling) |prev| {
        prev.next_sibling = thread.next_sibling;
    } else {
        proc.first_thread = thread.next_sibling;
    }

    if (proc.first_thread != null) {
        l.unlock();
        return;
    }

    proc.state = .dead;
    l.unlock();
    proc.handle_table.deinit();
    proc.addr_space.deinit();
    proc.arch_specific.deinit();
}
