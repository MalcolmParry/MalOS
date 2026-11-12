const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("x86_64.zig");
const apic = @import("apic.zig");
const debug = @import("../../debug.zig");

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
    try apic.init();

    const sdp = maybe_sdp orelse {
        return;
    };

    std.log.info("{any}", .{sdp});

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
    if (!sdt.doChecksum()) return error.BadChecksum;
    std.log.info("{any}", .{sdt});
    std.log.info("'{s}' '{s}'", .{ sdt.signature, sdt.oemid });

    if (std.mem.eql(u8, &sdt.signature, "APIC")) {
        try parseMadt(sdt);
    }
}

fn parseMadt(sdt: *SdtHeader) !void {
    const madt: *Madt = @fieldParentPtr("sdt", sdt);
    const madt_end = @intFromPtr(madt) + sdt.len;
    var entry: *Madt.Entry = @ptrFromInt(@intFromPtr(madt) + @sizeOf(Madt));

    const boot_apic_id: u8 = @truncate(arch.cpu.cpuid(1, 0).ebx >> 24);
    std.log.info("boot apic id: {}", .{boot_apic_id});

    while (@intFromPtr(entry) < madt_end) : (entry = @ptrFromInt(@intFromPtr(entry) + entry.len)) {
        switch (entry.kind) {
            .local_apic => {
                const local_apic: *Madt.LocalApic = @fieldParentPtr("entry", entry);
                std.log.info("{any}", .{local_apic});
            },
            else => {
                std.log.info("{any}", .{entry});
            },
        }
    }
}
