const std = @import("std");
const abi = @import("abi");
const Task = @import("Task.zig");
const Object = @import("../object/Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const assert = std.debug.assert;
const HandleTable = @This();

ref_count: std.atomic.Value(u32),
map: std.AutoHashMapUnmanaged(abi.Handle, Desc),
lock: Spinlock,
bump: u32,

pub const Desc = struct {
    obj: *Object,
    rights: abi.Rights,
};

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
    const table = try gpa.create(HandleTable);
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

    table.map.deinit(gpa);
    gpa.destroy(table);
}

pub fn getLocked(table: *HandleTable, handle: abi.Handle) ?Desc {
    return table.map.get(handle);
}

pub fn putLocked(table: *HandleTable, desc: Desc) !abi.Handle {
    const handle: abi.Handle = @enumFromInt(table.bump);
    table.bump +|= 1;

    const kv = try table.map.getOrPut(gpa, handle);
    if (kv.found_existing) return error.TooManyHandles;

    kv.value_ptr.* = desc;
    return handle;
}

pub fn fetchRemoveLocked(table: *HandleTable, handle: abi.Handle) ?Desc {
    const kv = table.map.fetchRemove(handle) orelse return null;
    return kv.value;
}

pub fn getCurrent() *HandleTable {
    return Task.current_tid.get().handle_table.?;
}
