const std = @import("std");
const mem = @import("memory.zig");

pub const Module = struct {
    pub const max_name_len = 16;

    range: mem.PhysRange,
    name_buf: [max_name_len]u8,
    name_len: usize,

    pub inline fn name(this: @This()) []const u8 {
        return this.name_buf[0..this.name_len];
    }
};

var available_regions_buffer: [16]mem.PhysRange = undefined;
var reserved_regions_buffer: [4]mem.PhysRange = undefined;
var modules_buffer: [8]Module = undefined;

pub var kernel_range: mem.PhysRange = undefined;
pub var available_ranges: std.ArrayList(mem.PhysRange) = .initBuffer(&available_regions_buffer);
pub var reserved_regions: std.ArrayList(mem.PhysRange) = .initBuffer(&reserved_regions_buffer);
pub var modules: std.ArrayList(Module) = .initBuffer(&modules_buffer);

pub var temp_mode: bool = true;
pub var total_pages: usize = 0;
pub var pages_used: usize = 0;
pub var bitset: std.DynamicBitSetUnmanaged = .{};
pub var next_alloc_index: usize = 0;

pub fn tempInit() void {
    reserveAvailableRegion(kernel_range);

    for (modules.items) |module| {
        reserveAvailableRegion(module.range);
    }

    for (reserved_regions.items) |region| {
        reserveAvailableRegion(region);
    }

    std.mem.sort(mem.PhysRange, available_ranges.items, @as(u8, 0), struct {
        fn lessThan(_: u8, lhs: mem.PhysRange, rhs: mem.PhysRange) bool {
            return lhs.base < rhs.base;
        }
    }.lessThan);

    for (available_ranges.items) |range| {
        total_pages += range.pagesInside();
    }
}

pub fn init(alloc: std.mem.Allocator) void {
    bitset = std.DynamicBitSetUnmanaged.initEmpty(alloc, total_pages) catch @panic("can't allocate pmm bitset");
    if (next_alloc_index != 0)
        bitset.setRangeValue(.{ .start = 0, .end = next_alloc_index - 1 }, true);

    std.log.info("bitset size: {x}\n", .{bitset.bit_length / 8});
    temp_mode = false;
}

pub fn allocatePage() !mem.PhysPagePtr {
    if (temp_mode) {
        const result_index = next_alloc_index;
        next_alloc_index += 1;
        pages_used += 1;
        if (result_index >= total_pages) return error.OutOfMemory;
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
        const addr: usize = @intFromPtr(page);
        if (!region.addrInRange(addr)) {
            cumulative_page_offset += region.pagesInside();
            continue;
        }

        const offset = addr - region.base;
        const page_offset = offset / mem.page_size;
        return cumulative_page_offset + page_offset;
    }

    @panic("out of range");
}

fn indexToAddr(index: usize) mem.PhysPagePtr {
    var region_start_index: usize = 0;
    for (available_ranges.items) |region| {
        const region_length = region.pagesInside();
        if (index < region_start_index + region_length) {
            const offset = index - region_start_index;
            return @ptrFromInt(region.base + offset * mem.page_size);
        }

        region_start_index += region_length;
    }

    @panic("out of range");
}

fn reserveAvailableRegion(reserved: mem.PhysRange) void {
    const res_aligned = reserved.alignOutwards(mem.page_size);

    var i: u32 = 0;
    while (i < available_ranges.items.len) {
        const range = available_ranges.items[i];
        var start = range.base;
        var end = range.base + range.len;

        if (res_aligned.addrInRange(start))
            start = res_aligned.end();

        if (res_aligned.addrInRange(end))
            end = res_aligned.base;

        if (start >= end) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        const newRange: mem.PhysRange = .{ .base = start, .len = end - start };

        if (newRange.addrInRange(res_aligned.base)) {
            const additional: mem.PhysRange = .{
                .base = res_aligned.end(),
                .len = end - res_aligned.end(),
            };

            available_ranges.appendBounded(additional) catch @panic("not enough memory ranges");
            end = res_aligned.base;
        }

        available_ranges.items[i] = .{ .base = start, .len = end - start };
        if (available_ranges.items[i].len <= mem.page_size) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        i += 1;
    }
}
