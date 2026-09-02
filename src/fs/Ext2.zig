const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const builtin = @import("builtin");
const vfs = @import("vfs.zig");
const BlockDevice = @import("../BlockDevice.zig");
const Ext2 = @This();

alloc: std.mem.Allocator,
bd: *BlockDevice,
sb_blocks: []u8,
gdt_descs: []align(1) BlockGroupDesc,
scratch_block: []u8,

sb: vfs.SuperBlock,
node_pool: std.heap.MemoryPool(FsNode),
dentry_pool: std.heap.MemoryPool(FsDirEntry),
file_pool: std.heap.MemoryPool(vfs.File),

pub fn init(fs: *Ext2, alloc: std.mem.Allocator, bd: *BlockDevice) !*vfs.DirEntry {
    const bd_block_size = bd.blockSize();
    const block_size_mask = bd_block_size - 1;

    fs.* = .{
        .alloc = alloc,
        .bd = bd,
        .sb_blocks = undefined,
        .gdt_descs = undefined,
        .scratch_block = undefined,

        .sb = undefined,
        .node_pool = .empty,
        .dentry_pool = .empty,
        .file_pool = .empty,
    };
    errdefer fs.node_pool.deinit(alloc);
    errdefer fs.dentry_pool.deinit(alloc);
    errdefer fs.file_pool.deinit(alloc);

    const sb_offset = 1024 & block_size_mask;
    const sb_block_index: u64 = @as(u64, 1024) >> bd.log2_block_size;
    const sb_block_count: u64 = (1024 + sb_offset + bd_block_size - 1) >> bd.log2_block_size;

    fs.sb_blocks = try alloc.alloc(u8, sb_block_count << bd.log2_block_size);
    errdefer alloc.free(fs.sb_blocks);

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

    std.log.info("{any}", .{sb_extra_info});

    fs.scratch_block = try alloc.alloc(u8, fs_block_size);
    errdefer alloc.free(fs.scratch_block);

    const block_group_count = (sb_info.block_count + sb_info.blocks_per_group - 1) / sb_info.blocks_per_group;
    const gdt_byte_count = block_group_count * @sizeOf(BlockGroupDesc);
    const gdt_blocks = try alloc.alloc(u8, std.mem.alignForward(usize, gdt_byte_count, fs_block_size));
    errdefer alloc.free(gdt_blocks);

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

        const name = @as([*]u8, @ptrCast(&dentry.name))[0..dentry.name_len];
        std.log.info("'{s}'", .{name});
        std.log.info("{any}", .{dentry});

        remaining_len -= dentry.size;
        if (remaining_len == 0) break;
        dentry = @ptrFromInt(@intFromPtr(dentry) + dentry.size);
    }

    const root = try fs.node_pool.create(alloc);
    root.* = .{
        .vfs = .{
            .kind = .dir,
            .vtable = &node_vtable,
            .sb = &fs.sb,
            .ref_count = .init(1),
            .data = .{ .dir = .{
                .first_child = null,
            } },
        },
        .inode = 2,
    };

    const root_dentry = try fs.dentry_pool.create(alloc);
    root_dentry.* = .{
        .vfs = .{
            .parent = null,
            .node = &root.vfs,
            .ref_count = .init(1),
            .name_buf = @as([1]u8, "/".*) ++ @as([vfs.max_embedded_name_len - 1]u8, @splat(0)),
            .name_len = 1,
            .next_sibling = null,
        },
        .block_index = std.math.maxInt(u32),
        .byte_offset = std.math.maxInt(u32),
    };

    fs.sb = .{
        .root = &root.vfs,
    };

    return &root_dentry.vfs;
}

pub fn deinit(fs: *Ext2) void {
    const alloc = fs.alloc;
    const fs_block_size = fs.sbInfo().blockSize();

    const gdt_byte_ptr: [*]u8 = @ptrCast(fs.gdt_descs.ptr);
    const gdt_byte_count = fs.gdt_descs.len * @sizeOf(BlockGroupDesc);
    const gdt_blocks = gdt_byte_ptr[0..std.mem.alignForward(usize, gdt_byte_count, fs_block_size)];
    alloc.free(gdt_blocks);

    alloc.free(fs.scratch_block);
    alloc.free(fs.sb_blocks);

    fs.node_pool.deinit(alloc);
    fs.dentry_pool.deinit(alloc);
    fs.file_pool.deinit(alloc);
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

fn readInodeBlocks(fs: *Ext2, inode: *align(1) const Inode, start: u32, buffer: []u8) !void {
    const block_size = fs.sbInfo().blockSize();
    const block_count = buffer.len / block_size;
    std.debug.assert(buffer.len % block_size == 0);
    if (block_count == 0) return;

    var i: u32 = 0;
    while (i < block_count) {
        const current = i + start;

        if (current < 12) {
            const block = inode.direct_pointers[current];
            std.debug.assert(block != 0);
            try fs.readBlocks(block, buffer[i * block_size ..][0..block_size]);
            i += 1;
            continue;
        }

        @panic("not implemented");
    }
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

fn nodeFree(vfs_node: *vfs.Node) void {
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_node.sb);
    const node: *FsNode = @fieldParentPtr("vfs", vfs_node);

    fs.node_pool.destroy(node);
}

fn dirEntryFree(vfs_dentry: *vfs.DirEntry) void {
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_dentry.node.sb);
    const dentry: *FsDirEntry = @fieldParentPtr("vfs", vfs_dentry);

    fs.dentry_pool.destroy(dentry);
}

