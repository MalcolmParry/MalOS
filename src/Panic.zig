const std = @import("std");
const TTY = @import("TTY.zig");
const Arch = @import("Arch.zig");

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, returnAddress: ?usize) noreturn {
    _ = trace;
    _ = returnAddress;

    TTY.Print("PANIC: {s}\n", .{str});
    Arch.Interrupt.Disable();
    Arch.halt();
}
