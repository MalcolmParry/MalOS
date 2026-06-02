const std = @import("std");
const mem = @import("memory.zig");
const Phys = mem.Phys;

var available_regions_buffer: [16]mem.PhysPageSlice = undefined;

pub var kernel_range: []align(mem.page_size) Phys(u8) = undefined;
pub var available_ranges: std.ArrayList(mem.PhysPageSlice) = .initBuffer(&available_regions_buffer);

pub var total_pages: usize = 0;
pub var pages_used: usize = 0;
var temp_mode: bool = true;
var bitset: std.DynamicBitSetUnmanaged = .{};
var next_alloc_index: usize = 0;

pub fn tempInit() void {
    reserveAvailableRegion(kernel_range);

    for (mem.modules.items) |module| {
        reserveAvailableRegion(module.phys_range);
    }

    for (available_ranges.items) |range| {
        total_pages += range.len;
    }
}

pub fn init(alloc: std.mem.Allocator) void {
    bitset = std.DynamicBitSetUnmanaged.initEmpty(alloc, total_pages) catch @panic("can't allocate pmm bitset");
    if (next_alloc_index != 0)
        bitset.setRangeValue(.{ .start = 0, .end = next_alloc_index - 1 }, true);

    temp_mode = false;
}

pub fn allocatePage() !mem.PhysPagePtr {
    if (temp_mode) {
        const result_index = next_alloc_index;
        if (result_index >= total_pages) return error.OutOfMemory;

        next_alloc_index += 1;
        pages_used += 1;
        return indexToAddr(result_index);
    }

    var result_index = next_alloc_index;
    while (bitset.isSet(result_index)) {
        result_index += 1;
        if (result_index >= total_pages) result_index = 0;
        if (result_index == next_alloc_index) return error.OutOfMemory;
    }

    pages_used += 1;
    next_alloc_index = result_index + 1;
    if (next_alloc_index >= total_pages) next_alloc_index = 0;
    bitset.set(result_index);
    return indexToAddr(result_index);
}

pub fn freePage(page: mem.PhysPagePtr) void {
    if (temp_mode) @panic("can't free pages with temp pmm");

    const index = addrToIndex(page);
    std.debug.assert(bitset.isSet(index));
    bitset.unset(index);
    pages_used -= 1;
}

fn addrToIndex(page: mem.PhysPagePtr) usize {
    var cumulative_page_offset: usize = 0;
    for (available_ranges.items) |region| {
        if (!mem.addrInSlice(mem.PhysPageSlice, region, page)) {
            cumulative_page_offset += region.len;
            continue;
        }

        const offset = @intFromPtr(page) - @intFromPtr(region.ptr);
        const page_offset = offset / mem.page_size;
        return cumulative_page_offset + page_offset;
    }

    @panic("out of range");
}

fn indexToAddr(index: usize) mem.PhysPagePtr {
    var region_start_index: usize = 0;
    for (available_ranges.items) |region| {
        if (index < region_start_index + region.len) {
            const offset = index - region_start_index;
            return &region[offset];
        }

        region_start_index += region.len;
    }

    @panic("out of range");
}

fn reserveAvailableRegion(reserved: []Phys(u8)) void {
    const res_aligned = mem.physPageAlignOutwards(reserved);
    const res_end = res_aligned.ptr + res_aligned.len;

    var i: u32 = 0;
    while (i < available_ranges.items.len) {
        const range = available_ranges.items[i];
        var start = range.ptr;
        var end = range.ptr + range.len;

        if (mem.addrInSlice(mem.PhysPageSlice, res_aligned, start))
            start = res_end;

        if (mem.addrInSlice(mem.PhysPageSlice, res_aligned, end))
            end = res_aligned.ptr;

        if (@intFromPtr(start) >= @intFromPtr(end)) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        const len = (@intFromPtr(end) - @intFromPtr(start)) / mem.page_size;
        const new_range = start[0..len];

        if (mem.addrInSlice(mem.PhysPageSlice, new_range, res_aligned.ptr)) {
            const add_len = (@intFromPtr(end) - @intFromPtr(res_end)) / mem.page_size;
            const additional = res_end[0..add_len];

            available_ranges.appendBounded(additional) catch @panic("not enough memory ranges");
            end = res_aligned.ptr;
        }

        available_ranges.items[i] = mem.fromStartAndEnd(mem.PhysPageSlice, start, end);
        if (available_ranges.items[i].len <= mem.page_size) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        i += 1;
    }
}
