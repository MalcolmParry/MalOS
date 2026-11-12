const std = @import("std");
const arch = @import("x86_64.zig");
const mem = @import("../../memory.zig");
const PageAlloc = @import("../../heap/PageAllocator.zig");
const pic = @import("pic.zig");
const pit = @import("../../drivers/x86/pit.zig");

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
pub var local_apic: *volatile LocalApic = undefined;
var apic_hz: u64 = undefined;
var tsc_hz: u64 = undefined;
var tsc_offset: u64 = undefined;

pub fn init() !void {
    pic.init();
    if (arch.cpu.cpuid(1, 0).edx & (1 << 9) == 0) {
        std.log.warn("no apic, falling back to pic", .{});
        pic.setMask(0b1111_1111_1111_1110);
        pit.init();
        return;
    }

    const msr_apic_base = 0x1b;
    const msr_apic_base_enable = 0x800;
    const apic_msr = arch.cpu.readMsr(msr_apic_base);
    const phys_apic_base = apic_msr & ~@as(u64, 0xfff);

    const apic_page = try PageAlloc.global.map(@as([*]mem.PhysPage, @ptrFromInt(phys_apic_base))[0..1], .{
        .cache_mode = .disabled,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    local_apic = @ptrCast(apic_page.ptr);

    arch.cpu.writeMsr(msr_apic_base, apic_msr | msr_apic_base_enable);
    local_apic.spurious_int_vec.val = 0x1ff;

    local_apic.divide_config.val = 3;
    local_apic.lvt_timer.val = .{ .vec = timer_int_vec, .mask = true, .mode = .one_shot };

    const fs_per_ms = 1_000_000_000_000;
    const fs_per_s = fs_per_ms * 1000;

    tsc_offset = -%arch.cpu.rdtsc();
    const calibrate_fs = (10 * fs_per_ms) / pit.period_fs * pit.period_fs;
    var apic_readings: [3]u64 = undefined;
    var tsc_readings: [3]u64 = undefined;
    for (&apic_readings, &tsc_readings) |*apic_reading, *tsc_reading| {
        pit.arm(calibrate_fs / pit.period_fs);
        local_apic.initial_count.val = 0xffff_ffff;
        const start_tsc = arch.cpu.rdtsc();
        pit.busyWait();
        const current_ticks = local_apic.current_count.val;
        const end_tsc = arch.cpu.rdtsc();
        apic_reading.* = 0xffff_ffff - current_ticks;
        tsc_reading.* = end_tsc - start_tsc;
    }

    std.mem.sort(u64, &apic_readings, {}, std.sort.asc(u64));
    std.mem.sort(u64, &tsc_readings, {}, std.sort.asc(u64));

    const median_apic_reading = apic_readings[apic_readings.len / 2];
    const median_tsc_reading = tsc_readings[tsc_readings.len / 2];

    apic_hz = @intCast(@as(u128, median_apic_reading) * fs_per_s / calibrate_fs);
    tsc_hz = @intCast(@as(u128, median_tsc_reading) * fs_per_s / calibrate_fs);

    std.log.info("{} apic ticks, {} tsc ticks in {f}", .{ median_apic_reading, median_tsc_reading, std.Io.Duration{ .nanoseconds = calibrate_fs / 1_000_000 } });
    std.log.info("apic freq: {} hz, tsc freq: {} hz", .{ apic_hz, tsc_hz });

    local_apic.initial_count.val = 0;
    local_apic.lvt_timer.val = .{ .mode = .one_shot, .mask = false, .vec = timer_int_vec };
    use_pic = false;
}

pub fn eoi(irq: u8) void {
    if (use_pic) {
        pic.eoi(@intCast(irq));
        return;
    }

    local_apic.eoi.val = 0;
}

pub fn setTimerNs(ns: u64) void {
    if (use_pic) {
        // dont need to do anything bc pit is set to be periodic
        return;
    }

    const ticks128 = (@as(u128, ns) * apic_hz + std.time.ns_per_s - 1) / std.time.ns_per_s;
    const ticks: u32 = @min(@max(1, ticks128), std.math.maxInt(u32));
    if (ticks < ticks128) {
        @branchHint(.cold);
        std.log.warn("tried to set apic timer for {} ticks, clamping to {} ticks", .{ ticks128, std.math.maxInt(u32) });
    }

    local_apic.initial_count.val = ticks;
}

pub fn getMonotonicNs() u64 {
    if (use_pic) {
        return pit.ticks.load(.monotonic) * pit.divisor_period_ns;
    }

    const ticks = arch.cpu.rdtscOrdered() +% tsc_offset;
    return @intCast(@as(u128, ticks) * std.time.ns_per_s / tsc_hz);
}

pub fn tscBusyWait(ns: u64) void {
    const ticks: u64 = @intCast((@as(u128, ns) * tsc_hz + std.time.ns_per_s - 1) / std.time.ns_per_s);
    const end = arch.cpu.rdtscOrdered() + ticks;

    while (arch.cpu.rdtsc() < end) {
        std.atomic.spinLoopHint();
    }
}
