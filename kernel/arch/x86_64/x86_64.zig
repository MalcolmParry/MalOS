const std = @import("std");
const mem = @import("../../mem/memory.zig");
const shared = @import("shared");
const virt_layout = @import("../../mem/virt_layout.zig");
const debug = @import("../../debug.zig");
const apic = @import("apic.zig");
const PerCpu = @import("../../PerCpu.zig");
pub const gdt = @import("gdt.zig");

pub const page_size = 4096;

pub const interrupt = @import("interrupt.zig");
pub const multiboot = @import("multiboot2.zig");
pub const paging = @import("paging.zig");
pub const cpu = @import("cpu.zig");
pub const time = @import("time.zig");
pub const initSmp = @import("smp.zig").init;

pub const initBootInfo = multiboot.initBootInfo;

pub const halt = cpu.halt;
pub const spinWait = cpu.spinWait;
pub const shutdownOtherCpus = apic.shutdownOtherCpus;
pub const sendRescheduleIpi = apic.sendRescheduleIpi;

pub const out = shared.arch.out;
pub const outb = shared.arch.outb;
pub const outw = shared.arch.outw;
pub const outl = shared.arch.outl;
pub const in = shared.arch.in;
pub const repInsw = shared.arch.repInsw;
pub const ioWait = shared.arch.ioWait;

const user_copy = @import("user_copy.zig");
pub const copyFromUser = user_copy.copyFromUser;
pub const copyToUser = user_copy.copyToUser;

pub const layout = struct {
    pub const big_region = 4096 * 512 * 512 * 512;
    pub const big_align: std.mem.Alignment = .fromByteUnits(big_region);

    pub const max_user_addr = 0x0000_8000_0000_0000;
    pub const min_kernel_addr = 0xffff_8000_0000_0000;
    pub const kernel_space_size = 0x1_0000_0000_0000_0000 - min_kernel_addr;

    pub const kernel_virt_base: u64 = 0xffff_ffff_c000_0000;
    pub const kernel_region_size = 4096 * 512 * 512;
    pub const direct_map_size = 512 * 1024 * 1024 * 1024;

    pub const requests: []const virt_layout.RequestedRegion = &.{
        .{
            .name = .mmio,
            .size = big_region,
            .sub_regions = &.{
                .{ .name = .lapic, .size = @sizeOf(apic.Lapic), .alignment = .fromByteUnits(page_size) },
            },
        },
    };
};

pub const getPerCpu = cpu.getPerCpu;
pub const CpuLocal = struct {
    apic_id: u8,
    per_cpu: *PerCpu,
    gdt: gdt.CpuLocal,
};

pub fn kernelEntry() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    PerCpu.bsp.arch_specific = .{
        .apic_id = undefined,
        .per_cpu = &PerCpu.bsp,
        .gdt = .{},
    };

    cpu.writeMsr(cpu.msrs.gs_base, @intFromPtr(&PerCpu.bsp.arch_specific.per_cpu));
    cpu.writeMsr(cpu.msrs.kernel_gs_base, 0);
    cpu.writeMsr(cpu.msrs.fs_base, 0);

    @import("../../main.zig").kernelMain() catch |err| {
        debug.dumpErrorAndPanic(err);
    };
}

comptime {
    @export(&kernelEntry, .{ .name = "kernelEntry" });
}
