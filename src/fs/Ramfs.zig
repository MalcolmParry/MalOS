const std = @import("std");
const vfs = @import("vfs.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

const max_name_len = 32;
const max_nodes = 64;

alloc: std.mem.Allocator,
sb: vfs.SuperBlock,
node_pool: std.heap.MemoryPool(Node),
file_pool: std.heap.MemoryPool(File),

const Node = struct {
    vfs_node: vfs.Node,
    next_sibling: ?*Node,
    name_buf: [max_name_len]u8,
    name_len: u8,

    data: union {
        file: struct {
            data: std.ArrayList(u8),
        },
        dir: struct {
            first_child: ?*Node,
        },
    },

    fn name(node: *const Node) []const u8 {
        return node.name_buf[0..node.name_len];
    }
};

const File = struct {
    vfs_file: vfs.File,
    head: usize,
};

const node_ops: vfs.Node.Ops = .{
    .free = &free,
    .lookup = &lookup,
    .create = &create,
    .destroy = &destroy,
    .open = &open,
};

const file_ops: vfs.File.Ops = .{
    .close = &close,
    .read = &read,
    .write = &write,
    .seek = &seek,
};

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator) !void {
    fs.* = .{
        .alloc = alloc,
        .node_pool = .empty,
        .file_pool = .empty,
        .sb = undefined,
    };

    const root = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(root);

    fs.sb = .{
        .lock = .init,
        .root = &root.vfs_node,
    };

    root.* = .{
        .vfs_node = .{
            .kind = .dir,
            .vtable = &node_ops,
            .sb = &fs.sb,
            .parent = &root.vfs_node,
        },
        .next_sibling = null,
        .name_buf = @as([1]u8, "/".*) ++ @as([max_name_len - 1]u8, @splat(0)),
        .name_len = 1,
        .data = .{ .dir = .{
            .first_child = null,
        } },
    };
}

pub fn deinit(fs: *Ramfs) void {
    fs.node_pool.deinit(fs.alloc);
    fs.file_pool.deinit(fs.alloc);
}

fn free(node_vfs: *vfs.Node) void {
    std.debug.assert(node_vfs.ref_count == 0 and !node_vfs.alive);
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const node: *Node = @fieldParentPtr("vfs_node", node_vfs);
    fs.node_pool.destroy(node);
}

fn lookup(dir_vfs: *vfs.Node, name: []const u8) vfs.Error!*vfs.Node {
    if (!dir_vfs.alive) return error.NodeDead;
    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir: *Node = @fieldParentPtr("vfs_node", dir_vfs);

    var maybe_next = dir.data.dir.first_child;
    while (maybe_next) |next| : (maybe_next = next.next_sibling) {
        if (!next.vfs_node.alive) continue;

        if (std.mem.eql(u8, name, next.name())) {
            return &next.vfs_node;
        }
    }

    return error.NoEntry;
}

fn create(dir_vfs: *vfs.Node, name: []const u8, opts: vfs.CreateOptions) vfs.Error!*vfs.Node {
    if (!dir_vfs.alive) return error.NodeDead;
    if (name.len > max_name_len) return error.NameTooLong;

    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);

    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir: *Node = @fieldParentPtr("vfs_node", dir_vfs);

    const new = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(new);

    new.* = .{
        .vfs_node = .{
            .kind = opts.kind,
            .vtable = &node_ops,
            .sb = dir_vfs.sb,
            .parent = dir_vfs,
        },
        .next_sibling = dir.data.dir.first_child,
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
        .data = switch (opts.kind) {
            .file => .{ .file = .{
                .data = .empty,
            } },
            .dir => .{ .dir = .{
                .first_child = null,
            } },
        },
    };

    @memcpy(new.name_buf[0..name.len], name);
    dir.data.dir.first_child = new;

    return &new.vfs_node;
}

fn destroy(node_vfs: *vfs.Node) vfs.Error!void {
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const node: *Node = @fieldParentPtr("vfs_node", node_vfs);
    if (!node_vfs.alive) return error.NodeDead;
    if (node_vfs.mount != null) return error.NotEmpty;

    switch (node_vfs.kind) {
        .file => node.data.file.data.deinit(fs.alloc),
        .dir => if (node.data.dir.first_child != null) return error.NotEmpty,
    }

    const parent: *Node = @fieldParentPtr("vfs_node", node_vfs.parent);
    if (parent.data.dir.first_child == node) {
        parent.data.dir.first_child = node.next_sibling;
    } else {
        var maybe_next = parent.data.dir.first_child;

        while (maybe_next) |next| : (maybe_next = next.next_sibling) {
            if (next.next_sibling == node) {
                next.next_sibling = node.next_sibling;
                break;
            }
        }
    }

    node.vfs_node.alive = false;
    if (node.vfs_node.ref_count == 0) {
        fs.node_pool.destroy(node);
    }
}

