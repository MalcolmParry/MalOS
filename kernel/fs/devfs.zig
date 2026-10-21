const std = @import("std");
const vfs = @import("vfs/vfs.zig");
const BlockDevice = @import("../block/BlockDevice.zig");
const gpa = @import("../heap/gpa.zig").allocator;

pub var superblock: vfs.SuperBlock = .{
    .mount_count = .init(1),
    .destroy_ptr = &vfs.sbDestroyPanic,
    .root = &root,
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
        .destroy = &vfs.Node.default_impls.destroyPanic,
        .open = &vfs.Node.Handle.default_impls.OpenDefault(&.{
            .read_dir = &vfs.Node.Handle.default_impls.readDirInCache,
        }),
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
        .destroy = &vfs.Node.default_impls.destroyPanic,
        .open = &vfs.Node.Handle.default_impls.OpenDefault(&.{
            .read_dir = &vfs.Node.Handle.default_impls.readDirInCache,
        }),
    },
};

pub fn init() !void {
    try root_node.data.dir.entries.put(gpa, disk_dir.name.get(), &disk_dir);
}

pub fn mount() !*vfs.Mount {
    return vfs.Mount.create(&root);
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
            .destroy = &vfs.Node.default_impls.destroyPanic,
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

    try disk_dir.node.data.dir.entries.putNoClobber(gpa, entry.name.get(), entry);
    disk_dir.acquire();
}
