const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("x86_64.zig");
const apic = @import("apic.zig");
const PageAlloc = @import("../../heap/PageAllocator.zig");
const ap_trampoline = @embedFile("ap_trampoline");
const log = std.log.scoped(.acpi);

pub var maybe_sdp: ?Sdp = null;
pub var ap_trampoline_phys_page: *mem.PhysPage = undefined;

pub const Sdp = union(enum) {
    rsdp: Rsdp,
    xsdp: Xsdp,
};

pub const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oemid: [6]u8,
    revision: u8,
    rsdt_addr: u32,
};

pub const Xsdp = extern struct {
    rsdp: Rsdp,
    len: u32,
    xsdt_addr: u64 align(4),
    ext_checksum: u8,
    reserved: [3]u8,
};

const SdtHeader = extern struct {
    signature: [4]u8,
    len: u32 align(1),
    rev: u8,
    checksum: u8,
    oemid: [6]u8,
    oem_table_id: [8]u8,
    oem_rev: u32 align(1),
    creator_id: u32 align(1),
    creator_rev: u32 align(1),

    fn doChecksum(header: *const SdtHeader) bool {
        var sum: u8 = 0;
        for (@as([*]const u8, @ptrCast(header))[0..header.len]) |b| sum +%= b;
        return sum == 0;
    }
};

const Madt = extern struct {
    sdt: SdtHeader,
    local_apic_addr: u32 align(1),
    flags: u32 align(1),

    const Entry = extern struct {
        kind: Kind,
        len: u8,

        const Kind = enum(u8) {
            local_apic = 0,
            io_apic = 1,
            io_apic_int_src_override = 2,
            io_apic_non_maskable_int_src = 3,
            local_apic_non_maskable_ints = 4,
            local_apic_addr_override = 5,
            local_x2_apic = 9,
            _,
        };
    };

    const LocalApic = extern struct {
        entry: Entry,
        acpi_proc_id: u8,
        apic_id: u8,
        flags: u32 align(1),
    };
};

pub fn initSmp() !void {
    if (apic.use_pic) return;
    const sdp = maybe_sdp orelse {
        return;
    };

    log.debug("{any}", .{sdp});

    switch (sdp) {
        .rsdp => |rsdp| {
            const rsdt: *SdtHeader = @ptrFromInt(rsdp.rsdt_addr + mem.direct_map_base);
            if (!rsdt.doChecksum()) return error.BadChecksum;

            const entry_count = (rsdt.len - @sizeOf(SdtHeader)) / 4;
            const entries = @as([*]align(1) const u32, @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(SdtHeader)))[0..entry_count];
            for (entries) |entry_ptr| {
                const sdt: *SdtHeader = @ptrFromInt(entry_ptr + mem.direct_map_base);
                try parseSdt(sdt);
            }
        },
        .xsdp => |xsdp| {
            const rsdt: *SdtHeader = @ptrFromInt(xsdp.xsdt_addr + mem.direct_map_base);
            if (!rsdt.doChecksum()) return error.BadChecksum;

            const entry_count = (rsdt.len - @sizeOf(SdtHeader)) / 8;
            const entries = @as([*]align(1) const u64, @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(SdtHeader)))[0..entry_count];
            for (entries) |entry_ptr| {
                const sdt: *SdtHeader = @ptrFromInt(entry_ptr + mem.direct_map_base);
                try parseSdt(sdt);
            }
        },
    }
}

fn parseSdt(sdt: *SdtHeader) !void {
    if (sdt.len < @sizeOf(SdtHeader)) return;
    if (!sdt.doChecksum()) log.warn("bad checksum, continuing anyway", .{});
    log.debug("{any}", .{sdt});
    log.debug("'{s}' '{s}'", .{ sdt.signature, sdt.oemid });

    if (std.mem.eql(u8, &sdt.signature, "APIC")) {
        try parseMadt(sdt);
    }
}

