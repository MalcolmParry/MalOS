const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");

const Tables = struct {
    const Entry = packed struct {
        present: bool,
        writable: bool,
        user: bool,
        writeThrough: bool, // ?
        disableCache: bool,
        // cpu sets this, should be set to false by default
        accessed: bool = false,
        available: bool = false,
        isHuge: bool,
        available2: u4 = 0,
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
            .address = 0,
            .disableExecute = false,
        };
    };

    // each entry is 512gb
    const L4 = extern struct { entries: [512]Entry, tables: [512]?*L3 };

    // each entry is 1gb
    const L3 = extern struct { entries: [512]Entry, tables: [512]?*L2 };

    // each entry is 2mb
    const L2 = extern struct { entries: [512]Entry, tables: [512]?*L1 };

    // each entry is 4kb
    const L1 = [512]Entry;

    fn GetVirtAddrFromIndicies(l4: usize, l3: usize, l2: usize, l1: usize) usize {
        const addr: usize = (l1 << 12) | (l2 << 21) | (l3 << 30) | (l4 << 39);
        const mask: usize = @truncate(std.math.maxInt(usize) <<| 48);
        return addr | if (l4 > 0) mask else 0;
    }
};

pub const kernelHeapStart = Mem.kernelVirtBase + 4096 * 512 * 512;

var l4Table: Tables.L4 align(4096) = undefined;
var l3KernelTable: Tables.L3 align(4096) = undefined;
var l2KernelTable: Tables.L2 align(4096) = undefined;

var l2KernelHeap: Tables.L2 align(4096) = undefined;
var l1KernelHeapStarter: Tables.L1 align(4096) = undefined;

pub fn PreInit() void {
    @branchHint(.cold); // stop from inlining
    GDT.InitGDT();

    TempMapKernel();
    @memset(&l1KernelHeapStarter, Tables.Entry.Blank);
    @memset(&l2KernelHeap.entries, Tables.Entry.Blank);
    @memset(&l2KernelHeap.tables, null);

    l2KernelHeap.tables[0] = &l1KernelHeapStarter;
    l2KernelHeap.entries[0] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThrough = false,
        .disableCache = false,
        .isHuge = false,
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
        .address = @intCast((@intFromPtr(&l2KernelHeap.entries) - Mem.kernelVirtBase) / Mem.pageSize),
        .disableExecute = false,
    };

    InvalidatePages();
}

pub fn InvalidatePages() void {
    SetCr3(@intFromPtr(&l4Table) - Mem.kernelVirtBase);
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
        .address = @intCast((@intFromPtr(&l3KernelTable.entries) - Mem.kernelVirtBase) >> 12),
        .disableExecute = false,
    };

    @memset(l4Table.entries[0..511], Tables.Entry.Blank);
    @memset(l4Table.tables[0..511], null);

    @memset(l3KernelTable.entries[0..510], Tables.Entry.Blank);
    @memset(l3KernelTable.tables[0..510], null);

    l3KernelTable.entries[511] = Tables.Entry.Blank;
    l3KernelTable.tables[511] = null;
}

fn SetCr3(physAddr: u64) void {
    asm volatile (
        \\mov %[addr], %%cr3
        :
        : [addr] "rdi" (physAddr),
    );
}
