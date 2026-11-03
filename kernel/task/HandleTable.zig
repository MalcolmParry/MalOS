const std = @import("std");
const abi = @import("abi");
const Task = @import("Task.zig");
const Object = @import("../object/Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const assert = std.debug.assert;
const HandleTable = @This();

map: std.AutoHashMapUnmanaged(abi.Handle, Desc),
lock: Spinlock,
bump: u32,

pub const init: HandleTable = .{
    .map = .empty,
    .lock = .init,
    .bump = 0,
};

pub const Desc = struct {
    obj: *Object,
    rights: abi.Rights,
};

pub fn deinit(table: *HandleTable) void {
    var iter = table.map.iterator();
    while (iter.next()) |kv| {
        const desc = kv.value_ptr.*;
        desc.obj.release();
    }

    table.map.deinit(gpa);
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
    const proc = Task.current_tid.get().proc orelse @panic("cant get handle table in kernel thread");
    return &proc.handle_table;
}
