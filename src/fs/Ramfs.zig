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
    vfs: vfs.Node,

    data: union {
        file: struct {
            data: std.ArrayList(u8),
        },
        dir: struct {
            entries: std.ArrayList(DirEntry),
        },
    },
};

const DirEntry = struct {
    name_buf: [max_name_len]u8,
    name_len: u8,
    node: *Node,

    fn name(entry: *DirEntry) []u8 {
        return entry.name_buf[0..entry.name_len];
    }
};

const File = struct {
    vfs: vfs.File,
    head: usize,
};

const node_ops: vfs.Node.Ops = .{
    .free = &free,
    .lookup = &lookup,
    .create = &create,
    .unlink = &unlink,
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
        .root = &root.vfs,
    };

    root.* = .{
        .vfs = .{
            .kind = .dir,
            .vtable = &node_ops,
            .sb = &fs.sb,
        },
        .data = .{ .dir = .{
            .entries = .empty,
        } },
    };
}

pub fn deinit(fs: *Ramfs) void {
    fs.sb.root.decRef();

    fs.node_pool.deinit(fs.alloc);
    fs.file_pool.deinit(fs.alloc);
}

fn free(node_vfs: *vfs.Node) void {
    std.debug.assert(node_vfs.ref_count == 0);
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const node: *Node = @fieldParentPtr("vfs", node_vfs);

    switch (node_vfs.kind) {
        .file => node.data.file.data.deinit(fs.alloc),
        .dir => {
            for (node.data.dir.entries.items) |entry| {
                entry.node.vfs.decRef();
            }

            node.data.dir.entries.deinit(fs.alloc);
        },
    }

    fs.node_pool.destroy(node);
}

fn lookup(dir_vfs: *vfs.Node, name: []const u8) vfs.Error!*vfs.Node {
    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir: *Node = @fieldParentPtr("vfs", dir_vfs);

    for (dir.data.dir.entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.name(), name)) continue;
        entry.node.vfs.ref_count += 1;
        return &entry.node.vfs;
    }

    return error.NoEntry;
}

fn create(dir_vfs: *vfs.Node, name: []const u8, opts: vfs.CreateOptions) vfs.Error!*vfs.Node {
    if (name.len > max_name_len) return error.NameTooLong;
    if (dir_vfs.kind != .dir) return error.NotADir;

    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);
    const dir: *Node = @fieldParentPtr("vfs", dir_vfs);

    const new = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(new);

    new.* = .{
        .vfs = .{
            .kind = opts.kind,
            .vtable = &node_ops,
            .sb = dir_vfs.sb,
            .ref_count = 2,
        },
        .data = switch (opts.kind) {
            .file => .{ .file = .{
                .data = .empty,
            } },
            .dir => .{ .dir = .{
                .entries = .empty,
            } },
        },
    };

    var entry: DirEntry = .{
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
        .node = new,
    };

    @memcpy(entry.name_buf[0..name.len], name);
    try dir.data.dir.entries.append(fs.alloc, entry);

    return &new.vfs;
}

fn unlink(dir_vfs: *vfs.Node, name: []const u8) vfs.Error!void {
    const dir: *Node = @fieldParentPtr("vfs", dir_vfs);
    if (dir_vfs.kind != .dir) return error.NotADir;

    const index: usize = blk: for (dir.data.dir.entries.items, 0..) |*entry, i| {
        if (!std.mem.eql(u8, entry.name(), name)) continue;
        break :blk i;
    } else return error.NoEntry;

    // TODO: this will cause problems later when iterating dir entries
    const entry = dir.data.dir.entries.swapRemove(index);
    entry.node.vfs.decRef();
    std.log.info("{}", .{entry.node.vfs.ref_count});
}

fn open(node_vfs: *vfs.Node) vfs.Error!*vfs.File {
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    if (node_vfs.kind != .file) return error.NotAFile;

    const file = try fs.file_pool.create(fs.alloc);
    errdefer fs.file_pool.destroy(file);

    file.* = .{
        .vfs = .{
            .node = node_vfs,
            .vtable = &file_ops,
        },
        .head = 0,
    };

    node_vfs.ref_count += 1;
    return &file.vfs;
}

fn close(vfs_file: *vfs.File) void {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    const file: *File = @alignCast(@fieldParentPtr("vfs", vfs_file));
    vfs_file.node.decRef();
    fs.file_pool.destroy(file);
}

fn read(vfs_file: *vfs.File, buffer: []u8) vfs.Error!usize {
    const node: *Node = @fieldParentPtr("vfs", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs", vfs_file));

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
    const node: *Node = @fieldParentPtr("vfs", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs", vfs_file));

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
    const node: *Node = @fieldParentPtr("vfs", vfs_file.node);
    const file: *File = @alignCast(@fieldParentPtr("vfs", vfs_file));

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
        const thing = try create(vfs.root, "thing.txt", .{ .kind = .file });
        thing.decRef();
    }

    {
        const thing_file = try lookup(vfs.root, "thing.txt");
        thing_file.decRef();
        try unlink(vfs.root, "thing.txt");
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
        defer other_file.decRef();

        const thing = try open(other_file);
        defer close(thing);

        try std.testing.expect(try write(thing, test_data1) == test_data1.len);
        try seek(thing, .start, 0);
        try std.testing.expect(try write(thing, test_data2) == test_data2.len);
    }

    {
        const other_file = try lookup(vfs.root, "other.thing");
        defer unlink(vfs.root, "other.thing") catch unreachable;
        defer other_file.decRef();

        try std.testing.expect(other_file.ref_count == 2);
        const thing = try open(other_file);
        defer close(thing);

        var buffer: [test_data2.len]u8 = undefined;
        try std.testing.expect(try read(thing, buffer[0..]) == test_data2.len);
        try std.testing.expect(std.mem.eql(u8, buffer[0..], test_data2));
        try std.testing.expect(read(thing, buffer[0..]) == error.EndOfFile);
    }
}
