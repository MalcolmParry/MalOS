const std = @import("std");
const arch = @import("x86_64.zig");
const mem = @import("../../memory.zig");
const apic = @import("apic.zig");
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
        // have to map as user page bc it is in lower half
        .user = true,
        .writable = true,
    });

    const ap_per_cpus = try gpa.alloc(PerCpu, ap_count);
    for (ap_apic_ids[0..ap_count], ap_per_cpus) |apic_id, *per_cpu| {
        per_cpu.* = .{
            .id = undefined,
            .arch_specific = .{
                .per_cpu = per_cpu,
                .apic_id = apic_id,
            },
            .thread = undefined,
        };

        try scheduler.initAp(&per_cpu.thread);
    }

    const lapic = apic.local_apic;
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

    apic.tscBusyWait(10 * std.time.ns_per_ms);
    for (ap_per_cpus) |*per_cpu| {
        const apic_id = per_cpu.arch_specific.apic_id;
        const apic_id_shifted = @as(u32, apic_id) << 24;

        per_cpu.id = PerCpu.cpu_count;
        const stack = per_cpu.thread.current.stack.?;
        ap_params.* = .{
            .cr3 = @intFromPtr(ap_page_table.physPage()),
            .sp = @intFromPtr(stack.ptr + stack.len),
            .entry = @intFromPtr(&apEntry),
            .started = .init(0),
            .per_cpu = @intFromPtr(per_cpu),
        };

        for (0..2) |_| {
            lapic.err_status.val = 0;
            lapic.icr[1].val = apic_id_shifted;
            lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0x4600 | trampoline_page;
            apic.tscBusyWait(std.time.ns_per_us * 200);
            while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();
        }

        const started = apic.getMonotonicNs();
        while (ap_params.started.load(.acquire) == 0) {
            if (apic.getMonotonicNs() - started > std.time.ns_per_s) {
                log.warn("timeout while starting ap {}", .{apic_id});
                return;
            }

            std.atomic.spinLoopHint();
        }

        PerCpu.cpus[PerCpu.cpu_count] = per_cpu;
        PerCpu.cpu_count += 1;
    }
}

const ApParams = extern struct {
    cr3: u64,
    sp: u64,
    entry: u64,
    started: std.atomic.Value(u64),
    per_cpu: u64,
};

fn apEntry(per_cpu: *PerCpu) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    arch.paging.getGlobalKernelTable().use();

    log.info("cpu {}", .{per_cpu.id});
    arch.spinWait();
}
