const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");
const VMM = @import("../../VMM.zig");
const PMM = @import("../../PMM.zig");
const Arch = @import("Arch.zig");
const PageAllocator = @import("../../PageAllocator.zig");

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
        var l2: [2]?*align(Mem.pageSize) L2 = @splat(null);
        var l1: [2]?*align(Mem.pageSize) L1 = @splat(null);
        var allocating: bool = false;

        fn AllocateSlice(T: type, slice: []?*align(Mem.pageSize) T, alloc: std.mem.Allocator) !void {
            for (slice) |*table| {
                if (table.* != null) continue;

                table.* = &(try alloc.alignedAlloc(T, .fromByteUnits(Mem.pageSize), 1))[0];
            }
        }

        fn Allocate(alloc: std.mem.Allocator) !void {
            if (allocating) return;
            allocating = true;

            try AllocateSlice(L1, &l1, alloc);
            try AllocateSlice(L2, &l2, alloc);

            allocating = false;
        }

        fn GetTable(T: type) *align(Mem.pageSize) T {
            const slice: []?*align(Mem.pageSize) T = switch (T) {
                L2 => &l2,
                L1 => &l1,
                else => @panic("wrong type"),
            };

            for (slice) |*table| {
                if (table.*) |x| {
                    table.* = null;
                    return x;
                }
            }

            @panic("no table reserved");
        }
    };

    fn GetOrCreateTable(l4: *L4, T: type, table: *T, index: usize) !*GetLowerType(T) {
        const lowerT = GetLowerType(T);

        if (table.tables[index]) |lower|
            return lower;

        const lower = Reserve.GetTable(lowerT);

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

        InitEmpty(lower);
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

        pub fn ClearEntry(this: *@This(), virt: Mem.PagePtr) !void {
            const indices = Table.GetIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse @panic("not mapped");
            const l2 = l3.tables[indices[2]] orelse @panic("not mapped");
            if (l2.entries[indices[1]].present and l2.entries[indices[1]].isHuge)
                l2.entries[indices[1]] = Entry.Blank;
            const l1 = l2.tables[indices[1]] orelse @panic("not mapped");
            if (!l1[indices[0]].present) @panic("not mapped");
            l1[indices[0]] = Entry.Blank;
            InvalidatePage(virt);
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

    fn InitEmpty(table: anytype) void {
        switch (@typeInfo(@TypeOf(table)).pointer.child) {
            L4, L3, L2 => {
                @memset(&table.entries, Entry.Blank);
                @memset(&table.tables, null);
            },
            L1 => @memset(table, Entry.Blank),
            else => @compileError("wrong type"),
        }
    }

    fn GetLowerType(T: type) type {
        return switch (T) {
            L4 => L3,
            L3 => L2,
            L2 => L1,
            else => @compileError("wrong type"),
        };
    }
};

const pageTableL3Index = 510;
const pageTableStart = Table.GetVirtAddrFromindices(511, pageTableL3Index, 0, 0);
pub const heapRange = @as(Mem.PageManyPtr, @ptrCast(Table.GetVirtAddrFromindices(511, 0, 0, 0)))[0 .. 512 * 512 * 510];
pub var tableAllocator: PageAllocator = undefined;

var l4Table: Table.L4 align(4096) = undefined;
var l3KernelTable: Table.L3 align(4096) = undefined;
var l2KernelTable: Table.L2 align(4096) = undefined;

comptime {
    @export(&l4Table.entries, .{ .name = "page_table_l4_virt" });
    @export(&l3KernelTable.entries, .{ .name = "page_table_l3_virt" });
    @export(&l2KernelTable.entries, .{ .name = "page_table_l2_virt" });
}

var l2PageTableStarter: Table.L2 align(4096) = undefined;
var l1PageTableStarter: Table.L1 align(4096) = undefined;

fn EnableExecuteDisable() void {
    const msr = 0xc000_0080;
    const old = Arch.ReadMSR(msr);
    Arch.WriteMSR(msr, old | (1 << 11));
}

pub fn Init() *Table.L4 {
    EnableExecuteDisable();
    GDT.InitGDT();

    @memset(l4Table.entries[0..511], Table.Entry.Blank);
    @memset(l3KernelTable.entries[0..511], Table.Entry.Blank);
    @memset(&l4Table.tables, null);
    @memset(&l3KernelTable.tables, null);
    @memset(&l2KernelTable.tables, null);
    l4Table.tables[511] = &l3KernelTable;
    l3KernelTable.tables[511] = &l2KernelTable;

    Table.InitEmpty(&l2PageTableStarter);
    Table.InitEmpty(&l1PageTableStarter);

    l2PageTableStarter.tables[0] = &l1PageTableStarter;
    l2PageTableStarter.entries[0] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l1PageTableStarter) - Mem.kernelVirtBase) / Mem.pageSize),
        .disableExecute = false,
    };

    l3KernelTable.tables[pageTableL3Index] = &l2PageTableStarter;
    l3KernelTable.entries[pageTableL3Index] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l2PageTableStarter.entries) - Mem.kernelVirtBase) / Mem.pageSize),
        .disableExecute = false,
    };

    InvalidatePages();

    const pageTableManyPtr: Mem.PageManyPtr = @ptrCast(pageTableStart);
    tableAllocator = .Create(&l4Table, pageTableManyPtr[0 .. 512 * 512]);
    Table.Reserve.Allocate(tableAllocator.allocator()) catch @panic("cant allocate tables");

    return &l4Table;
}

pub fn InvalidatePages() void {
    SetCr3(@intFromPtr(&l4Table) - Mem.kernelVirtBase);
}

pub fn InvalidatePage(page: Mem.PagePtr) void {
    asm volatile (
        \\invlpg (%[addr])
        :
        : [addr] "r" (page),
        : .{ .memory = true });
}

fn SetCr3(physAddr: u64) void {
    asm volatile (
        \\movq %[addr], %cr3
        :
        : [addr] "r" (physAddr),
    );
}
