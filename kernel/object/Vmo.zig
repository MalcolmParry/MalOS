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
const level_mask = level_entries - 1;
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

pub fn pageCapacity(vmo: *const Vmo) usize {
    return @as(usize, top_entries) << @intCast(vmo.tree_level * level_bits);
}

pub fn getPhysLocked(vmo: *const Vmo, page_offset: usize) ?pmm.Index {
    if (page_offset >= vmo.pageCapacity()) return null;

    var level = vmo.tree_level;
    var entries: []const pmm.OptIndex = &vmo.entries;
    while (level != 0) : (level -= 1) {
        const index = (page_offset >> @intCast(level * level_bits)) & level_mask;
        const entry = entries[index].unwrap() orelse return null;
        const node: *TreeNode = @ptrCast(entry.toDirectMap());
        entries = &node.entries;
    }

    const index = page_offset & level_mask;
    return entries[index].unwrap();
}

fn expandToDepthLocked(vmo: *Vmo, new_levels: usize) !void {
    if (vmo.tree_level >= new_levels) return;
    const to_add = new_levels - vmo.tree_level;
    if (std.mem.allEqual(pmm.OptIndex, &vmo.entries, .none)) {
        vmo.tree_level = new_levels;
        return;
    }

    for (0..to_add) |_| {
        const page = try pmm.allocatePage();
        const index: pmm.Index = .fromPtr(page);
        const node: *TreeNode = @ptrCast(index.toDirectMap());
        @memcpy(node.entries[0..top_entries], &vmo.entries);
        @memset(node.entries[top_entries..], .none);
        vmo.entries[0] = .wrap(index);
        @memset(vmo.entries[1..], .none);
        vmo.tree_level += 1;
    }
}

fn expandToPageCount(vmo: *Vmo, page_count: usize) !void {
    if (page_count == 0) return;
    try expandToDepthLocked(vmo, (std.math.log2_int_ceil(usize, page_count) + level_bits - top_bits - 1) / level_bits);
}

fn walkOrCreateLocked(vmo: *Vmo, page_offset: usize) ![]pmm.OptIndex {
    var level = vmo.tree_level;
    var entries: []pmm.OptIndex = &vmo.entries;
    while (level != 0) : (level -= 1) {
        const index = (page_offset >> @intCast(level * level_bits)) & level_mask;

        const node_index = entries[index].unwrap() orelse blk: {
            const page = try pmm.allocatePage();
            const page_index: pmm.Index = .fromPtr(page);
            const node: *TreeNode = @ptrCast(page_index.toDirectMap());
            @memset(&node.entries, .none);
            entries[index] = .wrap(page_index);
            break :blk page_index;
        };

        const node: *TreeNode = @ptrCast(node_index.toDirectMap());
        entries = &node.entries;
    }

    return entries;
}

pub fn write(vmo: *Vmo, offset: usize, data: []const u8) !void {
    if (data.len == 0) return;

    const l = vmo.lock.lock();
    defer l.unlock();

    const end = std.math.add(usize, offset, data.len) catch return error.OutOfRange;
    if (end > std.math.maxInt(usize) - mem.page_size) return error.OutOfRange;
    const page_start = offset / mem.page_size;
    const page_end = (end + mem.page_size - 1) / mem.page_size;
    const page_len = page_end - page_start;
    if (vmo.pageCount() < page_end) return error.OutOfRange;
    try vmo.expandToPageCount(page_end);

    var leaf: []pmm.OptIndex = undefined;
    var written: usize = 0;
    for (0..page_len) |i| {
        const page_offset = page_start + i;
        const index = page_offset & level_mask;
        if (i == 0 or index == 0) leaf = try vmo.walkOrCreateLocked(page_offset);

        const page_index = leaf[index].unwrap() orelse blk: {
            const new = try pmm.allocPageZeroed();
            leaf[index] = .wrap(new);
            break :blk new;
        };

        const direct = &page_index.toDirectMap().bytes;
        const offset_from_page = if (i == 0) offset % mem.page_size else 0;
        const len = @min(mem.page_size - offset_from_page, data.len - written);
        @memcpy(direct[offset_from_page..][0..len], data[written..][0..len]);
        written += len;
    }
}

pub fn read(vmo: *Vmo, offset: usize, buffer: []u8) !void {
    if (buffer.len == 0) return;

    const l = vmo.lock.lock();
    defer l.unlock();

    const end = std.math.add(usize, offset, buffer.len) catch return error.OutOfRange;
    if (end > std.math.maxInt(usize) - mem.page_size) return error.OutOfRange;
    const page_start = offset / mem.page_size;
    const page_end = (end + mem.page_size - 1) / mem.page_size;
    const page_len = page_end - page_start;
    if (vmo.pageCount() < page_end) return error.OutOfRange;

    var bytes_read: usize = 0;
    for (0..page_len) |i| {
        const page_offset = page_start + i;
        const maybe_page = vmo.getPhysLocked(page_offset);

        const offset_from_page = if (i == 0) offset % mem.page_size else 0;
        const len = @min(mem.page_size - offset_from_page, buffer.len - bytes_read);

        if (maybe_page) |page| {
            const direct = &page.toDirectMap().bytes;
            @memcpy(buffer[bytes_read..][0..len], direct[offset_from_page..][0..len]);
        } else {
            @memset(buffer[bytes_read..][0..len], 0);
        }

        bytes_read += len;
    }
}

pub fn commitLocked(vmo: *Vmo, first_page: usize, page_count: usize) !void {
    try vmo.expandToPageCount(first_page + page_count);

    var leaf: []pmm.OptIndex = undefined;
    for (0..page_count) |i| {
        const page_offset = first_page + i;
        const index = page_offset & level_mask;
        if (i == 0 or index == 0) leaf = try vmo.walkOrCreateLocked(page_offset);

        if (leaf[index] != .none) continue;
        leaf[index] = .wrap(try pmm.allocPageZeroed());
    }
}

fn levelCount(entry_count: usize) usize {
    if (entry_count < top_entries) return 0;
    const bits: usize = std.math.log2_int_ceil(usize, entry_count);
    return (bits - top_bits + level_bits - 1) / level_bits;
}
