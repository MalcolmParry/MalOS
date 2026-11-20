const std = @import("std");
const arch = @import("x86_64.zig");
const pic = @import("pic.zig");
const pit = @import("../../drivers/x86/pit.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const log = std.log.scoped(.time);

var apic_hz: u64 = undefined;
var tsc_hz: u64 = undefined;
var tsc_offset: u64 = undefined;

pub fn init() !void {
    tsc_offset = -%arch.cpu.rdtsc();
    try acpi.parse();

    pic.init();
    if (arch.cpu.cpuid(1, 0).edx & (1 << 9) == 0) {
        log.warn("no apic, falling back to pic", .{});
        pic.setMask(0b1111_1111_1111_1110);
        pit.init();
        calibrate();
        return;
    }

    try apic.init();
    calibrate();
}

fn calibrate() void {
    const fs_per_ms = 1_000_000_000_000;
    const fs_per_s = fs_per_ms * 1000;
    const calibrate_fs = (10 * fs_per_ms) / pit.period_fs * pit.period_fs;
    const calibrate_duration: std.Io.Duration = .{ .nanoseconds = calibrate_fs / 1_000_000 };
    var apic_readings: [3]u64 = undefined;
    var tsc_readings: [3]u64 = undefined;

    const use_apic = !apic.use_pic;
    for (&apic_readings, &tsc_readings) |*apic_reading, *tsc_reading| {
        pit.arm(calibrate_fs / pit.period_fs);
        if (use_apic) apic.writeReg(.initial_count, 0xffff_ffff);
        const start_tsc = arch.cpu.rdtsc();

        pit.busyWait();
        const end_apic = if (use_apic) apic.readReg(.current_count) else 0;
        const end_tsc = arch.cpu.rdtsc();

        apic_reading.* = 0xffff_ffff - end_apic;
        tsc_reading.* = end_tsc - start_tsc;
    }

    if (use_apic) {
        apic.writeReg(.initial_count, 0);
        std.mem.sort(u64, &apic_readings, {}, std.sort.asc(u64));
        const median_apic_reading = apic_readings[apic_readings.len / 2];
        apic_hz = @intCast(@as(u128, median_apic_reading) * fs_per_s / calibrate_fs);
        log.info("{} apic ticks in {f}, {} hz", .{ median_apic_reading, calibrate_duration, apic_hz });
    }

    std.mem.sort(u64, &tsc_readings, {}, std.sort.asc(u64));
    const median_tsc_reading = tsc_readings[tsc_readings.len / 2];
    tsc_hz = @intCast(@as(u128, median_tsc_reading) * fs_per_s / calibrate_fs);
    log.info("{} tsc ticks in {f}, {} hz", .{ median_tsc_reading, calibrate_duration, tsc_hz });
    log.info("tsc offset: -{}, -{f}", .{ -%tsc_offset, std.Io.Duration{ .nanoseconds = tscTicksToNs(-%tsc_offset) } });
}

fn tscTicksToNs(ticks: u64) u64 {
    return @intCast(@as(u128, ticks) * std.time.ns_per_s / tsc_hz);
}

fn tscTicksFromNs(ns: u64) u64 {
    return @intCast((@as(u128, ns) * tsc_hz + std.time.ns_per_s - 1) / std.time.ns_per_s);
}

pub fn setTimerNs(ns: u64) void {
    if (apic.use_pic) {
        // dont need to do anything bc pit is set to be periodic
        return;
    }

    const ticks128 = (@as(u128, ns) * apic_hz + std.time.ns_per_s - 1) / std.time.ns_per_s;
    const ticks: u32 = @min(@max(1, ticks128), std.math.maxInt(u32));
    if (ticks < ticks128) {
        @branchHint(.cold);
        std.log.warn("tried to set apic timer for {} ticks, clamping to {} ticks", .{ ticks128, std.math.maxInt(u32) });
    }

    apic.writeReg(.initial_count, ticks);
}

pub fn getBootNs() u64 {
    return tscTicksToNs(arch.cpu.rdtsc() +% tsc_offset);
}

pub fn getBootNsOrdered() u64 {
    return tscTicksToNs(arch.cpu.rdtscOrdered() +% tsc_offset);
}

pub fn busyWaitNs(ns: u64) void {
    startPolledTimerNs(ns).busyWait();
}

pub fn startPolledTimerNs(ns: u64) PolledTimer {
    return .{ .until_tsc_ticks = arch.cpu.rdtsc() +% tscTicksFromNs(ns) };
}

pub const PolledTimer = struct {
    until_tsc_ticks: u64,

    pub fn poll(timer: PolledTimer) bool {
        return arch.cpu.rdtsc() >= timer.until_tsc_ticks;
    }

    pub fn busyWait(timer: PolledTimer) void {
        while (arch.cpu.rdtsc() < timer.until_tsc_ticks) std.atomic.spinLoopHint();
    }
};
