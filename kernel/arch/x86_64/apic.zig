const std = @import("std");
const arch = @import("x86_64.zig");
const mem = @import("../../memory.zig");
const PageAlloc = @import("../../heap/PageAllocator.zig");
const pic = @import("pic.zig");
const pit = @import("../../drivers/x86/pit.zig");
const acpi = @import("acpi.zig");

const LocalApic = extern struct {
    reserved: [2]Slot,
    lapic_id: Slot,
    lapic_version: Slot,
    reserved2: [4]Slot,
    tpr: Slot,
    apr: Slot,
    ppr: Slot,
    eoi: Slot,
    rrd: Slot,
    logical_dest: Slot,
    dst_fmt: Slot,
    spurious_int_vec: Slot,
    isr: [8]Slot,
    tmr: [8]Slot,
    irr: [8]Slot,
    err_status: Slot,
    reserved3: [6]Slot,
    cmci: Slot,
    icr: [2]Slot,
    lvt_timer: LvtTimerSlot,
    lvt_thermal_sensor: Slot,
    lvt_perf_monitor_counter: Slot,
    lvt_lint0: Slot,
    lvt_lint1: Slot,
    lvt_err: Slot,
    initial_count: Slot,
    current_count: Slot,
    reserved4: [4]Slot,
    divide_config: Slot,

    const LvtTimerSlot = extern struct { val: LvtTimer, pad: [3]u32 };
    const LvtTimer = packed struct(u32) {
        vec: u8,
        reserved: u4 = 0,
        delivery_status: bool = false,
        reserved2: u3 = 0,
        mask: bool,
        mode: Mode,
        reserved3: u13 = 0,

        const Mode = enum(u2) {
            one_shot = 0,
            periodic = 1,
            tsc_deadline = 2,
        };
    };

    const Slot = extern struct { val: u32, pad: [3]u32 };
};

const timer_int_vec = 0x30;

pub var use_pic: bool = true;
pub var lapic: *volatile LocalApic = undefined;

pub fn init() !void {
    const msr_apic_base_enable = 0x800;
    const apic_msr = arch.cpu.readMsr(arch.cpu.msrs.apic_base);
    const phys_apic_base = apic_msr & ~@as(u64, 0xfff);

    const apic_page = try PageAlloc.global.map(@as([*]mem.PhysPage, @ptrFromInt(phys_apic_base))[0..1], .{
        .cache_mode = .disabled,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    lapic = @ptrCast(apic_page.ptr);

    arch.cpu.writeMsr(arch.cpu.msrs.apic_base, apic_msr | msr_apic_base_enable);
    initAp();
    use_pic = false;
}

pub fn initAp() void {
    lapic.spurious_int_vec.val = 0x1ff;
    lapic.divide_config.val = 3;
    lapic.initial_count.val = 0;
    lapic.lvt_timer.val = .{ .vec = timer_int_vec, .mask = false, .mode = .one_shot };
    lapic.lvt_lint0.val = 1 << 16;
}

pub fn eoi(irq: u8) void {
    if (use_pic) {
        pic.eoi(@intCast(irq));
        return;
    }

    lapic.eoi.val = 0;
}
