const std = @import("std");
const vfs = @import("vfs.zig");
const BlockDevice = @import("../block/BlockDevice.zig");
const gpa = @import("../heap/gpa.zig").allocator;

pub var superblock: vfs.SuperBlock = .{
    .root = &root_node,
};

pub var root: vfs.DirEntry = .{
    .ref_count = .init(1),
    .node = &root_node,
    .name_len = 1,
    .name_buf = @as([1]u8, "/".*) ++ @as([vfs.max_embedded_name_len - 1]u8, @splat(0)),
    .parent = null,
};

pub var root_node: vfs.Node = .{
    .kind = .dir,
    .data = .{ .dir = .{
        .entries = .empty,
    } },
    .ref_count = .init(1),
    .sb = &superblock,
    .vtable = &.{
        .node_free = &vfs.nodeFreePanic,
        .file_read_dir = &vfs.fileReadDirInCache,
    },
};

var disk_dir: vfs.DirEntry = .{
    .ref_count = .init(1),
    .node = &disk_dir_node,
    .name_len = 4,
    .name_buf = @as([4]u8, "disk".*) ++ @as([vfs.max_embedded_name_len - 4]u8, @splat(0)),
    .parent = &root,
};

var disk_dir_node: vfs.Node = .{
    .kind = .dir,
    .data = .{ .dir = .{ .entries = .empty } },
    .ref_count = .init(1),
    .sb = &superblock,
    .vtable = &.{
        .node_free = &vfs.nodeFreePanic,
        .file_read_dir = &vfs.fileReadDirInCache,
    },
};

pub fn init() !void {
    try root_node.data.dir.entries.put(gpa, disk_dir.getName(), &disk_dir);
}

pub fn registerDisk(name: []const u8, bd: *BlockDevice) !void {
    if (name.len > vfs.max_embedded_name_len) return error.NameTooLong;

    const node = try gpa.create(vfs.Node);
    errdefer gpa.destroy(node);
    const entry = try gpa.create(vfs.DirEntry);
    errdefer gpa.destroy(entry);

    node.* = .{
        .kind = .block_device,
        .ref_count = .init(1),
        .data = .{ .block_device = bd },
        .sb = &superblock,
        .vtable = &.{
            .node_free = &vfs.nodeFreePanic,
        },
    };

    entry.* = .{
        .ref_count = .init(1),
        .node = node,
        .parent = &disk_dir,
        .name_len = @intCast(name.len),
        .name_buf = @splat(0),
    };
    @memcpy(entry.name_buf[0..name.len], name);

    disk_dir.node.mutex.lock();
    defer disk_dir.node.mutex.unlock();

    try disk_dir.node.data.dir.entries.put(gpa, entry.getName(), entry);
}
