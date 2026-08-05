const std = @import("std");
const vfs = @import("vfs.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

const max_name_len = 32;
const max_nodes = 64;

lock: Spinlock,
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

const fs_info: vfs.FileSystem = .{
    .lookup = &lookup,
    .create = &create,
    .destroy = &destroy,
    .open = &open,
    .close = &close,
    .read = &read,
    .write = &write,
    .seek = &seek,
};

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator) !void {
    fs.* = .{
        .lock = .init,
        .alloc = alloc,
        .node_pool = .empty,
        .file_pool = .empty,
        .sb = undefined,
    };

    const root = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(root);

    fs.sb = .{
        .fs = &fs_info,
        .root = &root.vfs_node,
    };

    root.* = .{
        .vfs_node = .{
            .kind = .dir,
            .ref_count = 0,
            .sb = &fs.sb,
            .parent = &root.vfs_node,
            .mount = null,
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

fn lookup(dir_vfs: *vfs.Node, name: []const u8) vfs.Error!*vfs.Node {
    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir: *Node = @fieldParentPtr("vfs_node", dir_vfs);

    var maybe_next = dir.data.dir.first_child;
    while (maybe_next) |next| {
        if (std.mem.eql(u8, name, next.name())) {
            next.vfs_node.ref_count += 1;
            return &next.vfs_node;
        }

        maybe_next = next.next_sibling;
    }

    return error.NoEntry;
}

fn create(dir_vfs: *vfs.Node, name: []const u8, opts: vfs.CreateOptions) vfs.Error!*vfs.Node {
    if (name.len > max_name_len) return error.NameTooLong;

    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir: *Node = @fieldParentPtr("vfs_node", dir_vfs);

    const new = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(new);

    new.* = .{
        .vfs_node = .{
            .kind = opts.kind,
            .ref_count = 1,
            .sb = dir_vfs.sb,
            .parent = dir_vfs,
            .mount = null,
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
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: *Node = @fieldParentPtr("vfs_node", node_vfs);
    std.debug.assert(node_vfs.ref_count != 0);
    if (node_vfs.ref_count != 1) return error.FileBusy;

    // if there is a mount, then there should be another reference
    std.debug.assert(node_vfs.mount == null);

    switch (node_vfs.kind) {
        .file => node.data.file.data.deinit(fs.alloc),
        .dir => {},
    }

    const parent: *Node = @fieldParentPtr("vfs_node", node_vfs.parent);
    if (parent.data.dir.first_child == node) {
        parent.data.dir.first_child = node.next_sibling;
    } else {
        var maybe_next = parent.data.dir.first_child;

        while (maybe_next) |next| {
            if (next.next_sibling == node) {
                next.next_sibling = node.next_sibling;
                break;
            }

            maybe_next = next.next_sibling;
        }
    }

    fs.node_pool.destroy(node);
}

fn open(node_vfs: *vfs.Node) vfs.Error!*vfs.File {
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    if (node_vfs.kind != .file) return error.NotAFile;

    const file = try fs.file_pool.create(fs.alloc);
    errdefer fs.file_pool.destroy(file);

    file.* = .{
        .vfs_file = .{
            .node = node_vfs,
        },
        .head = 0,
    };

    node_vfs.ref_count += 1;
    return &file.vfs_file;
}

fn close(vfs_file: *vfs.File) void {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));
    vfs_file.node.ref_count -= 1;
    fs.file_pool.destroy(file);
}

fn read(vfs_file: *vfs.File, buffer: []u8) vfs.Error!usize {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));

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
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));

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
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: *Node = @fieldParentPtr("vfs_node", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs_file", vfs_file));

    const base_int: isize = switch (base) {
        .start => 0,
        .end => @intCast(node.data.file.data.items.len),
        .head => @intCast(file.head),
    };

    const new_head = @max(0, base_int + offset);
    file.head = @intCast(new_head);
}

test "lookup/destroy" {
    var ramfs: Ramfs = undefined;
    try ramfs.init(std.testing.allocator);
    defer ramfs.deinit();

    vfs.root = ramfs.sb.root;
    vfs.root.ref_count += 1;

    {
        try std.testing.expect(vfs.root.lookup("thing.txt") == error.NoEntry);
        const thing_file = try vfs.root.create("thing.txt", .{ .kind = .file });
        defer thing_file.ref_count -= 1;
    }

    {
        const thing_file = try vfs.root.lookup("thing.txt");
        try thing_file.destroy();
        try std.testing.expect(vfs.root.lookup("thing.txt") == error.NoEntry);
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
        const other_file = try vfs.root.create("other.thing", .{ .kind = .file });
        defer other_file.ref_count -= 1;

        const thing = try other_file.open();
        defer thing.close();

        try std.testing.expect(try thing.write(test_data1) == test_data1.len);
        try thing.seek(.start, 0);
        try std.testing.expect(try thing.write(test_data2) == test_data2.len);
    }

    {
        const other_file = try vfs.root.lookup("other.thing");
        defer other_file.destroy() catch unreachable;

        const thing = try other_file.open();
        defer thing.close();

        var buffer: [test_data2.len]u8 = undefined;
        try std.testing.expect(try thing.read(buffer[0..]) == test_data2.len);
        try std.testing.expect(std.mem.eql(u8, buffer[0..], test_data2));
    }
}
