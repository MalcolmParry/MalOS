const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");
const VMM = @import("../../VMM.zig");
const PMM = @import("../../PMM.zig");

pub const Table = struct {
    pub const Index = u9;

    pub const Entry = packed struct {
        present: bool,
        writable: bool,
        user: bool,
        writeThrough: bool, // ?
        disableCache: bool,
        // cpu sets this, should be set to false by default
        accessed: bool = false,
        available: bool = false,
        isHuge: bool,
        global: bool,
        available2: u3 = 0,
        address: u40, // address divided by 4096
        available3: u11 = 0,
        disableExecute: bool,

        const Blank: Entry = .{
            .present = false,
            .writable = false,
            .user = false,
            .writeThrough = false,
            .disableCache = false,
            .isHuge = false,
            .global = false,
            .address = 0,
            .disableExecute = false,
        };
    };

    // each entry is 512gb
    pub const L4 = extern struct {
        entries: [512]Entry,
        tables: [512]?*L3,

        pub fn MapPage(this: *Table.L4, phys: *align(Mem.pageSize) Mem.Phys(Mem.Page), virt: *align(Mem.pageSize) Mem.Page, pageFlags: VMM.PageFlags, alloc: std.mem.Allocator) !void {
            const indices = GetIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = blk: {
                if (l4.tables[indices[3]]) |x| {
                    break :blk x;
                } else {
                    const result: *Table.L3 = &(try alloc.alignedAlloc(Table.L3, .fromByteUnits(Mem.pageSize), 1))[0];
                    @memset(&result.entries, Table.Entry.Blank);
                    @memset(&result.tables, null);

                    l4.tables[indices[3]] = result;
                    l4.entries[indices[3]] = .{
                        .present = true,
                        .writable = true,
                        .user = false,
                        .writeThrough = false,
                        .disableCache = false,
                        .isHuge = false,
                        .global = false,
                        .address = @intCast((@intFromPtr(&result.entries) - Mem.kernelVirtBase) / Mem.pageSize),
                        .disableExecute = false,
                    };

                    break :blk result;
                }
            };

            const l2 = blk: {
                if (l3.tables[indices[2]]) |x| {
                    break :blk x;
                } else {
                    const result: *Table.L2 = &(try alloc.alignedAlloc(Table.L2, .fromByteUnits(Mem.pageSize), 1))[0];
                    @memset(&result.entries, Table.Entry.Blank);
                    @memset(&result.tables, null);

                    l3.tables[indices[2]] = result;
                    l3.entries[indices[2]] = .{
                        .present = true,
                        .writable = true,
                        .user = false,
                        .writeThrough = false,
                        .disableCache = false,
                        .isHuge = false,
                        .global = false,
                        .address = @intCast((@intFromPtr(&result.entries) - Mem.kernelVirtBase) / Mem.pageSize),
                        .disableExecute = false,
                    };

                    break :blk result;
                }
            };

            const l1 = blk: {
                if (l2.tables[indices[1]]) |x| {
                    break :blk x;
                } else {
                    const result: *Table.L1 = &(try alloc.alignedAlloc(Table.L1, .fromByteUnits(Mem.pageSize), 1))[0];
                    @memset(result, Table.Entry.Blank);

                    l2.tables[indices[1]] = result;
                    l2.entries[indices[1]] = .{
                        .present = true,
                        .writable = true,
                        .user = false,
                        .writeThrough = false,
                        .disableCache = false,
                        .isHuge = false,
                        .global = false,
                        .address = @intCast((@intFromPtr(result) - Mem.kernelVirtBase) / Mem.pageSize),
                        .disableExecute = false,
                    };

                    break :blk result;
                }
            };

            l1[indices[0]] = .{
                .present = pageFlags.present,
                .writable = pageFlags.writable,
                .user = !pageFlags.kernelOnly,
                .writeThrough = pageFlags.cacheMode == .WriteThrough,
                .disableCache = pageFlags.cacheMode == .Disabled,
                .isHuge = false,
                .global = pageFlags.global,
                .address = @intCast(@intFromPtr(phys) / Mem.pageSize),
                .disableExecute = !pageFlags.executable,
            };
        }

        pub fn IsAvailable(this: *@This(), page: *align(Mem.pageSize) Mem.Page) bool {
            const indices = GetIndicesFromVirtAddr(page);
            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse return true;
            const l2 = l3.tables[indices[2]] orelse return true;
            if (l2.entries[1].present and l2.entries[1].isHuge)
                return false;

            const l1 = l2.tables[indices[1]] orelse return true;
            return !l1[indices[0]].present;
        }

        pub fn IsRegionAvailable(this: *@This(), region: []align(Mem.pageSize) Mem.Page) bool {
            for (region) |*page| {
                if (!this.IsAvailable(page)) return false;
            }

            return true;
        }
    };

    // each entry is 1gb
    const L3 = extern struct { entries: [512]Entry, tables: [512]?*L2 };

    // each entry is 2mb
    const L2 = extern struct { entries: [512]Entry, tables: [512]?*L1 };

    // each entry is 4kb
    const L1 = [512]Entry;

    fn GetVirtAddrFromindices(l4: Index, l3: Index, l2: Index, l1: Index) *align(Mem.pageSize) Mem.Page {
        const ul4: usize = l4;
        const ul3: usize = l3;
        const ul2: usize = l2;
        const ul1: usize = l1;

        const addr: usize = (ul1 << 12) | (ul2 << 21) | (ul3 << 30) | (ul4 << 39);
        const mask: usize = @truncate(std.math.boolMask(usize, true) << 48);
        const full: usize = addr | if (l4 & (1 << 8) > 1) mask else 0;
        return @ptrFromInt(full);
    }

    fn GetIndicesFromVirtAddr(addr: *align(Mem.pageSize) Mem.Page) [4]Index {
        const addrI = @intFromPtr(addr);
        const l4 = (addrI >> 39) & 0x1ff;
        const l3 = (addrI >> 30) & 0x1ff;
        const l2 = (addrI >> 21) & 0x1ff;
        const l1 = (addrI >> 12) & 0x1ff;
        return .{
            @intCast(l1),
            @intCast(l2),
            @intCast(l3),
            @intCast(l4),
        };
    }

    fn Init(comptime T: type, table: *T) void {
        @memset(std.mem.asBytes(table), 0);
    }
};

