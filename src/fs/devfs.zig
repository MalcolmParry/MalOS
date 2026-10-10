const std = @import("std");
const vfs = @import("vfs.zig");
const BlockDevice = @import("../block/BlockDevice.zig");
const gpa = @import("../heap/gpa.zig").allocator;

pub var superblock: vfs.SuperBlock = .{
    .mount_count = .init(0),
};

pub var root: vfs.DirEntry = .{
    .ref_count = .init(2),
    .node = &root_node,
    .name = .initEmbedded("/"),
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
        .node_destroy = &vfs.nodeDestroyPanic,
        .file_read_dir = &vfs.fileReadDirInCache,
    },
};

var disk_dir: vfs.DirEntry = .{
    .ref_count = .init(0),
    .node = &disk_dir_node,
    .name = .initEmbedded("disk"),
    .parent = &root,
};

var disk_dir_node: vfs.Node = .{
    .kind = .dir,
    .data = .{ .dir = .{ .entries = .empty } },
    .ref_count = .init(1),
    .sb = &superblock,
    .vtable = &.{
        .node_destroy = &vfs.nodeDestroyPanic,
        .file_read_dir = &vfs.fileReadDirInCache,
    },
};

pub fn init() !void {
    try root_node.data.dir.entries.put(gpa, disk_dir.name.get(), &disk_dir);
}

pub fn mount() !*vfs.Mount {
    const m = try gpa.create(vfs.Mount);

    m.* = .{
        .target = null,
        .src = &root,
        .ref_count = .init(0),
    };

    _ = superblock.mount_count.fetchAdd(1, .monotonic);
    root.acquire();
    return m;
}

pub fn registerDisk(name: []const u8, bd: *BlockDevice) !void {
    if (name.len > vfs.max_name_len) return error.NameTooLong;

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
            .node_destroy = &vfs.nodeDestroyPanic,
        },
    };

    entry.* = .{
        .ref_count = .init(0),
        .node = node,
        .parent = &disk_dir,
        .name = undefined,
    };
    try entry.name.init(name);
    errdefer entry.name.deinit();

    disk_dir.node.mutex.lock();
    defer disk_dir.node.mutex.unlock();

    try disk_dir.node.data.dir.entries.put(gpa, entry.name.get(), entry);
    disk_dir.acquire();
}
