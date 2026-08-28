const std = @import("std");
const arch = @import("arch.zig");
const BlockDevice = @import("../../BlockDevice.zig");

const sector_size = 512;

pub const Drive = struct {
    bd: BlockDevice,
    io_base: u16,
    slave: bool,
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

pub fn getDrive(io_base: u16, slave: bool) ?Drive {
    arch.out(io_base + 6, @as(u8, if (slave) 0xb0 else 0xa0));
    arch.out(io_base + 2, @as(u16, 0));
    arch.out(io_base + 3, @as(u16, 0));
    arch.out(io_base + 4, @as(u16, 0));
    arch.out(io_base + 5, @as(u16, 0));

    arch.out(io_base + 7, @as(u8, 0xec));
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
    for (&identity) |*word| {
        word.* = arch.in(u16, io_base);
    }

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

    std.log.info("sector_count = {}", .{sector_count});

    return .{
        .bd = .{
            .block_count = sector_count,
            .log2_block_size = comptime std.math.log2(sector_size),
            .read = &read,
            .write = &write,
        },
        .io_base = io_base,
        .slave = slave,
    };
}

fn poll(io_base: u16) !void {
    while (true) {
        const status = arch.in(Status, io_base + 7);

        if (status.err or status.df) {
            @branchHint(.unlikely);
            return error.Failed;
        }

        if (status.bsy) continue;
        if (status.drq) return;

        return error.Failed;
    }
}

fn read(bd: *BlockDevice, block_offset: u64, block_count: u64, buffer_ptr: [*]u8) BlockDevice.Error!void {
    if (block_count == 0) return;
    if (block_offset > bd.block_count or block_count > bd.block_count - block_offset) return error.OutOfRange;
    if (block_count > std.math.maxInt(u16)) return error.Unknown;

    const drive: *Drive = @fieldParentPtr("bd", bd);
    const buffer = buffer_ptr[0 .. block_count * sector_size];

    const io_base = drive.io_base;
    arch.out(io_base + 6, @as(u8, if (drive.slave) 0x50 else 0x40));

    arch.out(io_base + 2, @as(u8, @truncate(block_count >> 8)));
    arch.out(io_base + 3, @as(u8, @truncate(block_offset >> 24)));
    arch.out(io_base + 4, @as(u8, @truncate(block_offset >> 32)));
    arch.out(io_base + 5, @as(u8, @truncate(block_offset >> 40)));

    arch.out(io_base + 2, @as(u8, @truncate(block_count & 0xff)));
    arch.out(io_base + 3, @as(u8, @truncate(block_offset)));
    arch.out(io_base + 4, @as(u8, @truncate(block_offset >> 8)));
    arch.out(io_base + 5, @as(u8, @truncate(block_offset >> 16)));

    arch.out(io_base + 7, @as(u8, 0x24));

    for (0..block_count) |i| {
        poll(io_base) catch return error.Unknown;

        asm volatile (
            \\ rep insw
            :
            : [port] "{dx}" (io_base),
              [buffer] "{rdi}" (buffer.ptr + i * sector_size),
              [count] "{rcx}" (256),
            : .{ .rdi = true, .rcx = true, .memory = true });
    }
}

fn write(bd: *BlockDevice, block_offset: u64, block_count: u64, buffer: [*]const u8) BlockDevice.Error!void {
    _ = bd;
    _ = block_offset;
    _ = block_count;
    _ = buffer;
    return error.NotSupported;
}
