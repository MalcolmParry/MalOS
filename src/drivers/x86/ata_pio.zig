const std = @import("std");
const arch = @import("../../arch/arch.zig").current;
const BlockDevice = @import("../../BlockDevice.zig");

const sector_size = 512;

pub const Drive = struct {
    bd: BlockDevice,
    io_base: u16,
    kind: Kind,

    pub const Kind = enum {
        master,
        slave,
    };
};

const Status = packed struct(u8) {
    err: bool,
    idx: bool,
    corr: bool,
    drq: bool,
    srv: bool,
    df: bool,
    rdy: bool,
    bsy: bool,
};

pub fn getDrive(io_base: u16, kind: Drive.Kind) ?Drive {
    arch.outb(io_base + 6, switch (kind) {
        .master => 0xa0,
        .slave => 0xb0,
    });

    arch.outw(io_base + 2, 0);
    arch.outw(io_base + 3, 0);
    arch.outw(io_base + 4, 0);
    arch.outw(io_base + 5, 0);

    arch.outb(io_base + 7, 0xec);
    if (arch.in(u8, io_base + 7) == 0) return null;

    while (arch.in(Status, io_base + 7).bsy) {}
    if (arch.in(u8, io_base + 4) != 0 or arch.in(u8, io_base + 5) != 0) return null;

    while (true) {
        const status = arch.in(Status, io_base + 7);

        if (status.bsy) {
            std.log.err("drive busy", .{});
            return null;
        }

        if (status.err) {
            std.log.err("drive error", .{});
            return null;
        }

        if (status.drq) break;
    }

    var identity: [256]u16 = undefined;
    arch.cpu.inWordSlice(io_base, &identity);

    if (identity[83] & (1 << 10) == 0) {
        std.log.err("drive doesn't support lba48", .{});
        return null;
    }

    const sector_count = blk: {
        const w0: u64 = identity[100];
        const w1: u64 = identity[101];
        const w2: u64 = identity[102];
        const w3: u64 = identity[103];
        break :blk w0 | (w1 << 16) | (w2 << 32) | (w3 << 48);
    };

    return .{
        .bd = .{
            .block_count = sector_count,
            .log2_block_size = comptime std.math.log2(sector_size),
            .read_ptr = &read,
            .write_ptr = &write,
        },
        .io_base = io_base,
        .kind = kind,
    };
}

fn poll(io_base: u16) !void {
    while (true) {
        const status = arch.in(Status, io_base + 7);

        if (status.err or status.df) {
            @branchHint(.unlikely);
            return error.Io;
        }

        if (status.bsy) continue;
        if (status.drq) return;

        return error.Io;
    }
}

fn read(bd: *BlockDevice, first_block: u64, block_count: u64, buffer_ptr: [*]u8) BlockDevice.Error!void {
    if (block_count > std.math.maxInt(u16)) return error.Unknown;
    std.debug.assert(first_block <= std.math.maxInt(u48));

    const drive: *Drive = @fieldParentPtr("bd", bd);
    const buffer = buffer_ptr[0 .. block_count * sector_size];

    const io_base = drive.io_base;
    arch.outb(io_base + 6, switch (drive.kind) {
        .master => 0x40,
        .slave => 0x50,
    });

    arch.outb(io_base + 2, @truncate(block_count >> 8));
    arch.outb(io_base + 3, @truncate(first_block >> 24));
    arch.outb(io_base + 4, @truncate(first_block >> 32));
    arch.outb(io_base + 5, @truncate(first_block >> 40));

    arch.outb(io_base + 2, @truncate(block_count));
    arch.outb(io_base + 3, @truncate(first_block));
    arch.outb(io_base + 4, @truncate(first_block >> 8));
    arch.outb(io_base + 5, @truncate(first_block >> 16));

    arch.outb(io_base + 7, 0x24);

    for (0..block_count) |i| {
        try poll(io_base);

        const word_ptr: [*]align(1) u16 = @ptrCast(buffer.ptr + i * sector_size);
        arch.cpu.inWordSlice(io_base, word_ptr[0..256]);
    }
}

fn write(bd: *BlockDevice, first_block: u64, block_count: u64, buffer: [*]const u8) BlockDevice.Error!void {
    _ = bd;
    _ = first_block;
    _ = block_count;
    _ = buffer;
    return error.NotSupported;
}
