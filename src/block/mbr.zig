const std = @import("std");
const BlockDevice = @import("BlockDevice.zig");
const Part = @import("Partition.zig");
const devfs = @import("../fs/devfs.zig");
const gpa = @import("../heap/gpa.zig");

pub fn partScan(bd: *BlockDevice, name: []const u8) !void {
    const alloc = gpa.allocator;
    if (bd.blockSize() < 512) {
        std.log.warn("block size too small for mbr part scan on {s}", .{name});
        return;
    }

    const block = try alloc.alloc(u8, bd.blockSize());
    defer alloc.free(block);

    try bd.read(0, block);

    if (block[510] != 0x55 or block[511] != 0xaa) return;

    const entries: *align(1) [4]Entry = @ptrCast(block.ptr + 0x01be);
    var new_name: [64]u8 = undefined;
    std.debug.assert(name.len + 2 <= 64);
    @memcpy(new_name[0..name.len], name);
    new_name[name.len] = 'p';

    for (entries) |entry| {
        if (entry.boot_indicator != 0 and entry.boot_indicator != 0x80) return;
        if (entry.sys_id == 0xee) return;
    }

    for (entries, 0..) |*entry, i| {
        switch (entry.sys_id) {
            0x00 => continue,
            0x05, 0x0f, 0x85 => continue,
            else => {},
        }

        const start: u64 = entry.rel_sector;
        const count: u64 = entry.sector_count;
        if (start == 0 or count == 0 or start + count > bd.block_count) continue;

        new_name[name.len + 1] = @intCast('0' + i);
        const part = try alloc.create(Part);
        errdefer alloc.destroy(part);
        part.* = .init(bd, entry.rel_sector, entry.sector_count);
        try devfs.registerDisk(new_name[0 .. name.len + 2], &part.bd);
    }
}

const Entry = extern struct {
    boot_indicator: u8,
    start_head: u8,
    start_sector: u16,
    sys_id: u8,
    end_head: u8,
    end_sector: u16,
    rel_sector: u32,
    sector_count: u32,

    comptime {
        std.debug.assert(@sizeOf(Entry) == 16);
    }
};
