const std = @import("std");
const mem = @import("Memory.zig");

pub var totalPages: usize = 0;

pub fn tempInit() void {
    for (mem.available_ranges.items) |range| {
        totalPages += range.pagesInside();
    }

    std.mem.sort(mem.PhysRange, mem.available_ranges.items, @as(u8, 0), struct {
        fn lessThan(_: u8, lhs: mem.PhysRange, rhs: mem.PhysRange) bool {
            return lhs.base < rhs.base;
        }
    }.lessThan);

    temp.enabled = true;
    temp.current_ptr = mem.available_ranges.items[0].base;
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
        if (!mem.available_ranges.items[current_range_index].addrInRange(current_ptr.?)) {
            current_range_index += 1;
            if (current_range_index >= mem.available_ranges.items.len) {
                current_ptr = null;
                return @ptrFromInt(result);
            }
            current_ptr = mem.available_ranges.items[current_range_index].base;
        }

        return @ptrFromInt(result);
    }
};
