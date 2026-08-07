const std = @import("std");
const vfs = @import("vfs.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

const max_nodes = 64;

lock: Spinlock,
alloc: std.mem.Allocator,
sb: vfs.SuperBlock,
node_pool: std.heap.MemoryPool(Node),
file_pool: std.heap.MemoryPool(File),

const Node = struct {
    vfs: vfs.Node,

    data: union {
        none: void,
        file: struct {
            data: std.ArrayList(u8),
        },
    },
};

const File = struct {
    vfs: vfs.File,
    head: usize,
};

const node_ops: vfs.Node.Ops = .{
    .free = &free,
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

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator) !*vfs.Node {
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
        .root = &root.vfs,
    };

    root.* = .{
        .vfs = .{
            .kind = .dir,
            .vtable = &node_ops,
            .sb = &fs.sb,
            // 1 ref is owned by the superblock
            // the other is owned by the caller
            .ref_count = .init(2),
            .data = .{ .dir = .{
                .entry_cache = .empty,
            } },
        },
        .data = .{ .none = {} },
    };

    return &root.vfs;
}

pub fn deinit(fs: *Ramfs) void {
    fs.sb.root.decRef();

    fs.node_pool.deinit(fs.alloc);
    fs.file_pool.deinit(fs.alloc);
}

fn free(node_vfs: *vfs.Node) void {
    std.debug.assert(node_vfs.ref_count.load(.unordered) == 0);
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const node: *Node = @fieldParentPtr("vfs", node_vfs);

    switch (node_vfs.kind) {
        .file => node.data.file.data.deinit(fs.alloc),
        .dir => {
            for (node_vfs.data.dir.entry_cache.items) |entry| {
                entry.node.decRef();
            }

            node_vfs.data.dir.entry_cache.deinit(fs.alloc);
        },
    }

    const lock = fs.lock.lock();
    defer lock.unlock();

    fs.node_pool.destroy(node);
}

fn create(dir_vfs: *vfs.Node, name: []const u8, opts: vfs.CreateOptions) vfs.Error!*vfs.Node {
    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);

    const glock = fs.lock.lock();
    defer glock.unlock();

    const lock = dir_vfs.lock.lock();
    defer lock.unlock();

    if (name.len > vfs.max_embedded_name_len) return error.NameTooLong;
    if (dir_vfs.kind != .dir) return error.NotADir;

    const new = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(new);

    new.* = .{
        .vfs = .{
            .kind = opts.kind,
            .vtable = &node_ops,
            .sb = dir_vfs.sb,
            // 1 ref is owned by the caller of this function
            // the other ref is owned by the dir entry
            .ref_count = .init(2),
            .data = switch (opts.kind) {
                .file => .{ .none = {} },
                .dir => .{ .dir = .{
                    .entry_cache = .empty,
                } },
            },
        },
        .data = switch (opts.kind) {
            .file => .{ .file = .{
                .data = .empty,
            } },
            .dir => .{ .none = {} },
        },
    };

    var entry: vfs.DirEntry = .{
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
        .node = &new.vfs,
    };

    @memcpy(entry.name_buf[0..name.len], name);
    try dir_vfs.data.dir.entry_cache.append(fs.alloc, entry);

    return &new.vfs;
}

fn unlink(dir_vfs: *vfs.Node, name: []const u8) vfs.Error!void {
    const lock = dir_vfs.lock.lock();
    defer lock.unlock();

    if (dir_vfs.kind != .dir) return error.NotADir;

    const index: usize = blk: for (dir_vfs.data.dir.entry_cache.items, 0..) |*entry, i| {
        if (!std.mem.eql(u8, entry.name(), name)) continue;
        break :blk i;
    } else return error.NoEntry;

    // TODO: this will cause problems later when iterating dir entries
    const entry = dir_vfs.data.dir.entry_cache.swapRemove(index);
    entry.node.decRef();
}

fn open(node_vfs: *vfs.Node) vfs.Error!*vfs.File {
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const glock = fs.lock.lock();
    defer glock.unlock();

    const lock = node_vfs.lock.lock();
    defer lock.unlock();

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

    _ = node_vfs.ref_count.fetchAdd(1, .monotonic);
    return &file.vfs;
}

fn close(vfs_file: *vfs.File) void {
    const fs: *Ramfs = @fieldParentPtr("sb", vfs_file.node.sb);
    const file: *File = @alignCast(@fieldParentPtr("vfs", vfs_file));
    const node = vfs_file.node;

    {
        const glock = fs.lock.lock();
        defer glock.unlock();
        fs.file_pool.destroy(file);
    }

    node.decRef();
}

fn read(vfs_file: *vfs.File, buffer: []u8) vfs.Error!usize {
    const lock = vfs_file.node.lock.lock();
    defer lock.unlock();

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
    const lock = vfs_file.node.lock.lock();
    defer lock.unlock();

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
    const lock = vfs_file.node.lock.lock();
    defer lock.unlock();

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
    const root = try ramfs.init(std.testing.allocator);
    root.decRef();
    defer ramfs.deinit();

    {
        try std.testing.expect(root.lookup("thing.txt") == error.NoEntry);
        const thing = try create(root, "thing.txt", .{ .kind = .file });
        thing.decRef();
    }

    {
        const thing_file = try root.lookup("thing.txt");
        thing_file.decRef();
        try unlink(root, "thing.txt");
        try std.testing.expect(root.lookup("thing.txt") == error.NoEntry);
    }
}

test "read/write" {
    var ramfs: Ramfs = undefined;
    const root = try ramfs.init(std.testing.allocator);
    root.decRef();
    defer ramfs.deinit();

    const test_data1 = "very important stuff";
    const test_data2 = "extra important info";

    {
        const other_file = try create(root, "other.thing", .{ .kind = .file });
        defer other_file.decRef();

        const thing = try open(other_file);
        defer close(thing);

        try std.testing.expect(try write(thing, test_data1) == test_data1.len);
        try seek(thing, .start, 0);
        try std.testing.expect(try write(thing, test_data2) == test_data2.len);
    }

    {
        const other_file = try root.lookup("other.thing");
        defer unlink(root, "other.thing") catch unreachable;
        defer other_file.decRef();

        const thing = try open(other_file);
        defer close(thing);

        var buffer: [test_data2.len]u8 = undefined;
        try std.testing.expect(try read(thing, buffer[0..]) == test_data2.len);
        try std.testing.expect(std.mem.eql(u8, buffer[0..], test_data2));
        try std.testing.expect(read(thing, buffer[0..]) == error.EndOfFile);
    }
}
