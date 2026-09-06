const std = @import("std");
const vfs = @import("vfs.zig");
const direct_map = @import("../heap/direct_map.zig");
const BlockDevice = @import("../BlockDevice.zig");

var file_pool: std.heap.MemoryPool(vfs.File) = .empty;
var disk_pool: std.heap.MemoryPool(Disk) = .empty;

pub var superblock: vfs.SuperBlock = .{
    .root = &root_node,
};

pub var root: vfs.DirEntry = .{
    .ref_count = .init(1),
    .node = &root_node,
    .name_len = 1,
    .name_buf = @as([1]u8, "/".*) ++ @as([vfs.max_embedded_name_len - 1]u8, @splat(0)),
    .next_sibling = null,
    .parent = null,
};

pub var root_node: vfs.Node = .{
    .kind = .dir,
    .data = .{ .dir = .{
        .first_child = &category_dentries[0],
    } },
    .ref_count = .init(1),
    .sb = &superblock,
    .vtable = &.{
        .node_free = &vfs.unimplementedNodeFree,
        .dir_entry_free = &vfs.unimplementedDentryFree,
        .file_open = &fileOpen,
        .file_close = &fileClose,
        .file_read_dir = &rootReadDir,
    },
};

fn rootReadDir(file: *vfs.File, record: *vfs.DirRecord) vfs.Error!bool {
    if (file.head >= Category.count) return false;

    const category: Category = @enumFromInt(file.head);
    const name: []const u8 = @tagName(category);

    record.* = .{
        .kind = .dir,
        .name_len = @intCast(name.len),
        .name_buf = @splat(0),
    };

    @memcpy(record.name_buf[0..name.len], name);
    file.head += 1;
    return true;
}

fn fileOpen(node: *vfs.Node) vfs.Error!*vfs.File {
    const file = try file_pool.create(direct_map.page_alloc);
    file.* = .{
        .node = node,
        .head = 0,
    };

    node.incRef();
    return file;
}

fn fileClose(file: *vfs.File) void {
    file.node.decRef();
    file_pool.destroy(file);
}

const Category = enum {
    disk,

    const count = std.enums.values(Category).len;
};

var category_dentries = blk: {
    var result: [Category.count]vfs.DirEntry = undefined;

    for (&result, 0..) |*dentry, i| {
        const category: Category = @enumFromInt(i);
        const name: []const u8 = @tagName(category);

        dentry.* = .{
            .ref_count = .init(1),
            .node = &category_nodes[i],
            .name_len = @intCast(name.len),
            .name_buf = (name ++ @as([vfs.max_embedded_name_len - name.len]u8, @splat(0))).*,
            .parent = &root,
            .next_sibling = if (i == Category.count - 1) null else &category_dentries[i + 1],
        };
    }

    break :blk result;
};

var category_nodes = blk: {
    var result: [Category.count]vfs.Node = undefined;

    for (&result, std.enums.values(Category)) |*node, category| {
        node.* = .{
            .ref_count = .init(1),
            .sb = &superblock,
            .data = .{ .dir = .{
                .first_child = null,
            } },
            .kind = .dir,
            .vtable = &.{
                .node_free = &vfs.unimplementedNodeFree,
                .dir_entry_free = &vfs.unimplementedDentryFree,
                .file_open = &fileOpen,
                .file_close = &fileClose,
                .file_read_dir = switch (category) {
                    .disk => &diskReadDir,
                },
            },
        };
    }

    break :blk result;
};

const Disk = struct {
    dentry: vfs.DirEntry,
    node: vfs.Node,
};

fn diskReadDir(file: *vfs.File, record: *vfs.DirRecord) vfs.Error!bool {
    const disk: *Disk = switch (file.head) {
        0 => if (file.node.data.dir.first_child) |child|
            @fieldParentPtr("dentry", child)
        else
            return false,
        1 => return false,
        else => @ptrFromInt(file.head),
    };

    record.* = .{
        .kind = .block_device,
        .name_len = disk.dentry.name_len,
        .name_buf = undefined,
    };
    @memcpy(&record.name_buf, &disk.dentry.name_buf);

    if (disk.dentry.next_sibling) |next_dentry| {
        const next_disk: *Disk = @fieldParentPtr("dentry", next_dentry);
        file.head = @intFromPtr(next_disk);
    } else {
        file.head = 1;
    }

    return true;
}

pub fn registerDisk(name: []const u8, bd: *BlockDevice) !void {
    if (name.len > vfs.max_embedded_name_len) return error.NameTooLong;

    const disk = try disk_pool.create(direct_map.page_alloc);
    errdefer disk_pool.destroy(disk);

    const parent = &category_dentries[@intFromEnum(Category.disk)];
    disk.* = .{
        .dentry = .{
            .ref_count = .init(1),
            .node = &disk.node,
            .name_len = @intCast(name.len),
            .name_buf = @splat(0),
            .parent = parent,
            .next_sibling = parent.node.data.dir.first_child,
        },
        .node = .{
            .ref_count = .init(1),
            .kind = .block_device,
            .data = .{ .block_device = bd },
            .sb = &superblock,
            .vtable = &.{
                .node_free = &vfs.unimplementedNodeFree,
                .dir_entry_free = &vfs.unimplementedDentryFree,
            },
        },
    };

    @memcpy(disk.dentry.name_buf[0..name.len], name);
    parent.node.data.dir.first_child = &disk.dentry;
}