fn fileOpen(vfs_node: *vfs.Node) vfs.Error!*vfs.File {
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_node.sb);

    if (vfs_node.kind != .file) return error.NotAFile;

    const file = try fs.file_pool.create(fs.alloc);
    errdefer fs.file_pool.destroy(file);

    file.* = .{
        .node = vfs_node,
        .head = 0,
    };

    vfs_node.incRef();
    return file;
}

fn fileClose(file: *vfs.File) void {
    const vfs_node = file.node;
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_node.sb);

    fs.file_pool.destroy(file);
    vfs_node.decRef();
}

fn nodeReadPage(vfs_node: *vfs.Node, page_offset: u32, phys_page: pmm.Index) vfs.Error!void {
    const node: *FsNode = @fieldParentPtr("vfs", vfs_node);
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_node.sb);
    const block_size = fs.sbInfo().blockSize();
    const blocks_in_file = (vfs_node.data.file.size + block_size - 1) / block_size;
    const blocks_per_page = mem.page_size / block_size;
    const block_offset = page_offset * blocks_per_page;
    const page = phys_page.toDirectMap();

    std.debug.assert(vfs_node.kind == .file);
    std.debug.assert(block_offset < blocks_in_file);

    const inode = fs.getInode(node.inode) catch return error.Io;
    const end_block = @min(block_offset + blocks_per_page, blocks_in_file);
    const block_count = end_block - block_offset;

    fs.readInodeBlocks(&inode, block_offset, page.bytes[0 .. block_count * block_size]) catch return error.Io;
    @memset(page.bytes[block_count * block_size ..], 0);
}

fn nodeLookup(vfs_dentry: *vfs.DirEntry, name: []const u8) vfs.Error!*vfs.DirEntry {
    const fs: *Ext2 = @fieldParentPtr("sb", vfs_dentry.node.sb);
    const node: *FsNode = @fieldParentPtr("vfs", vfs_dentry.node);
    const fs_block_size = fs.sbInfo().blockSize();

    const inode = fs.getInode(node.inode) catch return error.Io;
    const block_count = (inode.size() + fs_block_size - 1) / fs_block_size;

    const block = try fs.alloc.alloc(u8, fs_block_size);
    defer fs.alloc.free(block);

    for (0..block_count) |block_i_usize| {
        const block_i: u32 = @intCast(block_i_usize);
        fs.readInodeBlocks(&inode, block_i, block) catch return error.Io;

        var dentry: *align(1) Dentry = @ptrCast(block.ptr);
        var remaining_len = fs.sbInfo().blockSize();
        while (true) : ({
            remaining_len -= dentry.size;
            if (remaining_len == 0) break;
            dentry = @ptrFromInt(@intFromPtr(dentry) + dentry.size);
        }) {
            if (dentry.size < 8 or dentry.size > remaining_len or dentry.size % 4 != 0 or dentry.name_len > dentry.size - 8)
                return error.Corrupt;

            if (dentry.inode == 0) continue;

            const found_name = @as([*]u8, @ptrCast(&dentry.name))[0..dentry.name_len];
            if (!std.mem.eql(u8, name, found_name)) continue;
            if (found_name.len > vfs.max_embedded_name_len) return error.NameTooLong;

            const new_node = try fs.node_pool.create(fs.alloc);
            errdefer fs.node_pool.destroy(new_node);

            const new_dentry = try fs.dentry_pool.create(fs.alloc);
            errdefer fs.dentry_pool.destroy(new_dentry);

            const child_inode = fs.getInode(dentry.inode) catch return error.Io;

            // TODO: this will break with hardlinks
            new_node.* = .{
                .vfs = .{
                    .kind = switch (child_inode.t_perm.t) {
                        .regular_file => .file,
                        .dir => .dir,
                        else => return error.NotSupported,
                    },
                    .vtable = &node_vtable,
                    .sb = &fs.sb,
                    .ref_count = .init(1),
                    .data = switch (child_inode.t_perm.t) {
                        .regular_file => .{ .file = .{
                            .size = child_inode.size(),
                            .cache = .empty,
                        } },
                        .dir => .{ .dir = .{
                            .first_child = null,
                        } },
                        else => return error.NotSupported,
                    },
                },
                .inode = dentry.inode,
            };

            new_dentry.* = .{
                .vfs = .{
                    .node = &new_node.vfs,
                    .name_len = @intCast(found_name.len),
                    .name_buf = @splat(0),
                    .parent = vfs_dentry,
                    .next_sibling = vfs_dentry.node.data.dir.first_child,
                    .ref_count = .init(2),
                },
                .block_index = block_i,
                .byte_offset = @intCast(@intFromPtr(dentry) - @intFromPtr(block.ptr)),
            };

            @memcpy(new_dentry.vfs.name_buf[0..found_name.len], found_name);
            vfs_dentry.node.data.dir.first_child = &new_dentry.vfs;
            return &new_dentry.vfs;
        }
    }

    return error.NoEntry;
}

const node_vtable: vfs.Node.VTable = .{
    .node_free = &nodeFree,
    .dir_entry_free = &dirEntryFree,
    .node_lookup = &nodeLookup,
    .file_open = &fileOpen,
    .file_close = &fileClose,
    .node_read_page = &nodeReadPage,
};

const FsNode = struct {
    vfs: vfs.Node,
    inode: u32,
};

const FsDirEntry = struct {
    vfs: vfs.DirEntry,
    block_index: u32,
    byte_offset: u32,
};

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

    fn size(inode: Inode) u64 {
        return (@as(u64, inode.size_upper) << 32) | inode.size_lower;
    }
};

const Dentry = extern struct {
    inode: u32,
    size: u16,
    name_len: u8,
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
