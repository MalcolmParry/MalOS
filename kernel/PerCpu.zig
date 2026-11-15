const std = @import("std");
const arch = @import("arch/arch.zig").current;
const Thread = @import("proc/Thread.zig");
const PerCpu = @This();

pub var bsp: PerCpu = .{
    .arch_specific = undefined,
    .thread = .{ .current = undefined, .idle = undefined },
};

arch_specific: arch.CpuLocal,
thread: Thread.CpuLocal,

pub fn get() *PerCpu {
    return arch.getPerCpu();
}