pub const kernelHeapStart = Mem.kernelVirtBase - 4096 * 512 * 512;
var freeL1Entries: usize = 0;

pub var l4Table: Table.L4 align(4096) = undefined;
var l3KernelTable: Table.L3 align(4096) = undefined;
var l2KernelTable: Table.L2 align(4096) = undefined;

var l2KernelHeap: Table.L2 align(4096) = undefined;
var l1KernelHeapStarter: Table.L1 align(4096) = undefined;

pub fn PreInit() void {
    @branchHint(.cold); // stop from inlining
    GDT.InitGDT();

    TempMapKernel();
    Table.Init(Table.L2, &l2KernelHeap);
    Table.Init(Table.L1, &l1KernelHeapStarter);
    freeL1Entries = 512;

    l2KernelHeap.tables[0] = &l1KernelHeapStarter;
    l2KernelHeap.entries[0] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l1KernelHeapStarter) - Mem.kernelVirtBase) / Mem.pageSize),
        .disableExecute = false,
    };

    l3KernelTable.tables[510] = &l2KernelHeap;
    l3KernelTable.entries[510] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l2KernelHeap.entries) - Mem.kernelVirtBase) / Mem.pageSize),
        .disableExecute = false,
    };

    InvalidatePages();

    const heap: [*]align(Mem.pageSize) Mem.Page = @ptrFromInt(kernelHeapStart);
    var pageAllocator = PageAllocator.Create(&l4Table, heap[0 .. 512 * 512], std.testing.failing_allocator);
    const alloc = pageAllocator.allocator();

    var pagesAllocated: usize = 0;
    var lastAlloc: usize = 0;
    while (true) {
        const allocation = alloc.alloc(u8, 1) catch break;
        pagesAllocated += 1;
        lastAlloc = @intFromPtr(allocation.ptr);
    }

    std.log.info("Pages Allocated {}\nLast Alloc 0x{x}\n", .{ pagesAllocated, lastAlloc });
}

