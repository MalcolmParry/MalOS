const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");
const VMM = @import("../../VMM.zig");

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
                    const result: *Table.L3 = try alloc.alignedAlloc(Table.L3, Mem.pageSize, 1);
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
                }
            };

            const l2 = blk: {
                if (l3.tables[indices[2]]) |x| {
                    break :blk x;
                } else {
                    const result: *Table.L2 = try alloc.alignedAlloc(Table.L2, Mem.pageSize, 1);
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
                }
            };

            const l1 = blk: {
                if (l2.tables[indices[1]]) |x| {
                    break :blk x;
                } else {
                    const result: *Table.L1 = try alloc.alignedAlloc(Table.L1, Mem.pageSize, 1);
                    @memset(&result.entries, Table.Entry.Blank);
                    @memset(&result.tables, null);

                    l2.tables[indices[1]] = result;
                    l2.entries[indices[1]] = .{
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
        const mask: usize = @truncate(std.math.boolMask(usize, true) <<| 48);
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
};

pub const kernelHeapStart = Mem.kernelVirtBase + 4096 * 512 * 512;
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
    @memset(&l1KernelHeapStarter, Table.Entry.Blank);
    @memset(&l2KernelHeap.entries, Table.Entry.Blank);
    @memset(&l2KernelHeap.tables, null);
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

    l3KernelTable.tables[511] = &l2KernelHeap;
    l3KernelTable.entries[511] = .{
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
}

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

    l3KernelTable.tables[510] = &l2KernelTable;
    l3KernelTable.entries[510] = .{
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

    @memset(l3KernelTable.entries[0..510], Table.Entry.Blank);
    @memset(l3KernelTable.tables[0..510], null);

    l3KernelTable.entries[511] = Table.Entry.Blank;
    l3KernelTable.tables[511] = null;
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
