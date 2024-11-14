const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");
const std = @import("std");
const builtin = @import("builtin");

export fn KernelMain() noreturn {
    Arch.cli();
    TTY.Clear();
    Arch.Interrupt.Init();
    Arch.sti();

    Arch.int(0x80);

    Arch.hlt();
}
