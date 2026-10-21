const std = @import("std");
const BlockDevice = @import("BlockDevice.zig");
const Partition = @This();

bd: BlockDevice,
parent: *BlockDevice,
first_block: u64,

pub fn init(parent: *BlockDevice, first_block: u64, block_count: u64) Partition {
    std.debug.assert(first_block + block_count <= parent.block_count);

    return .{
        .bd = .{
            .log2_block_size = parent.log2_block_size,
            .block_count = block_count,
            .read_ptr = &read,
            .write_ptr = &write,
        },
        .parent = parent,
        .first_block = first_block,
    };
}

fn read(dev: *BlockDevice, first_block: u64, block_count: u64, buffer: [*]u8) BlockDevice.Error!void {
    const part: *Partition = @fieldParentPtr("bd", dev);
    std.debug.assert(block_count != 0);
    std.debug.assert(first_block + block_count <= dev.block_count);
    return part.parent.read_ptr(part.parent, first_block + part.first_block, block_count, buffer);
}

fn write(dev: *BlockDevice, first_block: u64, block_count: u64, buffer: [*]const u8) BlockDevice.Error!void {
    const part: *Partition = @fieldParentPtr("bd", dev);
    std.debug.assert(block_count != 0);
    std.debug.assert(first_block + block_count <= dev.block_count);
    return part.parent.write_ptr(part.parent, first_block + part.first_block, block_count, buffer);
}
