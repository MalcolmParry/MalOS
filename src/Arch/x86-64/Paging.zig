const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");

const Tables = struct {
    const Entry = packed struct {
        present: bool,
        writable: bool,
        user: bool,
        writeThough: bool, // ?
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
            .writeThough = false,
            .disableCache = false,
            .isHuge = false,
            .address = 0,
            .disableExecute = false,
        };
    };

    const L4 = [512]Entry; // each entry is 512gb
    const L3 = [512]Entry; // each entry is 1gb
    const L2 = [512]Entry; // each entry is 2mb
    const L1 = [512]Entry; // each entry is 4kb
};

const l4PagePhys = @extern(*Tables.L4, .{ .name = "page_table_l4" });
var l4Page: *Tables.L4 = undefined;

const l3PagePhys = @extern(*Tables.L3, .{ .name = "page_table_l3" });
var l3Page: *Tables.L3 = undefined;

const l2PagePhys = @extern(*Tables.L2, .{ .name = "page_table_l2" });
var l2Page: *Tables.L2 = undefined;

var l2Starter: Tables.L2 = undefined;

pub fn PreInit() void {
    @branchHint(.cold); // stop from inlining
    l4Page = @ptrFromInt(@intFromPtr(l4PagePhys) + Mem.kernelVirtBase);
    l3Page = @ptrFromInt(@intFromPtr(l3PagePhys) + Mem.kernelVirtBase);
    l2Page = @ptrFromInt(@intFromPtr(l2PagePhys) + Mem.kernelVirtBase);

    GDT.InitGDT();

    TempMap();
    @memset(&l2Starter, Tables.Entry.Blank);

    InvalidatePages();
}

pub fn InvalidatePages() void {
    SetCr3(@intFromPtr(l4PagePhys));
}

fn TempMap() void {
    for (l2Page, 0..) |*entry, i| {
        entry.* = .{
            .present = true,
            .writable = true,
            .user = false,
            .writeThough = false,
            .disableCache = false,
            .isHuge = true,
            .address = @as(u40, @intCast(i)) * 512,
            .disableExecute = false,
        };
    }

    l3Page[510] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThough = false,
        .disableCache = false,
        .isHuge = false,
        .address = @intCast(@intFromPtr(l2PagePhys) >> 12),
        .disableExecute = false,
    };

    l4Page[511] = .{
        .present = true,
        .writable = true,
        .user = false,
        .writeThough = false,
        .disableCache = false,
        .isHuge = false,
        .address = @intCast(@intFromPtr(l3PagePhys) >> 12),
        .disableExecute = false,
    };

    @memset(l4Page[0..511], Tables.Entry.Blank);
    @memset(l3Page[0..510], Tables.Entry.Blank);
    l3Page[511] = Tables.Entry.Blank;
}

fn SetCr3(physAddr: u64) void {
    asm volatile (
        \\mov %[addr], %%cr3
        :
        : [addr] "rax" (physAddr),
    );
}
