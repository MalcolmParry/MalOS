const std = @import("std");
const BlockDevice = @This();

pub const Error = error{
    OutOfRange,
    NotSupported,
    Io,
    Unknown,
};

block_count: u64,
log2_block_size: u6,
read_ptr: *const fn (dev: *BlockDevice, first_block: u64, block_count: u64, buffer: [*]u8) Error!void,
write_ptr: *const fn (dev: *BlockDevice, first_block: u64, block_count: u64, buffer: [*]const u8) Error!void,

pub inline fn blockSize(dev: BlockDevice) u64 {
    return @as(u64, 1) << dev.log2_block_size;
}

pub fn read(dev: *BlockDevice, first_block: u64, buffer: []u8) Error!void {
    const block_count: u64 = buffer.len >> dev.log2_block_size;
    std.debug.assert(block_count << dev.log2_block_size == buffer.len);

    if (block_count == 0) return;
    if (first_block > dev.block_count or block_count > dev.block_count - first_block) return error.OutOfRange;

    try dev.read_ptr(dev, first_block, block_count, buffer.ptr);
}

pub fn write(dev: *BlockDevice, first_block: u64, buffer: []const u8) Error!void {
    const block_count: u64 = buffer.len >> dev.log2_block_size;
    std.debug.assert(block_count << dev.log2_block_size == buffer.len);

    if (block_count == 0) return;
    if (first_block > dev.block_count or block_count > dev.block_count - first_block) return error.OutOfRange;

    try dev.write_ptr(dev, first_block, block_count, buffer.ptr);
}
