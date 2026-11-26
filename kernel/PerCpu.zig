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

pub const max_cpus = options.max_cpus;
pub var cpu_count: u32 = 1;
pub var cpus: [max_cpus]?*PerCpu = @as([1]?*PerCpu, .{&bsp}) ++ @as([max_cpus - 1]?*PerCpu, @splat(null));

id: u32,
arch_specific: arch.CpuLocal,
thread: Thread.CpuLocal,

pub fn get() *PerCpu {
    return arch.getPerCpu();
}

pub const UnorderedMask = std.bit_set.Integer(max_cpus);
pub const Mask = struct {
    int: std.atomic.Value(Int),

    const Int = @Int(.unsigned, max_cpus);
    pub const empty: Mask = .{ .int = .init(0) };
    pub const full: Mask = .{ .int = .init((1 << max_cpus) - 1) };

    pub fn load(mask: *Mask, comptime order: std.lang.AtomicOrder) UnorderedMask {
        const int = mask.int.load(order);
        return .{ .mask = int };
    }

    pub fn set(mask: *Mask, cpu: u32, comptime order: std.lang.AtomicOrder) bool {
        const cpu_mask = @as(Int, 1) << @intCast(cpu);
        const old = mask.int.fetchOr(cpu_mask, order);
        return old & cpu_mask > 0;
    }

    pub fn unset(mask: *Mask, cpu: u32, comptime order: std.lang.AtomicOrder) bool {
        const cpu_mask = @as(Int, 1) << @intCast(cpu);
        const old = mask.int.fetchAnd(~cpu_mask, order);
        return old & cpu_mask > 0;
    }

    pub fn setValue(mask: *Mask, cpu: u32, val: bool, comptime order: std.lang.AtomicOrder) bool {
        return if (val) mask.set(cpu, order) else mask.unset(cpu, order);
    }

    pub fn isSet(mask: *Mask, cpu: u32, comptime order: std.lang.AtomicOrder) bool {
        const val = mask.int.load(order);
        return val & (@as(Int, 1) << @intCast(cpu)) > 0;
    }

    pub fn findFirstSet(mask: *Mask) ?u32 {
        const val = mask.int.load(.monotonic);
        const trailing = @ctz(val);
        if (trailing == max_cpus) return null;
        return trailing;
    }

    pub fn findFirstAndUnset(mask: *Mask) ?u32 {
        while (true) {
            const val = mask.int.load(.monotonic);
            const trailing = @ctz(val);
            if (trailing == max_cpus) return null;
            if (mask.int.cmpxchgWeak(val, val & ~(@as(Int, 1) << @intCast(trailing)), .monotonic, .monotonic) == null) return trailing;
        }
    }
};
