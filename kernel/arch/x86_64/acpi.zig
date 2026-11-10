const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("x86_64.zig");

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

pub fn initSmp() !void {
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
}
