const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const assert = std.debug.assert;

const max_alloc = mem.page_size / 4;
const min_alloc = 16;
const log2_min_alloc = std.math.log2(min_alloc);
const max_size_class = sizeClass(max_alloc, .@"1");
const size_class_count = max_size_class + 1;

comptime {
    assert(classSlots(0) <= std.math.maxInt(u16));
    assert(classSlots(max_size_class) >= 2);
}

const Header = extern struct {
    free_count: u16,
    first_free: u16,
    prev: pmm.OptIndex,
    next: pmm.OptIndex,

    fn get(index: pmm.Index) *Header {
        return @ptrFromInt(@intFromPtr(index.toDirectMap()) + mem.page_size - @sizeOf(Header));
    }

    comptime {
        assert(@sizeOf(Header) <= min_alloc);
    }
};

const SizeBucket = struct {
    lock: Spinlock = .init,
    first_free_page: pmm.OptIndex = .none,
};

var size_buckets: [size_class_count]SizeBucket = @splat(.{});

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &alloc,
        .resize = &resize,
        .remap = &remap,
        .free = &free,
    },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const class = sizeClass(len, alignment);
    if (class >= size_class_count) {
        if (len > mem.page_size or alignment.toByteUnits() > mem.page_size) @panic("big allocation");
        const phys = pmm.allocatePage() catch return null;
        const index: pmm.Index = .fromPtr(phys);
        return @ptrCast(index.toDirectMap());
    }

    const bucket = &size_buckets[class];
    const lock = bucket.lock.lock();
    defer lock.unlock();

    const slot_size = classSize(class);
    const slot_count = classSlots(class);

    if (bucket.first_free_page.unwrap()) |page_index| {
        @branchHint(.likely);

        const header = Header.get(page_index);
        header.free_count -= 1;

        if (header.free_count == 0) {
            if (header.prev.unwrap()) |prev| {
                const prev_h = Header.get(prev);
                prev_h.next = header.next;
            } else {
                bucket.first_free_page = header.next;
            }

            if (header.next.unwrap()) |next| {
                const next_h = Header.get(next);
                next_h.prev = header.prev;
            }
        }

        const page_bytes: [*]align(mem.page_size) u8 = &page_index.toDirectMap().bytes;
        const slot = page_bytes + (header.first_free * slot_size);
        const link: *u16 = @ptrCast(@alignCast(slot));
        header.first_free = link.*;
        return slot;
    }

    const page = pmm.allocatePage() catch return null;
    const page_index: pmm.Index = .fromPtr(page);

    bucket.first_free_page = .wrap(page_index);
    const header = Header.get(page_index);
    header.* = .{
        .free_count = @intCast(slot_count - 1),
        .first_free = 1,
        .next = .none,
        .prev = .none,
    };

    const page_bytes: [*]align(mem.page_size) u8 = &page_index.toDirectMap().bytes;
    for (1..slot_count) |i| {
        const slot = page_bytes + (i * slot_size);
        const link: *u16 = @ptrCast(@alignCast(slot));
        link.* = if (i == slot_count - 1) undefined else @intCast(i + 1);
    }

    return &page_index.toDirectMap().bytes;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    const class = sizeClass(memory.len, alignment);
    const new_class = sizeClass(new_len, alignment);

    if (class >= size_class_count) {
        @branchHint(.unlikely);
        if (new_len > mem.page_size or alignment.toByteUnits() > mem.page_size) return false;
        if (new_class < size_class_count) return false;
        return true;
    }

    return class == new_class;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return if (resize(undefined, memory, alignment, new_len, undefined)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const class = sizeClass(memory.len, alignment);

    if (class >= size_class_count) {
        @branchHint(.unlikely);
        if (memory.len > mem.page_size or alignment.toByteUnits() > mem.page_size) @panic("big allocation");
        const index: pmm.Index = .fromDirect(@ptrCast(@alignCast(memory.ptr)));
        pmm.freePage(index.toPtr());
        return;
    }

    const slot_size = classSize(class);
    const slot_count = classSlots(class);

    const slot_offset = @intFromPtr(memory.ptr) % mem.page_size;
    const slot_index: u16 = @intCast(slot_offset / slot_size);
    const link: *u16 = @ptrCast(@alignCast(memory.ptr));

    const page_index: pmm.Index = .fromAddr(@intFromPtr(memory.ptr) - mem.direct_map_base);
    const header = Header.get(page_index);

    const bucket = &size_buckets[class];
    const lock = bucket.lock.lock();

    if (header.free_count == slot_count - 1) {
        @branchHint(.unlikely);

        if (header.next.unwrap()) |next| Header.get(next).prev = header.prev;
        if (header.prev.unwrap()) |prev| {
            Header.get(prev).next = header.next;
        } else {
            bucket.first_free_page = header.next;
        }

        lock.unlock();
        pmm.freePage(page_index.toPtr());
        return;
    }

    if (header.free_count == 0) {
        header.next = bucket.first_free_page;
        header.prev = .none;

        if (bucket.first_free_page.unwrap()) |other| {
            const other_h = Header.get(other);
            assert(other_h.prev == .none);
            other_h.prev = .wrap(page_index);
        }

        bucket.first_free_page = .wrap(page_index);
    }

    link.* = header.first_free;
    header.first_free = slot_index;
    header.free_count += 1;
    lock.unlock();
}

fn sizeClass(size: usize, alignment: std.mem.Alignment) usize {
    assert(size != 0);

    const size_or_min = @max(size, alignment.toByteUnits(), min_alloc);
    const log2 = std.math.log2_int_ceil(usize, size_or_min);
    const half = @as(usize, 1) << @intCast(log2 - 1);
    const three_quarters = half + (half >> 1);
    const class = (log2 - log2_min_alloc) * 2;
    return if (size_or_min <= three_quarters and alignment.check(three_quarters)) class - 1 else class;
}

fn classSize(class: usize) usize {
    assert(class <= max_size_class);

    const has_half = class % 2 == 1;
    const log2 = class / 2 + log2_min_alloc;
    const power_of_2 = @as(usize, 1) << @intCast(log2);
    const half = power_of_2 >> 1;
    return if (has_half) power_of_2 + half else power_of_2;
}

fn classSlots(class: usize) usize {
    return (mem.page_size - @sizeOf(Header)) / classSize(class);
}