fn open(node_vfs: *vfs.Node) vfs.Error!*vfs.File {
    if (!node_vfs.alive) return error.NodeDead;
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    if (node_vfs.kind != .file) return error.NotAFile;

    const file = try fs.file_pool.create(fs.alloc);
    errdefer fs.file_pool.destroy(file);

    file.* = .{
        .vfs_file = .{
            .node = node_vfs,
            .vtable = &file_ops,
        },
        .head = 0,
    };

    node_vfs.ref_count += 1;
    return &file.vfs_file;
}

fn close(vfs_file: *vfs.File) void {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));
    const vfs_node = vfs_file.node;

    vfs_node.ref_count -= 1;
    if (!vfs_node.alive and vfs_node.ref_count == 0)
        vfs_node.vtable.free(vfs_node);

    fs.file_pool.destroy(file);
}

fn read(vfs_file: *vfs.File, buffer: []u8) vfs.Error!usize {
    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));
    if (!node.vfs_node.alive) return error.NodeDead;

    const data = &node.data.file.data;
    if (file.head >= data.items.len) return error.EndOfFile;
    const remaining = data.items[file.head..];

    const bytes_to_read = @min(remaining.len, buffer.len);
    @memcpy(buffer[0..bytes_to_read], remaining[0..bytes_to_read]);
    file.head += bytes_to_read;
    return bytes_to_read;
}

fn write(vfs_file: *vfs.File, data: []const u8) vfs.Error!usize {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));
    if (!node.vfs_node.alive) return error.NodeDead;

    const file_data = &node.data.file.data;
    const old_size = file_data.items.len;
    const new_head = file.head + data.len;

    if (new_head > old_size) {
        try file_data.resize(fs.alloc, new_head);
    }

    @memcpy(file_data.items[file.head..], data);
    file.head = new_head;
    return data.len;
}

fn seek(vfs_file: *vfs.File, base: vfs.SeekBase, offset: isize) vfs.Error!void {
    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));
    if (!node.vfs_node.alive) return error.NodeDead;

    const base_uint: usize = switch (base) {
        .start => 0,
        .end => node.data.file.data.items.len,
        .head => file.head,
    };

    const base_int: isize = @min(base_uint, std.math.maxInt(isize));
    file.head = @max(0, base_int +| offset);
}

test "lookup/destroy" {
    var ramfs: Ramfs = undefined;
    try ramfs.init(std.testing.allocator);
    defer ramfs.deinit();

    vfs.root = ramfs.sb.root;
    vfs.root.ref_count += 1;

    {
        try std.testing.expect(lookup(vfs.root, "thing.txt") == error.NoEntry);
        _ = try create(vfs.root, "thing.txt", .{ .kind = .file });
    }

    {
        const thing_file = try lookup(vfs.root, "thing.txt");
        try destroy(thing_file);
        try std.testing.expect(lookup(vfs.root, "thing.txt") == error.NoEntry);
    }
}

test "read/write" {
    var ramfs: Ramfs = undefined;
    try ramfs.init(std.testing.allocator);
    defer ramfs.deinit();

    vfs.root = ramfs.sb.root;
    vfs.root.ref_count += 1;

    const test_data1 = "very important stuff";
    const test_data2 = "extra important info";

    {
        const other_file = try create(vfs.root, "other.thing", .{ .kind = .file });
        const thing = try open(other_file);
        defer close(thing);

        try std.testing.expect(try write(thing, test_data1) == test_data1.len);
        try seek(thing, .start, 0);
        try std.testing.expect(try write(thing, test_data2) == test_data2.len);
    }

    {
        const other_file = try lookup(vfs.root, "other.thing");
        defer destroy(other_file) catch unreachable;

        const thing = try open(other_file);
        defer close(thing);

        var buffer: [test_data2.len]u8 = undefined;
        try std.testing.expect(try read(thing, buffer[0..]) == test_data2.len);
        try std.testing.expect(std.mem.eql(u8, buffer[0..], test_data2));
        try std.testing.expect(read(thing, buffer[0..]) == error.EndOfFile);
    }
}
