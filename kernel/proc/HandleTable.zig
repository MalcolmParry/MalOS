const std = @import("std");
const abi = @import("abi").syscall;
const mem = @import("../mem/memory.zig");
const pmm = @import("../mem/pmm.zig");
const PerCpu = @import("../PerCpu.zig");
const Thread = @import("Thread.zig");
const Object = @import("../object/Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const gpa = @import("../mem/gpa.zig").allocator;
const assert = std.debug.assert;
const HandleTable = @This();

lock: Spinlock,
nodes: [node_count]pmm.OptIndex,
node_bump: u32,
first_free_index: u32,

const node_count = 256;
const descs_per_node = 256;
const desc_index_bits = 8;
const max_descs = node_count * descs_per_node;
const invalid_index = std.math.maxInt(u32);
const Gen = u13;

comptime {
    std.debug.assert(descs_per_node * @sizeOf(DescSlot) <= mem.page_size);
}

pub const Desc = struct {
    obj: *Object,
    rights: abi.Rights,
};

const DescSlot = extern struct {
    obj: ?*Object,
    rights_or_next_free: u32,
    gen: u32,
};

const InternalHandle = packed struct(u32) {
    desc_index: u8,
    node_index: u10,
    gen: Gen,
    one: u1 = 1,
};

pub fn init() !*HandleTable {
    const table = try gpa.create(HandleTable);
    table.* = .{
        .lock = .init,
        .nodes = @splat(.none),
        .node_bump = 0,
        .first_free_index = invalid_index,
    };
    return table;
}

pub fn deinit(table: *HandleTable) void {
    for (table.nodes[0..table.node_bump]) |opt_index| {
        const index = opt_index.unwrap().?;
        const desc_slots: *[descs_per_node]DescSlot = @ptrCast(index.toDirectMap());
        for (desc_slots) |slot| {
            if (slot.obj) |obj| obj.release();
        }

        pmm.freePage(index);
    }

    gpa.destroy(table);
}

pub fn getLocked(table: *HandleTable, abi_h: abi.Handle) ?Desc {
    const h: InternalHandle = @bitCast(abi_h);
    if (h.one == 0) return null;
    if (h.node_index >= node_count) return null;

    const node_page = table.nodes[h.node_index].unwrap() orelse return null;
    const desc_slots: *[descs_per_node]DescSlot = @ptrCast(node_page.toDirectMap());
    const slot = &desc_slots[h.desc_index];

    if (slot.obj == null) return null;
    if (@as(Gen, @truncate(slot.gen)) != h.gen) return null;

    return .{
        .obj = slot.obj.?,
        .rights = @bitCast(slot.rights_or_next_free),
    };
}

pub fn putLocked(table: *HandleTable, desc: Desc) !abi.Handle {
    if (table.first_free_index != invalid_index) {
        const node_index = table.first_free_index >> desc_index_bits;
        const desc_index = table.first_free_index & ((1 << desc_index_bits) - 1);

        const node_page = table.nodes[node_index].unwrap().?;
        const desc_slots: *[descs_per_node]DescSlot = @ptrCast(node_page.toDirectMap());
        const slot = &desc_slots[desc_index];

        std.debug.assert(slot.obj == null);
        table.first_free_index = slot.rights_or_next_free;
        slot.obj = desc.obj;
        slot.rights_or_next_free = @bitCast(desc.rights);

        const h: InternalHandle = .{
            .desc_index = @intCast(desc_index),
            .node_index = @intCast(node_index),
            .gen = @truncate(slot.gen),
        };

        return @bitCast(h);
    }

    const node_index = table.node_bump;
    if (node_index >= node_count) return error.TooManyHandles;
    const node_page: pmm.Index = try pmm.allocPage();
    const desc_slots: *[descs_per_node]DescSlot = @ptrCast(node_page.toDirectMap());

    for (desc_slots[1..], 2..) |*slot, next| {
        slot.* = .{
            .obj = null,
            .rights_or_next_free = if (next >= descs_per_node) invalid_index else @intCast((node_index << desc_index_bits) | next),
            .gen = 0,
        };
    }

    desc_slots[0] = .{
        .obj = desc.obj,
        .rights_or_next_free = @bitCast(desc.rights),
        .gen = 0,
    };

    const h: InternalHandle = .{
        .desc_index = 0,
        .node_index = @intCast(node_index),
        .gen = 0,
    };

    table.nodes[node_index] = .wrap(node_page);
    table.node_bump += 1;
    table.first_free_index = (node_index << desc_index_bits) | 1;
    return @bitCast(h);
}

pub fn fetchRemoveLocked(table: *HandleTable, abi_h: abi.Handle) ?Desc {
    const h: InternalHandle = @bitCast(abi_h);
    if (h.one == 0) return null;
    if (h.node_index >= node_count) return null;

    const node_page = table.nodes[h.node_index].unwrap() orelse return null;
    const desc_slots: *[descs_per_node]DescSlot = @ptrCast(node_page.toDirectMap());
    const slot = &desc_slots[h.desc_index];

    if (slot.obj == null) return null;
    if (@as(Gen, @truncate(slot.gen)) != h.gen) return null;

    const desc: Desc = .{
        .obj = slot.obj.?,
        .rights = @bitCast(slot.rights_or_next_free),
    };

    slot.obj = null;
    slot.rights_or_next_free = table.first_free_index;
    slot.gen +%= 1;
    table.first_free_index = (@as(u32, h.node_index) << desc_index_bits) | h.desc_index;

    return desc;
}

pub fn getCurrent() *HandleTable {
    const proc = Thread.current().proc orelse @panic("cant get handle table in kernel thread");
    return proc.handle_table;
}
