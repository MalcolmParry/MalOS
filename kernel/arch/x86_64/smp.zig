const std = @import("std");
const arch = @import("x86_64.zig");
const mem = @import("../../memory.zig");
const apic = @import("apic.zig");
const gdt = @import("gdt.zig");
const time = @import("time.zig");
const gpa = @import("../../heap/gpa.zig").allocator;
const PerCpu = @import("../../PerCpu.zig");
const Thread = @import("../../proc/Thread.zig");
const scheduler = @import("../../proc/scheduler.zig");
const ap_trampoline = @embedFile("ap_trampoline");
const options = @import("options");
const log = std.log.scoped(.smp);

pub var ap_trampoline_phys_page: *mem.PhysPage = undefined;
pub var ap_count: u32 = 0;
pub var ap_apic_ids: [options.max_cpus]u8 = undefined;

pub fn init() !void {
    if (apic.use_pic) return;
    if (ap_count == 0) return;

    const ap_trampoline_bytes = @as([*]u8, @ptrFromInt(@intFromPtr(ap_trampoline_phys_page) + mem.direct_map_base))[0..4096];
    @memcpy(ap_trampoline_bytes[0..ap_trampoline.len], ap_trampoline);
    const ap_params: *ApParams = @ptrFromInt(@intFromPtr(ap_trampoline_bytes) + 0xd00);

    const ap_page_table = try arch.paging.createTable();
    if (@intFromPtr(ap_page_table.physPage()) > std.math.maxInt(u32)) @panic("ap page table cant fit in u32");
    try arch.paging.mapPage(ap_page_table, .l4, @ptrCast(ap_trampoline_phys_page), ap_trampoline_phys_page, .{
        .cache_mode = .full,
        .executable = true,
        .global = false,
        .user = false,
        .writable = true,
    });

    const ap_per_cpus = try gpa.alloc(PerCpu, ap_count);
    for (ap_apic_ids[0..ap_count], ap_per_cpus) |apic_id, *per_cpu| {
        per_cpu.* = .{
            .id = undefined,
            .arch_specific = .{
                .per_cpu = per_cpu,
                .apic_id = apic_id,
                .gdt = .{},
            },
            .thread = undefined,
        };

        try scheduler.initAp(&per_cpu.thread);
        gdt.init(per_cpu);
    }

    const lapic = apic.lapic;
    const trampoline_page: u8 = @intCast(@intFromPtr(ap_trampoline_phys_page) / 4096);
    for (ap_per_cpus) |*per_cpu| {
        const apic_id = per_cpu.arch_specific.apic_id;
        const apic_id_shifted = @as(u32, apic_id) << 24;

        lapic.icr[1].val = apic_id_shifted;
        lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0xc500;
        while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();

        lapic.icr[1].val = apic_id_shifted;
        lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0x8500;
        while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();
    }

    ap_params.* = .{
        .cr3 = @intFromPtr(ap_page_table.physPage()),
        .entry = @intFromPtr(&apEntry),
        .efer = arch.cpu.readMsr(arch.cpu.msrs.efer),
        .cr0 = @bitCast(arch.cpu.Cr0.get()),
        .cr4 = @bitCast(arch.cpu.Cr4.get()),

        .started = undefined,
        .sp = undefined,
        .per_cpu = undefined,
    };

    time.busyWaitNs(10 * std.time.ns_per_ms);
    for (ap_per_cpus) |*per_cpu| {
        const apic_id = per_cpu.arch_specific.apic_id;
        const apic_id_shifted = @as(u32, apic_id) << 24;

        per_cpu.id = PerCpu.cpu_count;
        PerCpu.cpus[PerCpu.cpu_count] = per_cpu;
        PerCpu.cpu_count += 1;

        const stack = per_cpu.thread.current.stack.?;
        ap_params.sp = @intFromPtr(stack.ptr + stack.len);
        ap_params.per_cpu = @intFromPtr(per_cpu);
        ap_params.started.store(0, .release);

        for (0..2) |_| {
            lapic.err_status.val = 0;
            lapic.icr[1].val = apic_id_shifted;
            lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0x4600 | trampoline_page;
            time.busyWaitNs(std.time.ns_per_us * 200);
            while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();
        }

        const timer = time.startPolledTimerNs(std.time.ns_per_s);
        while (ap_params.started.load(.acquire) == 0) {
            if (timer.poll()) {
                log.warn("timeout while starting ap {}", .{apic_id});
                PerCpu.cpu_count -= 1;
                return;
            }

            std.atomic.spinLoopHint();
        }
    }

    for (1..PerCpu.cpu_count) |i| {
        var readings: [tsc_ping_pong_count]i64 = undefined;
        var largest_t1_minus_t2: i64 = std.math.minInt(i64);
        var smallest_t1_minus_t0: i64 = std.math.maxInt(i64);

        for (&readings) |*reading| {
            const t0 = arch.cpu.rdtscOrdered();
            current_ap_id.store(@intCast(i), .monotonic);
            while (current_ap_id.load(.acquire) != 0) std.atomic.spinLoopHint();
            const t2 = arch.cpu.rdtscOrdered();
            const t1 = tsc_reading.load(.monotonic);

            const offset: i64 = @bitCast(t1 -% (t0 + t2) / 2);
            const t1_minus_t2: i64 = @bitCast(t1 -% t2);
            const t1_minus_t0: i64 = @bitCast(t1 -% t0);

            reading.* = offset;
            largest_t1_minus_t2 = @max(largest_t1_minus_t2, t1_minus_t2);
            smallest_t1_minus_t0 = @min(smallest_t1_minus_t0, t1_minus_t0);

            time.busyWaitNs(10 * std.time.ns_per_us);
        }

        std.mem.sort(i64, &readings, {}, std.sort.asc(i64));
        const median_offset = readings[readings.len / 2];

        log.debug("cpu {} tsc offset {}, largest t1 - t2: {}, smallest t1 - t0: {}", .{ i, median_offset, largest_t1_minus_t2, smallest_t1_minus_t0 });

        // TODO: switch to hpet
        if (largest_t1_minus_t2 > 0 or smallest_t1_minus_t0 < 0) {
            log.warn("cpu {} tsc not synced, continuing anyways", .{i});
        }
    }
}

const tsc_ping_pong_count = 64;
var tsc_reading: std.atomic.Value(u64) align(std.atomic.cache_line) = undefined;
var current_ap_id: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0);

const ApParams = extern struct {
    cr3: u64,
    sp: u64,
    entry: u64,
    started: std.atomic.Value(u64),
    per_cpu: u64,
    efer: u64,
    cr0: u64,
    cr4: u64,
};

fn apEntry(per_cpu: *PerCpu) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    arch.paging.getGlobalKernelTable().use();
    arch.cpu.writeMsr(arch.cpu.msrs.fs_base, 0);
    arch.cpu.writeMsr(arch.cpu.msrs.kernel_gs_base, 0);
    arch.cpu.writeMsr(arch.cpu.msrs.gs_base, @intFromPtr(&per_cpu.arch_specific.per_cpu));

    gdt.load();
    arch.interrupt.initAp();
    apic.initAp();

    for (0..tsc_ping_pong_count) |_| {
        while (current_ap_id.load(.monotonic) != per_cpu.id) std.atomic.spinLoopHint();
        tsc_reading.store(arch.cpu.rdtscOrdered(), .monotonic);
        current_ap_id.store(0, .release);
    }

    log.info("cpu {}", .{per_cpu.id});
    arch.spinWait();
}
