const std = @import("std");
const vfs = @import("vfs.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

lock: Spinlock,
alloc: std.mem.Allocator,
sb: vfs.SuperBlock,
node_pool: std.heap.MemoryPool(Node),
file_pool: std.heap.MemoryPool(File),
dir_entry_pool: std.heap.MemoryPool(vfs.DirEntry),

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
    .free_dir_entry = &freeDirEntry,
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

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator) !*vfs.DirEntry {
    fs.* = .{
        .lock = .init,
        .alloc = alloc,
        .node_pool = .empty,
        .file_pool = .empty,
        .dir_entry_pool = .empty,
        .sb = undefined,
    };

    const root = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(root);

    const root_dent = try fs.dir_entry_pool.create(fs.alloc);
    errdefer fs.dir_entry_pool.destroy(root_dent);

    fs.sb = .{
        .root = &root.vfs,
    };

    root.* = .{
        .vfs = .{
            .kind = .dir,
            .vtable = &node_ops,
            .sb = &fs.sb,
            // ref owned by root dir entry
            .ref_count = .init(1),
            .data = .{ .dir = .{
                .first_child = null,
            } },
        },
        .data = .{ .none = {} },
    };

    root_dent.* = .{
        .parent = null,
        .node = &root.vfs,
        // ref owned by caller
        .ref_count = .init(1),
        .name_buf = @as([1]u8, "/".*) ++ @as([vfs.max_embedded_name_len - 1]u8, @splat(0)),
        .name_len = 1,
        .next_sibling = null,
    };

    return root_dent;
}

pub fn deinit(fs: *Ramfs) void {
    fs.node_pool.deinit(fs.alloc);
    fs.file_pool.deinit(fs.alloc);
    fs.dir_entry_pool.deinit(fs.alloc);
}

fn free(node_vfs: *vfs.Node) void {
    std.debug.assert(node_vfs.ref_count.load(.monotonic) == 0);
    const fs: *Ramfs = @fieldParentPtr("sb", node_vfs.sb);
    const node: *Node = @fieldParentPtr("vfs", node_vfs);

    switch (node_vfs.kind) {
        .file => node.data.file.data.deinit(fs.alloc),
        .dir => {
            var maybe_entry = node_vfs.data.dir.first_child;
            while (maybe_entry) |entry| : (maybe_entry = entry.next_sibling) {
                entry.decRef();
            }
        },
    }

    const lock = fs.lock.lock();
    defer lock.unlock();

    fs.node_pool.destroy(node);
}

fn freeDirEntry(entry: *vfs.DirEntry) void {
    std.debug.assert(entry.ref_count.load(.monotonic) == 0);
    const node = entry.node;
    const fs: *Ramfs = @fieldParentPtr("sb", node.sb);

    {
        const lock = fs.lock.lock();
        defer lock.unlock();
        fs.dir_entry_pool.destroy(entry);
    }

    node.decRef();
}

