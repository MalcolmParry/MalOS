const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const mem = @import("../memory.zig");
const gpa = @import("gpa.zig");
const Spinlock = @import("../sync/Spinlock.zig");

const heap = mem.getRegion(.debug_heap).slice;
const heap_pages = mem.getRegion(.debug_heap).page_slice;
var lock: Spinlock = .init;
var bump: usize = 0;
var mapped_page_count: usize = 0;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &alloc,
        .resize = &resize,
        .remap = &remap,
        .free = &free,
    },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    if (len <= mem.page_size and alignment.toByteUnits() <= mem.page_size) return gpa.allocator.rawAlloc(len, alignment, ret_addr);

    const l = lock.lock();
    defer l.unlock();

    const base = alignment.forward(bump);
    if (base + len > heap.len) return null;

    const end_page_index = @divCeil(base + len, mem.page_size);
    if (end_page_index > mapped_page_count) {
        arch.paging.allocAndMap(heap_pages[mapped_page_count..end_page_index], .kernel_rw) catch return null;
        mapped_page_count = end_page_index;
    }

    bump = base + len;
    return heap.ptr + base;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    if (!isInHeap(memory)) return gpa.allocator.rawResize(memory, alignment, new_len, ret_addr);

    const l = lock.lock();
    defer l.unlock();

    const last_end = @intFromPtr(memory.ptr + memory.len) - @intFromPtr(heap.ptr);
    if (new_len <= memory.len) {
        if (last_end == bump) bump -= memory.len - new_len;
        return true;
    }

    if (last_end != bump) return false;
    const extra = new_len - memory.len;
    if (last_end + extra > heap.len) return false;
    const end_page_index = @divCeil(last_end + extra, mem.page_size);

    if (end_page_index > mapped_page_count) {
        arch.paging.allocAndMap(heap_pages[mapped_page_count..end_page_index], .kernel_rw) catch return false;
        mapped_page_count = end_page_index;
    }

    bump += extra;
    return true;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(undefined, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    if (!isInHeap(memory)) return gpa.allocator.rawFree(memory, alignment, ret_addr);

    const l = lock.lock();
    defer l.unlock();

    const end = @intFromPtr(memory.ptr + memory.len) - @intFromPtr(heap.ptr);
    if (end != bump) return;

    bump -= memory.len;
}

fn isInHeap(slice: []u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(heap.ptr) and @intFromPtr(slice.ptr + slice.len) <= @intFromPtr(heap.ptr + heap.len);
}
