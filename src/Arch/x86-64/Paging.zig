const std = @import("std");
const GDT = @import("GDT.zig");
const Mem = @import("../../Memory.zig");

const Tables = struct {
    const L4 = [512]u64; // each entry is 512gb
    const L3 = [512]u64; // each entry is 1gb
    const L2 = [512]u64; // each entry is 2mb
    const L1 = [512]u64; // each entry is 4kb
};

const l4PagePhys = @extern(*Tables.L4, .{ .name = "page_table_l4" });
var l4Page: *Tables.L4 = undefined;

const l3PagePhys = @extern(*Tables.L3, .{ .name = "page_table_l3" });
var l3Page: *Tables.L3 = undefined;

const l2PagePhys = @extern(*Tables.L2, .{ .name = "page_table_l2" });
var l2Page: *Tables.L2 = undefined;

pub fn PreInit() void {
    @branchHint(.cold); // stop from inlining
    l4Page = @ptrFromInt(@intFromPtr(l4PagePhys) + Mem.kernelVirtBase);
    l3Page = @ptrFromInt(@intFromPtr(l3PagePhys) + Mem.kernelVirtBase);
    l2Page = @ptrFromInt(@intFromPtr(l2PagePhys) + Mem.kernelVirtBase);

    GDT.InitGDT();

    @memset(l4Page[0..255], 0);

    InvalidatePages();
}

pub fn InvalidatePages() void {
    SetCr3(@intFromPtr(l4PagePhys));
}

fn SetCr3(physAddr: u64) void {
    asm volatile (
        \\mov %[addr], %%cr3
        :
        : [addr] "rax" (physAddr),
    );
}
