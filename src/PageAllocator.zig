const std = @import("std");
const mem = @import("memory.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const arch = @import("arch.zig");

table: *arch.PageTable,
allowed_range: mem.PageSlice,
last_alloc_end: mem.PageManyPtr,

const flags: vmm.PageFlags = .{
    .cache_mode = .full,
    .executable = false,
    .global = false,
    .kernel_only = true,
    .writable = true,
};

pub fn init(table: *arch.PageTable, allowed_range: mem.PageSlice) @This() {
    return .{
        .table = table,
        .allowed_range = allowed_range,
        .last_alloc_end = allowed_range.ptr,
    };
}

pub fn allocator(this: *@This()) std.mem.Allocator {
    return .{
        .ptr = this,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn getAvailableVirtRange(this: *@This(), page_count: usize) ?mem.PageSlice {
    var virtStart = this.last_alloc_end;
    if (virtStart == this.allowed_range.ptr + this.allowed_range.len) virtStart = this.allowed_range.ptr;

    while (true) {
        if (this.table.isRegionAvailable(virtStart[0..page_count])) break;

        virtStart += 1;
        if (virtStart + page_count == this.allowed_range.ptr + this.allowed_range.len) virtStart = this.allowed_range.ptr;
        if (virtStart == this.last_alloc_end) return null;
    }

    std.debug.assert(@intFromPtr(virtStart) >= @intFromPtr(this.allowed_range.ptr));
    std.debug.assert(@intFromPtr(virtStart + page_count) <= @intFromPtr(this.allowed_range.ptr + this.allowed_range.len));
    return virtStart[0..page_count];
}

pub fn mapRange(this: *@This(), range: mem.PhysRange) ![]u8 {
    const pages = range.alignOutwards(mem.page_size);
    const page_count = pages.pagesInside();

    const virt = this.getAvailableVirtRange(page_count) orelse return error.OutOfVirtAddrSpace;
    for (virt, 0..) |*page, i| {
        const phys: mem.PhysPagePtr = @ptrFromInt(pages.base + i * mem.page_size);
        try this.table.mapPage(phys, page, .{
            .writable = true,
            .executable = false,
            .global = true,
            .kernel_only = true,
            .cache_mode = .full,
        }, false);
    }

    const offset_from_page_bounds = range.base - pages.base;
    const pages_as_bytes = std.mem.sliceAsBytes(virt);
    return pages_as_bytes[offset_from_page_bounds .. offset_from_page_bounds + range.len];
}

fn internalAlloc(this: *@This(), page_count: usize) !mem.PageSlice {
    const result = this.getAvailableVirtRange(page_count) orelse return error.OutOfVirtAddrSpace;
    this.last_alloc_end = result.ptr + page_count;
    var pages_allocated: usize = 0;
    errdefer this.internalFree(result[0..pages_allocated]);

    for (result) |*page| {
        const phys = try pmm.allocatePage();
        try this.table.mapPage(phys, page, flags, false);
        pages_allocated += 1;
    }

    return result;
}

fn internalResize(this: *@This(), pages: mem.PageSlice, new_page_count: usize) !bool {
    if (pages.len == new_page_count) return true;
    if (pages.len > new_page_count) {
        const extra_pages = pages[new_page_count..pages.len];
        this.internalFree(extra_pages);
        return true;
    }

    const extra_pages = pages.ptr[pages.len..new_page_count];
    var pages_allocated: usize = 0;
    if (!this.table.isRegionAvailable(extra_pages)) return false;
    errdefer if (pages_allocated != 0) this.internalFree(extra_pages[0..pages_allocated]);
    for (extra_pages) |*page| {
        const phys = try pmm.allocatePage();
        try this.table.mapPage(phys, page, flags, false);
        pages_allocated += 1;
    }

    return true;
}

fn internalFree(this: *@This(), pages: mem.PageSlice) void {
    for (pages) |*page| {
        const phys = this.table.getPhysAddrFromVirt(page);
        pmm.freePage(phys);
        this.table.clearEntry(page) catch @panic("not mapped");
        if (&this.last_alloc_end[0] == &pages.ptr[pages.len]) this.last_alloc_end = pages.ptr;
    }
}

fn alloc(ctx: *anyopaque, size: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const this: *@This() = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment.toByteUnits() <= mem.page_size);
    _ = ret_addr;

    const page_count = std.mem.alignForward(usize, size, mem.page_size) / mem.page_size;
    const allocation = this.internalAlloc(page_count) catch return null;
    const bytes: [*]u8 = @ptrCast(allocation);

    return bytes;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const this: *@This() = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment.toByteUnits() <= mem.page_size);
    _ = ret_addr;

    const page_count = std.mem.alignForward(usize, new_len, mem.page_size) / mem.page_size;
    return this.internalResize(mem.pageSliceFromBytes(memory), page_count) catch false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const this: *@This() = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment.toByteUnits() <= mem.page_size);
    _ = ret_addr;

    this.internalFree(mem.pageSliceFromBytes(memory));
}
