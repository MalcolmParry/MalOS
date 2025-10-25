const std = @import("std");
const Mem = @import("Memory.zig");
const Arch = @import("Arch.zig");
const PMM = @import("PMM.zig");

pub const PageTable = Arch.Tables.L4;
pub const PageFlags = struct {
    const CacheMode = enum {
        Full,
        // for memory that is read by hardware
        WriteThrough,
        // for io
        Disabled,
    };

    present: bool = true,
    writable: bool,
    executable: bool,
    kernelOnly: bool,
    cacheMode: CacheMode,
    global: bool,
};

pub const PageAllocator = struct {
    table: *Arch.PageTable,
    allowedRange: Mem.PageSlice,
    lastAllocEnd: Mem.PageManyPtr,

    const flags: PageFlags = .{
        .present = true,
        .cacheMode = .Full,
        .executable = true,
        .global = false,
        .kernelOnly = true,
        .writable = true,
    };

    pub fn Create(table: *Arch.PageTable, allowedRange: Mem.PageSlice) @This() {
        return .{
            .table = table,
            .allowedRange = allowedRange,
            .lastAllocEnd = allowedRange.ptr,
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

    pub fn GetAvailableVirtRange(this: *@This(), pageCount: usize) ?Mem.PageSlice {
        var virtStart = this.lastAllocEnd;
        if (virtStart == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;

        while (true) {
            if (this.table.IsRegionAvailable(virtStart[0..pageCount])) break;

            virtStart += 1;
            if (virtStart + pageCount == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;
            if (virtStart == this.lastAllocEnd) return null;
        }

        std.debug.assert(@intFromPtr(virtStart) >= @intFromPtr(this.allowedRange.ptr));
        std.debug.assert(@intFromPtr(virtStart + pageCount) <= @intFromPtr(this.allowedRange.ptr + this.allowedRange.len));
        return virtStart[0..pageCount];
    }

    fn InternalAlloc(this: *@This(), pageCount: usize) !Mem.PageSlice {
        const result = this.GetAvailableVirtRange(pageCount) orelse return error.OutOfVirtAddrSpace;
        this.lastAllocEnd = result.ptr + pageCount;
        // TODO: handle errors

        for (result) |*page| {
            const phys = try PMM.AllocatePage();
            try this.table.MapPage(phys, page, flags, false, Arch.Paging.tableAllocator.allocator());
        }

        return result;
    }

    fn InternalResize(this: *@This(), pages: Mem.PageSlice, newPageCount: usize) !bool {
        if (newPageCount == 0) {
            this.InternalFree(pages);
            return true;
        }

        if (pages.len == newPageCount) return true;
        if (pages.len > newPageCount) {
            const extraPages = pages[newPageCount..pages.len];
            this.InternalFree(extraPages);
            return true;
        }

        const extraPages = pages.ptr[pages.len..newPageCount];
        var pagesAllocated: usize = 0;
        if (!this.table.IsRegionAvailable(extraPages)) return false;
        errdefer if (pagesAllocated != 0) this.InternalFree(extraPages[0..pagesAllocated]);
        for (extraPages) |*page| {
            const phys = try PMM.AllocatePage();
            try this.table.MapPage(phys, page, flags, false, Arch.Paging.tableAllocator.allocator());
            pagesAllocated += 1;
        }

        @memset(extraPages, undefined);
        return true;
    }

    fn InternalFree(this: *@This(), pages: Mem.PageSlice) void {
        for (pages) |*page| {
            const phys = this.table.GetPhysAddrFromVirt(page);
            PMM.FreePage(phys);
            this.table.ClearEntry(page) catch @panic("not mapped");
            if (&this.lastAllocEnd[0] == &pages.ptr[pages.len]) this.lastAllocEnd = pages.ptr;
        }
    }

    pub fn alloc(ctx: *anyopaque, size: usize, alignment: std.mem.Alignment, retAddr: usize) ?[*]u8 {
        const this: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(alignment.toByteUnits() <= Mem.pageSize);
        _ = retAddr;

        const pageCount = std.mem.alignForward(usize, size, Mem.pageSize) / Mem.pageSize;
        const allocation = this.InternalAlloc(pageCount) catch return null;
        const bytes: [*]u8 = @ptrCast(allocation);

        @memset(bytes[0..size], undefined);
        return bytes;
    }

    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, newLen: usize, retAddr: usize) bool {
        const this: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(alignment.toByteUnits() <= Mem.pageSize);
        _ = retAddr;

        const pageCount = std.mem.alignForward(usize, newLen, Mem.pageSize) / Mem.pageSize;
        return this.InternalResize(Mem.PageSliceFromBytes(memory), pageCount) catch false;
    }

    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, newLen: usize, retAddr: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, newLen, retAddr)) return memory.ptr;
        if (memory.len >= newLen) @panic("case should have been handled by resize");

        const newAlloc = alloc(ctx, newLen, alignment, retAddr) orelse return null;
        @memcpy(newAlloc[0..memory.len], memory);
        free(ctx, memory, alignment, retAddr);
        return newAlloc;
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, retAddr: usize) void {
        const this: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(alignment.toByteUnits() <= Mem.pageSize);
        _ = retAddr;

        this.InternalFree(Mem.PageSliceFromBytes(memory));
    }
};
