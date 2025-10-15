const std = @import("std");
const Mem = @import("Memory.zig");

pub var totalPages: usize = 0;

pub fn TempInit() void {
    for (Mem.availableRanges.items) |range| {
        totalPages += range.PagesInside();
    }

    std.mem.sort(Mem.PhysRange, Mem.availableRanges.items, @as(u8, 0), struct {
        fn lessThan(_: u8, lhs: Mem.PhysRange, rhs: Mem.PhysRange) bool {
            return lhs.base < rhs.base;
        }
    }.lessThan);

    tempAlloc.isEnabled = true;
    tempAlloc.currentPtr = Mem.availableRanges.items[0].base;
    tempAlloc.currentRangeIndex = 0;
}

pub fn AllocatePage() !*Mem.Phys(Mem.Page) {
    if (tempAlloc.isEnabled) return tempAlloc.AllocatePage();

    @panic("not implemented");
}

const tempAlloc = struct {
    var isEnabled: bool = true;
    var currentPtr: ?usize = null;
    var currentRangeIndex: usize = undefined;

    fn AllocatePage() !*align(Mem.pageSize) Mem.Phys(Mem.Page) {
        if (currentPtr == null) return error.OutOfMemory;

        const result = currentPtr;
        currentPtr.? += Mem.pageSize;
        if (!Mem.availableRanges.items[currentRangeIndex].AddrInRange(currentPtr.?)) {
            currentRangeIndex += 1;
            if (currentRangeIndex >= Mem.availableRanges.items.len) {
                currentPtr = null;
                return @ptrFromInt(result);
            }
            currentPtr.? = Mem.availableRanges.items[currentRangeIndex].base;
        }

        return @ptrFromInt(result);
    }
};