fn create(dir_entry: *vfs.DirEntry, name: []const u8, opts: vfs.CreateOptions) vfs.Error!*vfs.DirEntry {
    const dir_vfs = dir_entry.node;
    const fs: *Ramfs = @fieldParentPtr("sb", dir_vfs.sb);

    if (dir_vfs.kind != .dir) return error.NotADir;

    const glock = fs.lock.lock();
    defer glock.unlock();

    const lock = dir_vfs.lock.lock();
    defer lock.unlock();

    if (name.len > vfs.max_embedded_name_len) return error.NameTooLong;

    var maybe_next = dir_vfs.data.dir.first_child;
    while (maybe_next) |next| : (maybe_next = next.next_sibling) {
        if (std.mem.eql(u8, next.getName(), name)) return error.AlreadyExists;
    }

    const new = try fs.node_pool.create(fs.alloc);
    errdefer fs.node_pool.destroy(new);

    const new_entry = try fs.dir_entry_pool.create(fs.alloc);
    errdefer fs.dir_entry_pool.destroy(new_entry);

    new.* = .{
        .vfs = .{
            .kind = opts.kind,
            .vtable = &node_ops,
            .sb = dir_vfs.sb,
            // ref owned by the dir entry
            .ref_count = .init(1),
            .data = switch (opts.kind) {
                .file => .{ .none = {} },
                .dir => .{ .dir = .{
                    .first_child = null,
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

    new_entry.* = .{
        .node = &new.vfs,
        // 1 ref owned by the caller
        // the other is owned by the directory
        .ref_count = .init(2),
        .parent = dir_entry,
        .next_sibling = dir_vfs.data.dir.first_child,
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
    };

    @memcpy(new_entry.name_buf[0..name.len], name);
    dir_vfs.data.dir.first_child = new_entry;

    return new_entry;
}

fn unlink(parent: *vfs.DirEntry, dir_entry: *vfs.DirEntry) vfs.Error!void {
    const dir_vfs = parent.node;

    blk: {
        const lock = dir_vfs.lock.lock();
        defer lock.unlock();

        if (dir_vfs.kind != .dir) return error.NotADir;
        if (dir_entry.node.kind == .dir) {
            const target_lock = dir_entry.node.lock.lock();
            defer target_lock.unlock();
            if (dir_entry.node.data.dir.first_child != null) return error.NotEmpty;
        }

        var maybe_other = dir_vfs.data.dir.first_child;
        if (maybe_other == dir_entry) {
            dir_vfs.data.dir.first_child = dir_entry.next_sibling;
            break :blk;
        }

        while (maybe_other) |other| : (maybe_other = other.next_sibling) {
            if (other.next_sibling == dir_entry) {
                other.next_sibling = dir_entry.next_sibling;
                break :blk;
            }
        }

        return error.NoEntry;
    }

    dir_entry.decRef();
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

    node_vfs.incRef();
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
    if (file.head >= data.items.len) return 0;
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
        .current => file.head,
    };

    const base_int: isize = @min(base_uint, std.math.maxInt(isize));
    file.head = @max(0, base_int +| offset);
}

test "lookup/destroy" {
    var ramfs: Ramfs = undefined;
    const root = try ramfs.init(std.testing.allocator);
    defer {
        root.decRef();
        ramfs.deinit();
    }

    {
        try std.testing.expect(root.lookup("thing.txt") == error.NoEntry);
        const thing = try create(root, "thing.txt", .{ .kind = .file });
        thing.decRef();
    }

    {
        const thing_ent = try root.lookup("thing.txt");
        thing_ent.decRef();
        try unlink(root, thing_ent);
        try std.testing.expect(root.lookup("thing.txt") == error.NoEntry);
    }
}

test "read/write" {
    var ramfs: Ramfs = undefined;
    const root = try ramfs.init(std.testing.allocator);
    defer {
        root.decRef();
        ramfs.deinit();
    }

    const test_data1 = "very important stuff";
    const test_data2 = "extra important info";

    {
        const other_ent = try create(root, "other.thing", .{ .kind = .file });
        defer other_ent.decRef();

        const thing = try open(other_ent.node);
        defer close(thing);

        try std.testing.expect(try write(thing, test_data1) == test_data1.len);
        try seek(thing, .start, 0);
        try std.testing.expect(try write(thing, test_data2) == test_data2.len);
    }

    {
        const other_ent = try root.lookup("other.thing");
        defer unlink(root, other_ent) catch unreachable;
        defer other_ent.decRef();

        const thing = try open(other_ent.node);
        defer close(thing);

        var buffer: [test_data2.len]u8 = undefined;
        try std.testing.expect(try read(thing, buffer[0..]) == test_data2.len);
        try std.testing.expect(std.mem.eql(u8, buffer[0..], test_data2));
        try std.testing.expect(try read(thing, buffer[0..]) == 0);
    }
}
