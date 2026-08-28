const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch.zig").current;
const mem = @import("memory.zig");
const log = @import("log.zig");

/// Symbol as it appears in symbol_table module
/// Definition also used by build file
/// Symbols in the module will be sorted by address
pub const Symbol = extern struct {
    addr: u64,
    /// offset into symbol_names module
    name_offset: u32,
    name_len: u32,
};

var symbol_table: ?[]Symbol = null;
var symbol_names: ?[]u8 = null;

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    @branchHint(.cold);
    _ = trace;
    _ = return_address;

    arch.interrupt.disable();
    log.spinlock.status.store(.unlocked, .monotonic);

    printStackTrace(@frameAddress());
    std.log.err("Kernel Panic: {s}", .{str});
    arch.spinWait();
}

pub fn loadSymbolTable(modules: []const mem.Module) void {
    for (modules) |*module| {
        if (module.data == null) continue;
        const data = module.data.?;
        const name = module.name();

        if (std.mem.eql(u8, name, "symbol_table")) {
            symbol_table = std.mem.bytesAsSlice(Symbol, data);
        }

        if (std.mem.eql(u8, name, "symbol_names")) {
            symbol_names = data;
        }
    }
}

const Frame = extern struct {
    next: ?*Frame,
    ret_addr: usize,
};

pub fn printStackTrace(frame_addr: usize) void {
    if (builtin.omit_frame_pointer) {
        std.log.err("no stack trace available (frame pointer omitted)", .{});
        return;
    }

    var maybe_frame: ?*Frame = @ptrFromInt(frame_addr);

    while (maybe_frame) |frame| {
        writeTraceAddr(frame.ret_addr);
        maybe_frame = frame.next;
    }
}

pub fn writeTraceAddr(addr: usize) void {
    if (getSymbolFromAddr(addr)) |sym| {
        const name = getSymbolName(sym);
        std.log.err("{s} + 0x{x}", .{ name, addr - sym.addr });
    }

    std.log.err("at 0x{x}\n", .{addr});
}

fn getSymbolName(sym: *Symbol) []u8 {
    return symbol_names.?[sym.name_offset..][0..sym.name_len];
}

fn getSymbolFromAddr(addr: usize) ?*Symbol {
    if (symbol_table == null or symbol_names == null) return null;
    var syms = symbol_table.?;

    while (true) {
        if (syms.len == 1) {
            if (syms[0].addr > addr) return null;
            return &syms[0];
        }

        const mid_i = syms.len / 2;
        const mid = &syms[mid_i];

        if (addr < mid.addr) {
            syms = syms[0..mid_i];
        } else if (addr > mid.addr) {
            syms = syms[mid_i..];
        } else {
            return mid;
        }
    }
}
