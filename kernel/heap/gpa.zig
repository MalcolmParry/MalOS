const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const Spinlock = @import("../sync/Spinlock.zig");

const min_size_bucket = std.math.log2(@sizeOf(u16));
const max_size_bucket = sizeClassIndex(mem.page_size / 4, .@"1");
const size_bucket_count = max_size_bucket - min_size_bucket + 1;

comptime {
    std.debug.assert(slotCount(0) <= std.math.maxInt(u16));
}

const SizeBucket = struct {
    lock: Spinlock = .init,
    first_free_page: pmm.OptIndex = .none,
};

var size_buckets: [size_bucket_count]SizeBucket = @splat(.{});

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
    const class = sizeClassIndex(len, alignment);
    if (class >= size_bucket_count) {
        if (len > mem.page_size or alignment.toByteUnits() > mem.page_size) @panic("big allocation");
        const phys = pmm.allocatePage() catch return null;
        const index: pmm.Index = .fromPtr(phys);
        return @ptrCast(index.toDirectMap());
    }

    const bucket = &size_buckets[class];
    const lock = bucket.lock.lock();
    defer lock.unlock();

    const slot_size = slotSize(class);
    const slot_count = slotCount(class);

    if (bucket.first_free_page.unwrap()) |page_index| {
        @branchHint(.likely);

        const info = &page_index.getDesc().data.gpa;
        info.free_count -= 1;

        if (info.free_count == 0) {
            if (info.prev.unwrap()) |prev| {
                prev.getDesc().data.gpa.next = info.next;
            } else {
                bucket.first_free_page = info.next;
            }

            if (info.next.unwrap()) |next| next.getDesc().data.gpa.prev = info.prev;
        }

        const page_bytes: [*]align(mem.page_size) u8 = &page_index.toDirectMap().bytes;
        if (info.bump < slot_count) {
            const slot = page_bytes + (info.bump * slot_size);
            info.bump += 1;
            return slot;
        }

        const slot = page_bytes + (info.first_free * slot_size);
        const link: *u16 = @ptrCast(@alignCast(slot));
        info.first_free = link.*;
        return slot;
    }

    const page = pmm.allocatePage() catch return null;
    const page_index: pmm.Index = .fromPtr(page);

    bucket.first_free_page = .wrap(page_index);
    page_index.getDesc().data = .{ .gpa = .{
        .first_free = std.math.maxInt(u16),
        .free_count = @intCast(slot_count - 1),
        .next = .none,
        .prev = .none,
        .bump = 1,
    } };

    return &page_index.toDirectMap().bytes;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);

    if (class >= size_bucket_count) {
        @branchHint(.unlikely);
        if (new_len > mem.page_size or alignment.toByteUnits() > mem.page_size) return false;
        if (new_class < size_bucket_count) return false;
        return true;
    }

    return class == new_class;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return if (resize(undefined, memory, alignment, new_len, undefined)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const class = sizeClassIndex(memory.len, alignment);

    if (class >= size_bucket_count) {
        @branchHint(.unlikely);
        if (memory.len > mem.page_size or alignment.toByteUnits() > mem.page_size) @panic("big allocation");
        const index: pmm.Index = .fromDirect(@ptrCast(@alignCast(memory.ptr)));
        pmm.freePage(index.toPtr());
        return;
    }

    const slot_offset = @intFromPtr(memory.ptr) % mem.page_size;
    const slot_index: u16 = @intCast(slot_offset >> @intCast(class + min_size_bucket));
    const link: *u16 = @ptrCast(@alignCast(memory.ptr));

    const page_index: pmm.Index = .fromAddr(@intFromPtr(memory.ptr) - mem.direct_map_base);
    const info = &page_index.getDesc().data.gpa;

    const bucket = &size_buckets[class];
    const lock = bucket.lock.lock();

    if (info.free_count == slotCount(class) - 1) {
        @branchHint(.unlikely);

        if (info.next.unwrap()) |next| next.getDesc().data.gpa.prev = info.prev;
        if (info.prev.unwrap()) |prev| {
            prev.getDesc().data.gpa.next = info.next;
        } else {
            bucket.first_free_page = info.next;
        }

        lock.unlock();
        pmm.freePage(page_index.toPtr());
        return;
    }

    if (info.free_count == 0) {
        info.next = bucket.first_free_page;
        info.prev = .none;

        if (bucket.first_free_page.unwrap()) |other| {
            const other_info = &other.getDesc().data.gpa;
            std.debug.assert(other_info.prev == .none);
            other_info.prev = .wrap(page_index);
        }

        bucket.first_free_page = .wrap(page_index);
    }

    link.* = info.first_free;
    info.first_free = slot_index;
    info.free_count += 1;
    lock.unlock();
}

fn sizeClassIndex(len: usize, alignment: std.mem.Alignment) usize {
    std.debug.assert(len != 0);
    return @max(@bitSizeOf(usize) - @clz(len - 1), @backingInt(alignment), min_size_bucket) - min_size_bucket;
}

fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_size_bucket);
}

fn slotCount(class: usize) usize {
    return @as(usize, 1) << @intCast(mem.log2_page_size - class - min_size_bucket);
}
