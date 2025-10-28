const std = @import("std");
const arch = @import("Arch.zig");

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, returnAddress: ?usize) noreturn {
    _ = trace;
    _ = returnAddress;

    std.log.err("\n{s}\n", .{str});
    arch.interrupt.disable();
    arch.spinWait();
}
