const std = @import("std");
const arch = @import("Arch.zig");

pub fn isr(intNum: u8) callconv(.SysV) void {
    switch (intNum) {
        else => {
            std.log.info("Interrupt {d}\n", .{intNum});
            arch.interrupt.disable();
            arch.halt();
        },
    }
}

pub fn syscall(func: u64, args: [6]u64) u64 {
    _ = func;
    _ = args;

    std.log.info("syscall\n", .{});

    return 0;
}