pub const PageAllocator = struct {
    table: *Table.L4,
    allowedRange: []align(Mem.pageSize) Mem.Page,
    lastAllocEnd: [*]align(Mem.pageSize) Mem.Page,
    pageTableAllocator: std.mem.Allocator,

    const flags: VMM.PageFlags = .{
        .present = true,
        .cacheMode = .Full,
        .executable = true,
        .global = false,
        .kernelOnly = true,
        .writable = true,
    };

    pub fn Create(table: *Table.L4, allowedRange: []align(Mem.pageSize) Mem.Page, pageTableAllocator: std.mem.Allocator) @This() {
        return .{
            .table = table,
            .allowedRange = allowedRange,
            .lastAllocEnd = allowedRange.ptr,
            .pageTableAllocator = pageTableAllocator,
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

    fn InternalAlloc(this: *@This(), pageCount: usize) ![]align(Mem.pageSize) Mem.Page {
        var virtStart = this.lastAllocEnd;
        if (virtStart == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;

        while (true) {
            if (this.table.IsRegionAvailable(virtStart[0..pageCount])) break;

            virtStart += 1;
            if (virtStart + pageCount == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;
            if (virtStart == this.lastAllocEnd) return error.OutOfVirtAddrSpace;
        }

        for (0..pageCount) |i| {
            const phys = try PMM.AllocatePage();
            try this.table.MapPage(phys, @alignCast(&virtStart[i]), flags, this.pageTableAllocator);
        }

        this.lastAllocEnd = virtStart + pageCount;
        return virtStart[0..pageCount];
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
        if (!this.table.IsRegionAvailable(extraPages)) return false;
        for (extraPages) |*page| {
            const phys = try PMM.AllocatePage();
            try this.table.MapPage(phys, page, flags, this.pageTableAllocator);
        }

        return true;
    }

    fn InternalFree(this: *@This(), pages: Mem.PageSlice) void {
        for (pages) |*page| {
            const indices = Table.GetIndicesFromVirtAddr(page);
            const l4 = this.table;
            const l3 = l4.tables[indices[3]] orelse @panic("called free on memory which isn't mapped");
            const l2 = l3.tables[indices[2]] orelse @panic("called free on memory which isn't mapped");
            const l1 = l2.tables[indices[1]] orelse @panic("called free on memory which isn't mapped");
            if (!l1[indices[0]].present) @panic("called free on memory which isn't mapped");
            const phys: usize = l1[indices[0]].address * Mem.pageSize;
            PMM.FreePage(@ptrFromInt(phys));
            l1[indices[0]] = Table.Entry.Blank;
            if (&this.lastAllocEnd[0] == &pages.ptr[pages.len]) this.lastAllocEnd = pages.ptr;
        }
    }

    pub fn alloc(ctx: *anyopaque, size: usize, alignment: std.mem.Alignment, retAddr: usize) ?[*]u8 {
        const this: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(alignment.toByteUnits() <= Mem.pageSize);
        _ = retAddr;

        const pageCount = std.mem.alignForward(usize, size, Mem.pageSize) / Mem.pageSize;
        const allocation = this.InternalAlloc(pageCount) catch return null;
        return @ptrCast(allocation);
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

fn TempMapKernel() void {
    for (&l2KernelTable.entries, &l2KernelTable.tables, 0..) |*entry, *table, i| {
        table.* = null;
        entry.* = .{
            .present = true,
            .writable = true,
            .user = false,
            .writeThrough = false,
            .disableCache = false,
            .isHuge = true,
            .global = true,
            .address = @as(u40, @intCast(i)) * 512,
            .disableExecute = false,
        };
    }

    l3KernelTable.tables[511] = &l2KernelTable;
    l3KernelTable.entries[511] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l2KernelTable.entries) - Mem.kernelVirtBase) >> 12),
        .disableExecute = false,
    };

    l4Table.tables[511] = &l3KernelTable;
    l4Table.entries[511] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l3KernelTable.entries) - Mem.kernelVirtBase) >> 12),
        .disableExecute = false,
    };

    @memset(l4Table.entries[0..511], Table.Entry.Blank);
    @memset(l4Table.tables[0..511], null);

    @memset(l3KernelTable.entries[0..511], Table.Entry.Blank);
    @memset(l3KernelTable.tables[0..511], null);
}

pub fn InvalidatePages() void {
    SetCr3(@intFromPtr(&l4Table) - Mem.kernelVirtBase);
}

fn SetCr3(physAddr: u64) void {
    asm volatile (
        \\mov %[addr], %%cr3
        :
        : [addr] "rdi" (physAddr),
    );
}
