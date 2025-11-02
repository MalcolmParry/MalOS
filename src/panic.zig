const std = @import("std");
const arch = @import("arch.zig");

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    @branchHint(.cold);
    std.log.err("\nKernel Panic: {s}\nStack trace:\n", .{str});

    if (trace) |x| {
        var last_addr: usize = 0;
        for (x.instruction_addresses) |addr| {
            if (addr == 0) continue;
            if (last_addr != addr)
                writeTraceAddr(addr);
            last_addr = addr;
        }
    } else {
        var iter = std.debug.StackIterator.init(return_address orelse @returnAddress(), null);
        var last_addr: usize = 0;
        while (iter.next()) |addr| {
            if (last_addr != addr)
                writeTraceAddr(addr);
            last_addr = addr;
        }
    }

    arch.interrupt.disable();
    arch.spinWait();
}

fn writeTraceAddr(addr: usize) void {
    std.log.info("at 0x{x}\n", .{addr});
}
