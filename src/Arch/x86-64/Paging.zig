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

    const Reserve = struct {
        var l3: ?*align(Mem.pageSize) L3 = null;
        var l2: ?*align(Mem.pageSize) L2 = null;
        var l1: ?*align(Mem.pageSize) L1 = null;
        var allocating: bool = false;

        fn Allocate(alloc: std.mem.Allocator) !void {
            if (allocating) return;
            allocating = true;

            if (l3 == null) l3 = &(try alloc.alignedAlloc(L3, .fromByteUnits(Mem.pageSize), 1))[0];
            if (l2 == null) l2 = &(try alloc.alignedAlloc(L2, .fromByteUnits(Mem.pageSize), 1))[0];
            if (l1 == null) l1 = &(try alloc.alignedAlloc(L1, .fromByteUnits(Mem.pageSize), 1))[0];

            allocating = false;
        }
    };

    fn GetOrCreateTable(l4: *L4, T: type, table: *T, index: usize) !*GetLowerType(T) {
        const lowerT = GetLowerType(T);

        if (table.tables[index]) |lower|
            return lower;

        const res = switch (lowerT) {
            L3 => &Reserve.l3,
            L2 => &Reserve.l2,
            L1 => &Reserve.l1,
            else => @panic("wrong type"),
        };
        if (res.* == null) @panic("nuh uh");
        const lower = res.*.?;
        res.* = null;

        table.tables[index] = lower;
        table.entries[index] = .{
            .present = true,
            .writable = true,
            .user = false,
            .writeThrough = false,
            .disableCache = false,
            .isHuge = false,
            .global = false,
            .address = @intCast(@intFromPtr(l4.GetPhysAddrFromVirt(@ptrCast(lower))) / Mem.pageSize),
            .disableExecute = false,
        };

        InitEmpty(lowerT, lower);
        return lower;
    }

    // each entry is 512gb
    pub const L4 = extern struct {
        entries: [512]Entry,
        tables: [512]?*L3,

        pub fn MapPage(this: *Table.L4, phys: Mem.PhysPagePtr, virt: Mem.PagePtr, pageFlags: VMM.PageFlags, canOverwrite: bool, alloc: std.mem.Allocator) !void {
            const indices = GetIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = try GetOrCreateTable(l4, L4, l4, indices[3]);
            const l2 = try GetOrCreateTable(l4, L3, l3, indices[2]);
            const l1 = try GetOrCreateTable(l4, L2, l2, indices[1]);
            try Reserve.Allocate(alloc);

            if (!canOverwrite and l1[indices[0]].present)
                return error.Overwrite;

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

        pub fn GetPhysAddrFromVirt(this: *@This(), virt: Mem.PagePtr) Mem.PhysPagePtr {
            const indices = Table.GetIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse @panic("not mapped");
            const l2 = l3.tables[indices[2]] orelse @panic("not mapped");
            if (l2.entries[indices[1]].present and l2.entries[indices[1]].isHuge)
                return @ptrFromInt((l2.entries[indices[1]].address + indices[0]) * Mem.pageSize);
            const l1 = l2.tables[indices[1]] orelse @panic("not mapped");
            if (!l1[indices[0]].present) @panic("not mapped");
            return @ptrFromInt(l1[indices[0]].address * Mem.pageSize);
        }

        pub fn IsAvailable(this: *@This(), page: Mem.PagePtr) bool {
            const indices = GetIndicesFromVirtAddr(page);
            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse return true;
            const l2 = l3.tables[indices[2]] orelse return true;
            if (l2.entries[1].present and l2.entries[1].isHuge)
                return false;

            const l1 = l2.tables[indices[1]] orelse return true;
            return !l1[indices[0]].present;
        }

        pub fn IsRegionAvailable(this: *@This(), region: Mem.PageSlice) bool {
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

    fn GetVirtAddrFromindices(l4: Index, l3: Index, l2: Index, l1: Index) Mem.PagePtr {
        const ul4: usize = l4;
        const ul3: usize = l3;
        const ul2: usize = l2;
        const ul1: usize = l1;

        const addr: usize = (ul1 << 12) | (ul2 << 21) | (ul3 << 30) | (ul4 << 39);
        const mask: usize = @truncate(std.math.boolMask(usize, true) << 48);
        const full: usize = addr | if (l4 & (1 << 8) > 1) mask else 0;
        return @ptrFromInt(full);
    }

    fn GetIndicesFromVirtAddr(addr: Mem.PagePtr) [4]Index {
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

    fn InitEmpty(comptime T: type, table: *T) void {
        @memset(std.mem.asBytes(table), 0);
    }

    fn GetLowerType(T: type) type {
        return switch (T) {
            L4 => L3,
            L3 => L2,
            L2 => L1,
            else => @compileError("nuh uh"),
        };
    }
};

pub const pageTableStart = Mem.kernelVirtBase - 4096 * 512 * 512;
pub const heapRange = @as(Mem.PageManyPtr, @ptrFromInt(Mem.kernelVirtBase))[0 .. 512 * 512 * 510];
pub var tableAllocator: PageAllocator = undefined;

pub var l4Table: Table.L4 align(4096) = undefined;
var l3KernelTable: Table.L3 align(4096) = undefined;
var l2KernelTable: Table.L2 align(4096) = undefined;

var l2PageTableStarter: Table.L2 align(4096) = undefined;
var l1PageTableStarter: Table.L1 align(4096) = undefined;

pub fn Init() void {
    GDT.InitGDT();

    TempMapKernel();
    Table.InitEmpty(Table.L2, &l2PageTableStarter);
    Table.InitEmpty(Table.L1, &l1PageTableStarter);
    Table.Reserve.l2 = &l2PageTableStarter;
    Table.Reserve.l1 = &l1PageTableStarter;

    InvalidatePages();

    const pageTableManyPtr: Mem.PageManyPtr = @ptrFromInt(pageTableStart);
    tableAllocator = PageAllocator.Create(&l4Table, pageTableManyPtr[0 .. 512 * 512], std.testing.failing_allocator);
    const alloc = tableAllocator.allocator();
    tableAllocator.pageTableAllocator = alloc;
}

pub const PageAllocator = struct {
    table: *Table.L4,
    allowedRange: Mem.PageSlice,
    lastAllocEnd: Mem.PageManyPtr,
    pageTableAllocator: std.mem.Allocator,

    const flags: VMM.PageFlags = .{
        .present = true,
        .cacheMode = .Full,
        .executable = true,
        .global = false,
        .kernelOnly = true,
        .writable = true,
    };

    pub fn Create(table: *Table.L4, allowedRange: Mem.PageSlice, pageTableAllocator: std.mem.Allocator) @This() {
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

    pub fn GetAvailableVirtRange(this: *@This(), pageCount: usize) ?Mem.PageSlice {
        var virtStart = this.lastAllocEnd;
        if (virtStart == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;

        while (true) {
            if (this.table.IsRegionAvailable(virtStart[0..pageCount])) break;

            virtStart += 1;
            if (virtStart + pageCount == this.allowedRange.ptr + this.allowedRange.len) virtStart = this.allowedRange.ptr;
            if (virtStart == this.lastAllocEnd) return null;
        }

        return virtStart[0..pageCount];
    }

    fn InternalAlloc(this: *@This(), pageCount: usize) !Mem.PageSlice {
        const result = this.GetAvailableVirtRange(pageCount) orelse return error.OutOfVirtAddrSpace;
        this.lastAllocEnd = result.ptr + pageCount;
        // TODO: handle errors

        for (result) |*page| {
            const phys = try PMM.AllocatePage();
            try this.table.MapPage(phys, page, flags, false, this.pageTableAllocator);
        }

        @memset(result, undefined);
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
            try this.table.MapPage(phys, page, flags, false, this.pageTableAllocator);
            pagesAllocated += 1;
        }

        @memset(extraPages, undefined);
        return true;
    }

    fn InternalFree(this: *@This(), pages: Mem.PageSlice) void {
        @memset(pages, undefined);

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
