const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Object = @import("Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const Vmo = @This();

obj: Object,
lock: Spinlock,
size: usize,

entries: [top_entries]pmm.OptIndex,
tree_level: usize,

const top_entries = 4;
const level_entries = mem.page_size / @sizeOf(pmm.OptIndex);
const top_bits = std.math.log2_int(usize, top_entries);
const level_bits = std.math.log2_int(usize, level_entries);

const TreeNode = extern struct {
    entries: [level_entries]pmm.OptIndex,
};

pub fn create(size: usize) !*Vmo {
    const vmo = try gpa.create(Vmo);
    vmo.* = .{
        .obj = .{
            .kind = .vmo,
            .ref_count = .init(1),
        },
        .lock = .init,
        .size = size,
        .entries = @splat(.none),
        .tree_level = 0,
    };

    return vmo;
}

pub fn fromOwnedSlice(slice: []align(mem.page_size) mem.Phys(u8)) !*Vmo {
    const page_count = (slice.len + mem.page_size - 1) / mem.page_size;
    const pages = @as([*]mem.PhysPage, @ptrCast(slice.ptr))[0..page_count];

    const vmo: *Vmo = try .create(slice.len);
    errdefer vmo.destroy();

    const level = levelCount(page_count);
    errdefer for (vmo.entries) |opt| if (opt.unwrap()) |x| freeNodes(x, level);

    try fillEntries(&vmo.entries, pages, level);
    vmo.tree_level = level;
    return vmo;
}

fn fillEntries(entries: []pmm.OptIndex, pages: []mem.PhysPage, level: usize) !void {
    @memset(entries, .none);

    if (level == 0) {
        for (pages, entries[0..pages.len]) |*page, *entry|
            entry.* = .wrap(.fromPtr(page));
        return;
    }

    const pages_per_entry = @as(usize, 1) << @intCast(level * level_bits);
    var remaining = pages;
    for (entries) |*entry| {
        if (remaining.len == 0) break;
        const n = @min(pages_per_entry, remaining.len);

        const node_index: pmm.Index = .fromPtr(try pmm.allocatePage());
        entry.* = .wrap(node_index);
        const node: *TreeNode = @ptrCast(node_index.toDirectMap());

        try fillEntries(&node.entries, remaining[0..n], level - 1);
        remaining = remaining[n..];
    }

    std.debug.assert(remaining.len == 0);
}

pub fn freeNodes(entry: pmm.Index, level: usize) void {
    if (level == 0) return;
    const node: *TreeNode = @ptrCast(entry.toDirectMap());
    for (node.entries) |sub| if (sub.unwrap()) |x| freeNodes(x, level - 1);
    pmm.freePage(entry.toPtr());
}

pub fn destroy(vmo: *Vmo) void {
    std.debug.assert(vmo.obj.ref_count.load(.monotonic) == 0);

    for (&vmo.entries) |top| {
        if (top.unwrap()) |x| destroyEntry(x, vmo.tree_level);
    }

    gpa.destroy(vmo);
}

fn destroyEntry(entry: pmm.Index, level: usize) void {
    if (level == 0) {
        pmm.freePage(entry.toPtr());
        return;
    }

    const child: *TreeNode = @ptrCast(entry.toDirectMap());
    for (child.entries) |sub| {
        if (sub.unwrap()) |x| destroyEntry(x, level - 1);
    }

    pmm.freePage(entry.toPtr());
}

pub fn pageCount(vmo: *const Vmo) usize {
    return (vmo.size + mem.page_size - 1) / mem.page_size;
}

fn levelCount(entry_count: usize) usize {
    if (entry_count < top_entries) return 0;
    const bits: usize = std.math.log2_int_ceil(usize, entry_count);
    return (bits - top_bits + level_bits - 1) / level_bits;
}
