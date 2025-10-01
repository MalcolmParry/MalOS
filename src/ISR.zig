const std = @import("std");
const Arch = @import("Arch.zig");

pub export fn ISR(intNum: u8) callconv(.SysV) void {
    switch (intNum) {
        else => {
            std.log.info("Interrupt {d}\n", .{intNum});
            Arch.Interrupt.Disable();
            Arch.halt();
        },
    }
}

pub fn Syscall(func: u64, args: [6]u64) u64 {
    _ = func;
    _ = args;

    std.log.info("syscall\n", .{});

    return 0;
}
