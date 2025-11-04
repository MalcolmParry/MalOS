const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");

/// Symbol as it appears in symbol_table module
/// Definition also used by build file
/// Symbols in the module will be sorted by address
pub const Symbol = extern struct {
    addr: usize,
    /// offset into symbol_names module
    name_offset: u16,
    name_len: u8,
};

var symbol_table: ?[]Symbol = null;
var symbol_names: ?[]u8 = null;

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    @branchHint(.cold);
    getSymbolTable();
    _ = trace;

    var iter = std.debug.StackIterator.init(return_address orelse @returnAddress(), @frameAddress());
    var last_addr: usize = 0;
    while (iter.next()) |addr| {
        if (last_addr != addr)
            writeTraceAddr(addr);
        last_addr = addr;
    }

    std.log.err("Kernel Panic: {s}\n", .{str});
    arch.interrupt.disable();
    arch.spinWait();
}

fn getSymbolTable() void {
    for (mem.modules.items) |*module| {
        if (module.data == null) continue;
        const data = module.data.?;
        const name = module.name();

        if (std.mem.eql(u8, name, "symbol_table")) {
            const count = data.len / @sizeOf(Symbol);
            const many_ptr: [*]Symbol = @ptrCast(@alignCast(data));
            symbol_table = many_ptr[0..count];
        }

        if (std.mem.eql(u8, name, "symbol_names")) {
            symbol_names = data;
        }
    }
}

fn writeTraceAddr(addr: usize) void {
    if (symbol_table != null and symbol_names != null) {
        const sym = getSymbolFromAddr(addr);
        const name = getSymbolName(sym);
        std.log.err("{s} ", .{name});
    }

    std.log.err("at 0x{x}\n", .{addr});
}

fn getSymbolName(sym: *Symbol) []u8 {
    return symbol_names.?[sym.name_offset .. sym.name_offset + sym.name_len];
}

fn getSymbolFromAddr(addr: usize) *Symbol {
    var start: usize = 0;
    var end: usize = symbol_table.?.len;

    while (true) {
        const index = (start + end) / 2;
        const sym = &symbol_table.?[index];
        if (end == start + 1) return sym;

        if (addr < sym.addr) {
            end = index;
        } else if (addr > sym.addr) {
            start = index;
        } else {
            return sym;
        }
    }
}
