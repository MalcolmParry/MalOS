const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");

pub export fn ISR(intNum: u8) callconv(.SysV) void {
    switch (intNum) {
        else => {
            TTY.Print("Interrupt {d}\n", .{intNum});
            Arch.cli();
            Arch.hlt();
        },
    }
}

// return value is in rax
pub export fn Syscall(rax: u64, rbx: u64, rdx: u64, rcx: u64) callconv(.SysV) u64 {
    _ = rax;
    _ = rbx;
    _ = rcx;
    _ = rdx;

    TTY.Print("syscall\n", .{});

    return 0;
}
