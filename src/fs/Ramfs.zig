const std = @import("std");
const vfs = @import("vfs.zig");
const pmm = @import("../pmm.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

lock: Spinlock,
alloc: std.mem.Allocator,
sb: vfs.SuperBlock,
node_pool: std.heap.MemoryPool(vfs.Node),
file_pool: std.heap.MemoryPool(vfs.File),
dir_entry_pool: std.heap.MemoryPool(vfs.DirEntry),

const node_vtable: vfs.Node.VTable = .{
    .node_free = &free,
    .dir_entry_free = &freeDirEntry,

    .node_create = &create,
    .node_unlink = &unlink,

    .file_open = &open,
    .file_close = &close,
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
        .root = root,
    };

    root.* = .{
        .kind = .dir,
        .vtable = &node_vtable,
        .sb = &fs.sb,
        // ref owned by root dir entry
        .ref_count = .init(1),
        .data = .{ .dir = .{
            .first_child = null,
        } },
    };

    root_dent.* = .{
        .parent = null,
        .node = root,
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

fn free(node: *vfs.Node) void {
    std.debug.assert(node.ref_count.load(.monotonic) == 0);
    const fs: *Ramfs = @fieldParentPtr("sb", node.sb);

    const lock = fs.lock.lock();
    defer lock.unlock();

    fs.node_pool.destroy(node);
    std.log.info("node freed", .{});
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
    std.log.info("dentry freed", .{});
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
        .kind = opts.kind,
        .vtable = &node_vtable,
        .sb = dir_vfs.sb,
        // ref owned by the dir entry
        .ref_count = .init(1),
        .data = switch (opts.kind) {
            .file => .{ .file = .{
                .size = 0,
                .cache = .empty,
            } },
            .dir => .{ .dir = .{
                .first_child = null,
            } },
        },
    };

    new_entry.* = .{
        .node = new,
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

fn open(node: *vfs.Node) vfs.Error!*vfs.File {
    const fs: *Ramfs = @fieldParentPtr("sb", node.sb);
    const glock = fs.lock.lock();
    defer glock.unlock();

    const lock = node.lock.lock();
    defer lock.unlock();

    if (node.kind != .file) return error.NotAFile;

    const file = try fs.file_pool.create(fs.alloc);
    errdefer fs.file_pool.destroy(file);

    file.* = .{
        .node = node,
        .head = 0,
    };

    node.incRef();
    return file;
}

fn close(file: *vfs.File) void {
    const fs: *Ramfs = @fieldParentPtr("sb", file.node.sb);
    const node = file.node;

    {
        const glock = fs.lock.lock();
        defer glock.unlock();
        fs.file_pool.destroy(file);
    }

    node.decRef();
}