fn parseMadt(sdt: *SdtHeader) !void {
    const madt: *Madt = @fieldParentPtr("sdt", sdt);
    const madt_end = @intFromPtr(madt) + sdt.len;
    var entry: *Madt.Entry = @ptrFromInt(@intFromPtr(madt) + @sizeOf(Madt));

    const boot_apic_id: u8 = @truncate(arch.cpu.cpuid(1, 0).ebx >> 24);
    log.debug("boot apic id: {}", .{boot_apic_id});

    while (@intFromPtr(entry) < madt_end) : (entry = @ptrFromInt(@intFromPtr(entry) + entry.len)) {
        switch (entry.kind) {
            .local_apic => {
                const local_apic: *Madt.LocalApic = @fieldParentPtr("entry", entry);
                log.debug("{any}", .{local_apic});
            },
            else => {
                log.debug("{any}", .{entry});
            },
        }
    }

    const ap_trampoline_bytes = @as([*]u8, @ptrFromInt(@intFromPtr(ap_trampoline_phys_page) + mem.direct_map_base))[0..4096];
    @memcpy(ap_trampoline_bytes[0..ap_trampoline.len], ap_trampoline);
    const ap_params: *ApParams = @ptrFromInt(@intFromPtr(ap_trampoline_bytes) + 0xd00);

    const ap_page_table = try arch.paging.createTable();
    try arch.paging.mapPage(ap_page_table, .l4, @ptrCast(ap_trampoline_phys_page), ap_trampoline_phys_page, .{
        .cache_mode = .full,
        .executable = true,
        .global = false,
        // have to map as user page bc it is in lower half
        .user = true,
        .writable = true,
    });

    const trampoline_page: u8 = @intCast(@intFromPtr(ap_trampoline_phys_page) / 4096);
    entry = @ptrFromInt(@intFromPtr(madt) + @sizeOf(Madt));
    while (@intFromPtr(entry) < madt_end) : (entry = @ptrFromInt(@intFromPtr(entry) + entry.len)) {
        if (entry.kind != .local_apic) continue;
        const lapic_entry: *Madt.LocalApic = @fieldParentPtr("entry", entry);
        if (lapic_entry.apic_id == boot_apic_id) continue;
        if (lapic_entry.flags & 1 == 0) continue;
        const lapic = apic.local_apic;
        const apic_id_shifted = @as(u32, lapic_entry.apic_id) << 24;

        const stack_size = 32 * 1024;
        const stack = try PageAlloc.global.alloc(stack_size / 4096, .{
            .cache_mode = .full,
            .global = true,
            .writable = true,
            .user = false,
            .executable = false,
        });

        if (@intFromPtr(ap_page_table.physPage()) > std.math.maxInt(u32)) @panic("ap page table cant fit in u32");
        ap_params.* = .{
            .cr3 = @intFromPtr(ap_page_table.physPage()),
            .sp = @intFromPtr(stack.ptr) + stack_size,
            .entry = @intFromPtr(&apEntry),
            .started = .init(0),
        };

        lapic.icr[1].val = apic_id_shifted;
        lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0xc500;
        while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();

        lapic.icr[1].val = apic_id_shifted;
        lapic.icr[0].val = lapic.icr[0].val & 0xfff0_0000 | 0x8500;
        while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();
        apic.tscBusyWait(10 * std.time.ns_per_ms);

        for (0..2) |_| {
            lapic.err_status.val = 0;
            lapic.icr[1].val = apic_id_shifted;
            lapic.icr[0].val = lapic.icr[0].val & 0xfff0_f800 | 0x0000_0600 | trampoline_page;
            apic.tscBusyWait(std.time.ns_per_us * 200);
            while (lapic.icr[0].val & (1 << 12) > 0) std.atomic.spinLoopHint();
        }

        const started = apic.getMonotonicNs();
        while (ap_params.started.load(.acquire) == 0) {
            if (apic.getMonotonicNs() - started > std.time.ns_per_s) {
                log.warn("timeout while starting ap {}", .{lapic_entry.apic_id});
                return;
            }
            std.atomic.spinLoopHint();
        }
    }
}

const ApParams = extern struct {
    cr3: u64,
    sp: u64,
    entry: u64,
    started: std.atomic.Value(u64),
};

fn apEntry() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    arch.outb(0x3f8, 'a');
    arch.outb(0x3f8, 'p');
    arch.outb(0x3f8, '\r');
    arch.outb(0x3f8, '\n');
    arch.spinWait();
}
