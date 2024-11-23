const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");

pub export fn ISR(intNum: u8) callconv(.SysV) void {
    switch (intNum) {
        else => {
            TTY.Print("Interrupt {d}\n", .{intNum});
            Arch.Interrupt.Disable();
            Arch.halt();
        },
    }
}

pub fn Syscall(func: u64, args: [6]u64) u64 {
    _ = func;
    _ = args;

    TTY.Print("syscall\n", .{});

    return 0;
}
