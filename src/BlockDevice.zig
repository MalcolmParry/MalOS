const std = @import("std");
const BlockDevice = @This();

pub const Error = error{
    OutOfRange,
    NotSupported,
    Unknown,
};

block_count: u64,
log2_block_size: u6,
read: *const fn (dev: *BlockDevice, block_offset: u64, block_count: u64, buffer: [*]u8) Error!void,
write: *const fn (dev: *BlockDevice, block_offset: u64, block_count: u64, buffer: [*]const u8) Error!void,
