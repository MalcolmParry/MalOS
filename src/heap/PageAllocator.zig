const std = @import("std");
const arch = @import("../arch.zig");
const mem = @import("../memory.zig");
const Vmm = @import("../Vmm.zig");
const pmm = @import("../pmm.zig");
const Spinlock = @import("../Spinlock.zig");
const PageAllocator = @This();

table: *arch.paging.Table,
vmm: Vmm,
default_flags: Vmm.PageFlags,
lock: Spinlock,

pub var global: PageAllocator = undefined;

pub fn alloc(page_alloc: *PageAllocator, page_count: usize, flags: Vmm.PageFlags) ![]mem.Page {
    const lock = page_alloc.lock.lock();
    defer lock.unlock();

    const range = try page_alloc.vmm.reserve(page_count);
    errdefer page_alloc.vmm.unreserve(range) catch {};

    var pages_mapped: usize = 0;
    errdefer for (0..pages_mapped) |i| {
        const phys = arch.paging.getPhysFromVirt(page_alloc.table, &range[i]);
        arch.paging.clearEntry(page_alloc.table, &range[i]);
        pmm.freePage(phys);
    };

    for (range) |*page| {
        const phys = try pmm.allocPage();
        errdefer pmm.freePage(phys);

        try arch.paging.mapPage(page_alloc.table, .l4, page, phys, flags);
        pages_mapped += 1;
    }

    return range;
}

pub fn map(page_alloc: *PageAllocator, phys_range: []mem.PhysPage, flags: Vmm.PageFlags) ![]mem.Page {
    const lock = page_alloc.lock.lock();
    defer lock.unlock();

    const virt = try page_alloc.vmm.reserve(phys_range.len);
    errdefer page_alloc.vmm.unreserve(virt) catch {};

    var mapped_pages: usize = 0;
    errdefer for (0..mapped_pages) |i| {
        arch.paging.clearEntry(page_alloc.table, &virt[i]);
    };

    for (virt, phys_range) |*page, *phys| {
        try arch.paging.mapPage(page_alloc.table, .l4, page, phys, flags);
        mapped_pages += 1;
    }

    return virt;
}

pub fn resize(page_alloc: *PageAllocator, pages: []mem.Page, new_page_count: usize, flags: Vmm.PageFlags) bool {
    if (pages.len == new_page_count) return true;
    _ = flags;

    if (new_page_count < pages.len) {
        const extra = pages[new_page_count..];
        page_alloc.free(extra);
        return true;
    }

    return false;
}

pub fn free(page_alloc: *PageAllocator, pages: []mem.Page) void {
    const lock = page_alloc.lock.lock();
    defer lock.unlock();

    for (pages) |*page| {
        const phys = arch.paging.getPhysFromVirt(page_alloc.table, page);
        arch.paging.clearEntry(page_alloc.table, page);
        pmm.freePage(phys);
    }

    page_alloc.vmm.unreserve(pages) catch {};
}

pub fn allocator(page_alloc: *PageAllocator) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(page_alloc),
        .vtable = &.{
            .alloc = interface.alloc,
            .resize = interface.resize,
            .remap = interface.remap,
            .free = interface.free,
        },
    };
}

const interface = struct {
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        if (alignment.toByteUnits() > mem.page_size) return null;
        const page_alloc: *PageAllocator = @ptrCast(@alignCast(ctx));
        const page_count = (len + mem.page_size - 1) / mem.page_size;
        const pages = page_alloc.alloc(page_count, page_alloc.default_flags) catch return null;
        return @ptrCast(pages.ptr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
        std.debug.assert(std.mem.isAligned(@intFromPtr(memory.ptr), mem.page_size));
        std.debug.assert(alignment.toByteUnits() <= mem.page_size);
        const page_alloc: *PageAllocator = @ptrCast(@alignCast(ctx));

        const old_page_count = (memory.len + mem.page_size - 1) / mem.page_size;
        const new_page_count = (new_len + mem.page_size - 1) / mem.page_size;
        const pages = @as([*]mem.Page, @ptrCast(@alignCast(memory.ptr)))[0..old_page_count];

        return page_alloc.resize(pages, new_page_count, page_alloc.default_flags);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (interface.resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        std.debug.assert(std.mem.isAligned(@intFromPtr(memory.ptr), mem.page_size));
        std.debug.assert(alignment.toByteUnits() <= mem.page_size);
        const page_alloc: *PageAllocator = @ptrCast(@alignCast(ctx));

        const page_count = (memory.len + mem.page_size - 1) / mem.page_size;
        const pages = @as([*]mem.Page, @ptrCast(@alignCast(memory.ptr)))[0..page_count];
        page_alloc.free(pages);
    }
};
