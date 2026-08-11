const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");

pub var page_alloc: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = page_allocator.alloc,
        .resize = page_allocator.resize,
        .remap = page_allocator.remap,
        .free = page_allocator.free,
    },
};

const page_allocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        if (len > mem.page_size) return null;
        if (alignment.toByteUnits() > mem.page_size) return null;

        const phys = pmm.allocPage() catch return null;
        const index = @intFromPtr(phys) / mem.page_size;
        return @ptrCast(&mem.direct_map[index]);
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
        std.debug.assert(alignment.toByteUnits() <= mem.page_size);
        std.debug.assert(memory.len <= mem.page_size);
        std.debug.assert(std.mem.isAligned(@intFromPtr(memory.ptr), mem.page_size));

        return new_len <= mem.page_size;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        std.debug.assert(alignment.toByteUnits() <= mem.page_size);
        std.debug.assert(memory.len <= mem.page_size);
        std.debug.assert(std.mem.isAligned(@intFromPtr(memory.ptr), mem.page_size));

        const phys: *mem.PhysPage = @ptrFromInt(@intFromPtr(memory.ptr) - @intFromPtr(mem.direct_map.ptr));
        pmm.freePage(phys);
    }
};
