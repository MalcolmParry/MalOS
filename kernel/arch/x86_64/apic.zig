const std = @import("std");
const arch = @import("x86_64.zig");
const mem = @import("../../mem/memory.zig");
const pic = @import("pic.zig");
const pit = @import("../../drivers/x86/pit.zig");
const acpi = @import("acpi.zig");
const PerCpu = @import("../../PerCpu.zig");
const log = std.log.scoped(.apic);

pub const Lapic = extern struct {
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
    icr_low: IcrLowSlot,
    icr_high: IcrHighSlot,
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
    pub const LvtTimer = packed struct(u32) {
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

    const IcrLowSlot = extern struct { val: IcrLow, pad: [3]u32 };
    pub const IcrLow = packed struct(u32) {
        int_vec: u8 = 0,
        delivery_mode: DeliveryMode = .normal,
        dest_mode: DestinationMode = .physical,
        delivery_status: bool = false,
        reserved: u1 = 0,
        level: Level = .assert,
        trigger_mode: TriggerMode = .edge,
        reserved2: u2 = 0,
        dest_short: DestShort = .none,
        reserved3: u12 = 0,

        const DeliveryMode = enum(u3) {
            normal = 0,
            low_priority = 1,
            smi = 2,
            nmi = 4,
            init = 5,
            sipi = 6,
            _,
        };

        const DestinationMode = enum(u1) { physical = 0, logical = 1 };
        const Level = enum(u1) { deassert = 0, assert = 1 };
        const TriggerMode = enum(u1) { edge = 0, level = 1 };
        const DestShort = enum(u2) { none = 0, self = 1, all = 2, all_except_self = 3 };
    };

    const IcrHighSlot = extern struct { val: IcrHigh, pad: [3]u32 };
    pub const IcrHigh = packed struct(u32) {
        reserved: u24 = 0,
        apic_id: u8,
    };

    const Slot = extern struct { val: u32, pad: [3]u32 };
};

pub const timer_int_vec = 0x30;
pub const error_int_vec = 0xfe;
pub const reschedule_int_vec = 0xfd;

pub var use_pic: bool = true;
pub const lapic: *volatile Lapic = @ptrFromInt(mem.getRegion(.lapic).base);

pub fn init() !void {
    const msr_apic_base_enable = 0x800;
    const apic_msr = arch.cpu.readMsr(arch.cpu.msrs.apic_base);
    const phys_apic_base = apic_msr & ~@as(u64, 0xfff);

    // no lock taken for map page
    std.debug.assert(PerCpu.cpu_count == 1);
    try arch.paging.mapPage(arch.paging.getGlobalKernelTable(), .l4, &mem.getRegion(.lapic).page_slice[0], .fromAddr(phys_apic_base), .mmio);

    arch.cpu.writeMsr(arch.cpu.msrs.apic_base, apic_msr | msr_apic_base_enable);
    initAp();
    use_pic = false;
}

pub fn initAp() void {
    writeReg(.spurious_int_vec, 0x1ff);
    writeReg(.divide_config, 3);
    writeReg(.initial_count, 0);
    writeReg(.lvt_timer, .{ .vec = timer_int_vec, .mask = false, .mode = .one_shot });
    writeReg(.lvt_lint0, 1 << 16);
    writeReg(.lvt_err, error_int_vec);
    writeReg(.err_status, 0);
}

pub fn eoi(irq: u8) void {
    if (use_pic) {
        pic.eoi(@intCast(irq));
        return;
    }

    writeReg(.eoi, 0);
}

pub fn handleError(state: *align(1) arch.cpu.State) noreturn {
    writeReg(.err_status, 0);
    const err = readReg(.err_status);

    if (err != 0) {
        log.err("apic error 0x{x} 0b{b}", .{ err, err });
    }

    writeReg(.eoi, 0);
    state.restore();
}

pub fn sendRescheduleIpi(cpu: u32) void {
    arch.interrupt.assertDisabled();
    writeReg(.icr_high, .{ .apic_id = PerCpu.cpus[cpu].?.arch_specific.apic_id });
    writeReg(.icr_low, .{ .delivery_mode = .normal, .int_vec = reschedule_int_vec });
    while (readReg(.icr_low).delivery_status) std.atomic.spinLoopHint();
}

pub var shutting_down: std.atomic.Value(u32) = .init(0);
pub fn shutdownOtherCpus() void {
    if (PerCpu.cpu_count == 1) return;
    std.debug.assert(!use_pic);

    if (shutting_down.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {
        arch.spinWait();
    }

    writeReg(.icr_low, .{ .delivery_mode = .nmi, .dest_short = .all_except_self });
    while (readReg(.icr_low).delivery_status) std.atomic.spinLoopHint();

    const timer = arch.time.startPolledTimerNs(100 * std.time.ns_per_ms);
    while (shutting_down.load(.monotonic) < PerCpu.cpu_count) {
        if (timer.poll()) {
            log.warn("timed out while shutting down all other cpus", .{});
            break;
        }
        std.atomic.spinLoopHint();
    }
}

fn GetRegTypeFromName(comptime name: @EnumLiteral()) type {
    return @FieldType(@FieldType(Lapic, @tagName(name)), "val");
}

pub fn writeReg(comptime reg_name: @EnumLiteral(), val: GetRegTypeFromName(reg_name)) void {
    const reg = &@field(lapic, @tagName(reg_name)).val;
    @as(*volatile u32, @ptrCast(reg)).* = @bitCast(val);
}

pub fn readReg(comptime reg_name: @EnumLiteral()) GetRegTypeFromName(reg_name) {
    const reg = &@field(lapic, @tagName(reg_name)).val;
    const int_ptr: *volatile u32 = @ptrCast(reg);
    return @bitCast(int_ptr.*);
}
