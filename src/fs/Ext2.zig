const std = @import("std");
const mem = @import("../memory.zig");
const builtin = @import("builtin");
const BlockDevice = @import("../BlockDevice.zig");
const PageAllocator = @import("../heap/PageAllocator.zig");
const Ext2 = @This();

bd: *BlockDevice,
sb_blocks: []u8,
gdt_descs: []align(1) BlockGroupDesc,
scratch_block: []u8,

pub fn init(bd: *BlockDevice) !Ext2 {
    const page_alloc = PageAllocator.global.allocator();
    const bd_block_size = bd.blockSize();
    const block_size_mask = bd_block_size - 1;

    var fs: Ext2 = .{
        .bd = bd,
        .sb_blocks = undefined,
        .gdt_descs = undefined,
        .scratch_block = undefined,
    };

    const sb_offset = 1024 & block_size_mask;
    const sb_block_index: u64 = @as(u64, 1024) >> bd.log2_block_size;
    const sb_block_count: u64 = (1024 + sb_offset + bd_block_size - 1) >> bd.log2_block_size;

    fs.sb_blocks = try page_alloc.alloc(u8, sb_block_count << bd.log2_block_size);
    errdefer page_alloc.free(fs.sb_blocks);

    try bd.read(bd, sb_block_index, sb_block_count, fs.sb_blocks.ptr);

    const sb_info = fs.sbInfo();
    if (sb_info.signature != 0xef53) return error.BadSuperBlock;
    if (sb_info.major_version != 1) return error.UnsupportedVersion;

    const fs_block_size = @as(u32, 1024) << @intCast(sb_info.log2_block_size_minus_10);
    if (fs_block_size < bd_block_size) return error.UnsupportedBlockSize;
    if (fs_block_size > mem.page_size) return error.UnsupportedBlockSize;

    std.log.info("{any}", .{sb_info});

    const sb_extra_info = fs.sbExtraInfo();
    if (sb_extra_info.incompat_features != 2) return error.UnsupportedFeature;
    if (sb_extra_info.inode_size < @sizeOf(Inode)) return error.UnsupportedFeature;

    fs.scratch_block = try page_alloc.alloc(u8, fs_block_size);
    errdefer page_alloc.free(fs.scratch_block);

    const block_group_count = (sb_info.block_count + sb_info.blocks_per_group - 1) / sb_info.blocks_per_group;
    const gdt_byte_count = block_group_count * @sizeOf(BlockGroupDesc);
    const gdt_blocks = try page_alloc.alloc(u8, std.mem.alignForward(usize, gdt_byte_count, fs_block_size));
    errdefer page_alloc.free(gdt_blocks);

    try fs.readBlocks(sb_info.first_data_block + 1, gdt_blocks);
    fs.gdt_descs = @as([*]align(1) BlockGroupDesc, @ptrCast(gdt_blocks.ptr))[0..block_group_count];

    for (fs.gdt_descs) |*desc| {
        std.log.info("{any}", .{desc});
    }

    const root_inode = try fs.getInode(2);
    std.log.info("{any}", .{root_inode});

    const root_data = fs.scratch_block;
    try fs.readBlocks(root_inode.direct_pointers[0], root_data);

    var dentry: *align(1) Dentry = @ptrCast(root_data.ptr);
    var remaining_len = fs_block_size;
    while (true) {
        if (dentry.size == 0 or dentry.size > remaining_len)
            return error.Corrupt;

        const name = @as([*]u8, @ptrCast(&dentry.name))[0..dentry.name_len_lower];
        std.log.info("'{s}'", .{name});
        std.log.info("{any}", .{dentry});

        remaining_len -= dentry.size;
        if (remaining_len == 0) break;
        dentry = @ptrFromInt(@intFromPtr(dentry) + dentry.size);
    }

    return fs;
}

pub fn deinit(fs: *Ext2) void {
    const page_alloc = PageAllocator.global.allocator();
    const fs_block_size = fs.sbInfo().blockSize();

    const gdt_byte_ptr: [*]u8 = @ptrCast(fs.gdt_descs.ptr);
    const gdt_byte_count = fs.gdt_descs.len * @sizeOf(BlockGroupDesc);
    const gdt_blocks = gdt_byte_ptr[0..std.mem.alignForward(usize, gdt_byte_count, fs_block_size)];
    page_alloc.free(gdt_blocks);

    page_alloc.free(fs.scratch_block);
    page_alloc.free(fs.sb_blocks);
}

fn getInode(fs: *Ext2, inode: u32) !Inode {
    const sb_info = fs.sbInfo();
    const sb_extra_info = fs.sbExtraInfo();

    const group = (inode - 1) / sb_info.inodes_per_group;
    const index = (inode - 1) % sb_info.inodes_per_group;
    const block_offset = (index * sb_extra_info.inode_size) / sb_info.blockSize();
    const block_i = block_offset + fs.gdt_descs[group].inode_table_first_block_index;
    const offset_from_block = (index * sb_extra_info.inode_size) % sb_info.blockSize();

    const block = fs.scratch_block;
    try fs.readBlocks(block_i, block);

    const inode_ptr: *align(1) Inode = @ptrCast(block.ptr + offset_from_block);
    return inode_ptr.*;
}

