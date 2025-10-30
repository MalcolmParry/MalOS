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

pub var totalPages: usize = 0;

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
        totalPages += range.pagesInside();
    }

    temp.enabled = true;
    temp.current_ptr = available_ranges.items[0].base;
    temp.current_range_index = 0;
}

pub fn allocatePage() !mem.PhysPagePtr {
    if (temp.enabled) return temp.allocatePage();

    @panic("not implemented");
}

pub fn freePage(page: mem.PhysPagePtr) void {
    _ = page;
    @panic("not implemented");
}

const temp = struct {
    var enabled: bool = true;
    var current_ptr: ?usize = null;
    var current_range_index: usize = undefined;

    fn allocatePage() !mem.PhysPagePtr {
        if (current_ptr == null) return error.OutOfMemory;

        const result = current_ptr.?;
        current_ptr.? += mem.page_size;
        if (!available_ranges.items[current_range_index].addrInRange(current_ptr.?)) {
            current_range_index += 1;
            if (current_range_index >= available_ranges.items.len) {
                current_ptr = null;
                return @ptrFromInt(result);
            }
            current_ptr = available_ranges.items[current_range_index].base;
        }

        return @ptrFromInt(result);
    }
};

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
