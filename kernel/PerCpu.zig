const std = @import("std");
const options = @import("options");
const arch = @import("arch/arch.zig").current;
const Thread = @import("proc/Thread.zig");
const PerCpu = @This();

pub var bsp: PerCpu = .{
    .id = 0,
    .arch_specific = undefined,
    .thread = .{ .current = undefined, .idle = undefined },
};

pub var cpu_count: u32 = 1;
pub var cpus: [options.max_cpus]?*PerCpu = @as([1]?*PerCpu, .{&bsp}) ++ @as([options.max_cpus - 1]?*PerCpu, @splat(null));

id: u32,
arch_specific: arch.CpuLocal,
thread: Thread.CpuLocal,

pub fn get() *PerCpu {
    return arch.getPerCpu();
}