fn readBlocks(fs: *Ext2, start: u32, buffer: []u8) !void {
    const bd_block_size = fs.bd.blockSize();
    const fs_block_size = fs.sbInfo().blockSize();
    const bd_blocks_per_fs_block = fs_block_size / bd_block_size;

    const count = buffer.len / fs_block_size;
    std.debug.assert(buffer.len % fs_block_size == 0);

    try fs.bd.read(fs.bd, bd_blocks_per_fs_block * start, bd_blocks_per_fs_block * count, buffer.ptr);
}

inline fn sbData(fs: Ext2) *[1024]u8 {
    const block_size_mask = fs.bd.blockSize() - 1;
    const sb_offset = 1024 & block_size_mask;
    return fs.sb_blocks[sb_offset..][0..1024];
}

inline fn sbInfo(fs: Ext2) *align(1) SbInfo {
    return @ptrCast(fs.sbData());
}

inline fn sbExtraInfo(fs: Ext2) *align(1) SbExtraInfo {
    return @ptrCast(&fs.sbData()[84]);
}

const SbInfo = extern struct {
    inode_count: u32,
    block_count: u32,
    reserved_block_count: u32,
    free_block_count: u32,
    free_inode_count: u32,
    first_data_block: u32,
    log2_block_size_minus_10: u32,
    log2_fragment_size_minus_10: u32,
    blocks_per_group: u32,
    fragments_per_group: u32,
    inodes_per_group: u32,
    last_mount_time: u32,
    last_written_time: u32,
    mount_count: u16,
    max_mount_count: u16,
    signature: u16,
    state: State,
    err_handle_method: ErrHandleMethod,
    minor_version: u16,
    last_check_time: u32,
    check_interval: u32,
    creator_os: u32,
    major_version: u32,
    reserved_blocks_uid: u16,
    reserved_blocks_gid: u16,

    const State = enum(u16) {
        clean = 1,
        err,
        _,
    };

    const ErrHandleMethod = enum(u16) {
        ignore = 1,
        remount_ro,
        kpanic,
        _,
    };

    comptime {
        std.debug.assert(@sizeOf(SbInfo) == 0x54);
        std.debug.assert(@offsetOf(SbInfo, "signature") == 0x38);
    }

    fn blockSize(info: *align(1) SbInfo) u32 {
        return @as(u32, 1024) << @intCast(info.log2_block_size_minus_10);
    }
};

const SbExtraInfo = extern struct {
    first_inode: u32,
    inode_size: u16,
    sb_group: u16,
    compat_features: u32,
    incompat_features: u32,
    ro_compat_features: u32,
    fs_id: [16]u8,
    volume_name: [16]u8,
    last_mount_path: [64]u8,
    compression_alhorithms: u32,
    file_prealloc_blocks: u8,
    dir_prealloc_blocks: u8,
    unused1: u16,
    journal_id: [16]u8,
    journal_inode: u32,
    journal_dev: u32,
    first_orphaned_inode: u32,
};

const BlockGroupDesc = extern struct {
    block_usage_block_index: u32,
    inode_usage_block_index: u32,
    inode_table_first_block_index: u32,
    free_blocks_in_group: u16,
    free_inodes_in_group: u16,
    dir_count_in_group: u16,
    unused: [14]u8,

    comptime {
        std.debug.assert(@sizeOf(BlockGroupDesc) == 32);
    }
};

const Inode = extern struct {
    t_perm: TypePerm,
    uid: u16,
    size_lower: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    link_count: u16,
    sector_count: u32,
    flags: u32,
    os_val1: u32,
    direct_pointers: [12]u32,
    singly_indirect_pointer: u32,
    doubly_indirect_pointer: u32,
    triply_indirect_pointer: u32,
    gen: u32,
    extended_attrib_block: u32,
    size_upper: u32,
    fragment_block: u32,
    os_val2: [12]u8,

    const TypePerm = packed struct(u16) {
        other: Rwe,
        group: Rwe,
        user: Rwe,
        sticky: bool,
        set_group_id: bool,
        set_user_id: bool,
        t: Type,
    };

    const Type = enum(u4) {
        fifo = 0x1,
        char_device = 0x2,
        dir = 0x4,
        block_device = 0x6,
        regular_file = 0x8,
        sym_link = 0xa,
        socket = 0xc,
        _,
    };

    const Rwe = packed struct(u3) {
        execute: bool,
        write: bool,
        read: bool,
    };
};

const Dentry = extern struct {
    inode: u32,
    size: u16,
    name_len_lower: u8,
    t: Type,
    name: u8,

    const Type = enum(u8) {
        unknown,
        regular_file,
        dir,
        char_device,
        block_device,
        fifo,
        socket,
        sym_link,
        _,
    };
};

comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}
