const std = @import("std");
const vfs = @import("vfs.zig");
const mem = @import("../memory.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

const max_name_len = 32;
const max_nodes = 64;

lock: Spinlock,
alloc: std.mem.Allocator,
nodes: [max_nodes]Node,
first_free_node: Node.OptRef,
next_node_alloc: u32,

const Node = struct {
    vfs_node: vfs.Node.Ref,
    next_sibling: OptRef,
    name_buf: [max_name_len]u8,
    name_len: u8,

    data: union {
        file: struct {
            data: std.ArrayList(u8),
        },
        dir: struct {
            first_child: OptRef,
        },
    },

    fn name(node: *const Node) []const u8 {
        return node.name_buf[0..node.name_len];
    }

    const Ref = enum(u32) {
        _,

        fn get(ref: Ref, fs: *Ramfs) *Node {
            return &fs.nodes[@intFromEnum(ref)];
        }
    };

    const OptRef = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn wrap(maybe_ref: ?Ref) OptRef {
            if (maybe_ref) |ref| std.debug.assert(@intFromEnum(ref) != @intFromEnum(OptRef.none));
            return if (maybe_ref) |ref| @enumFromInt(@intFromEnum(ref)) else .none;
        }

        pub fn unwrap(maybe_ref: OptRef) ?Ref {
            if (maybe_ref == .none) return null;
            return @enumFromInt(@intFromEnum(maybe_ref));
        }
    };
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

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator) !vfs.SuperBlock.Ref {
    fs.* = .{
        .lock = .init,
        .alloc = alloc,
        .nodes = undefined,
        .first_free_node = .none,
        .next_node_alloc = 0,
    };

    const sb = try vfs.allocSuperBlock();
    errdefer vfs.freeSuperBlock(sb);

    const root = try fs.allocNode();
    errdefer fs.freeNode(root);

    const vfs_root = try vfs.allocNode();
    errdefer vfs.freeNode(vfs_root);

    vfs.nodes[@intFromEnum(vfs_root)] = .{
        .kind = .dir,
        .ref_count = 0,
        .sb = sb,
        .parent = vfs_root,
        .mount = .none,
        .userdata = @intFromEnum(root),
    };

    fs.nodes[@intFromEnum(root)] = .{
        .vfs_node = vfs_root,
        .next_sibling = .none,
        .name_buf = @as([1]u8, "/".*) ++ @as([max_name_len - 1]u8, @splat(0)),
        .name_len = 1,
        .data = .{ .dir = .{
            .first_child = .none,
        } },
    };

    vfs.super_blocks[@intFromEnum(sb)] = .{
        .fs = &fs_info,
        .userdata = @intFromPtr(fs),
        .root = vfs_root,
    };

    return sb;
}

fn lookup(dir: vfs.Node.Ref, name: []const u8) vfs.Error!vfs.Node.Ref {
    const fs = fsFromVfsNode(dir);
    fs.lock.lock();
    defer fs.lock.unlock();

    const dir_vfs = &vfs.nodes[@intFromEnum(dir)];
    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir_ramfs = &fs.nodes[dir_vfs.userdata];

    var maybe_next = dir_ramfs.data.dir.first_child;
    while (maybe_next.unwrap()) |next_ref| {
        const next = &fs.nodes[@intFromEnum(next_ref)];

        if (std.mem.eql(u8, name, next.name())) {
            next.vfs_node.incRef();
            return next.vfs_node;
        }

        maybe_next = next.next_sibling;
    }

    return error.NoEntry;
}

fn create(dir: vfs.Node.Ref, name: []const u8, opts: vfs.CreateOptions) vfs.Error!vfs.Node.Ref {
    if (name.len > max_name_len) return error.NameTooLong;

    const fs = fsFromVfsNode(dir);
    fs.lock.lock();
    defer fs.lock.unlock();

    const dir_vfs = &vfs.nodes[@intFromEnum(dir)];
    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir_ramfs = &fs.nodes[dir_vfs.userdata];

    const new_vfs = try vfs.allocNode();
    errdefer vfs.freeNode(new_vfs);

    const new = try fs.allocNode();
    errdefer fs.freeNode(new);

    vfs.nodes[@intFromEnum(new_vfs)] = .{
        .kind = opts.kind,
        .ref_count = 1,
        .sb = dir_vfs.sb,
        .parent = dir,
        .mount = .none,
        .userdata = @intFromEnum(new),
    };

    const node_ptr = &fs.nodes[@intFromEnum(new)];
    node_ptr.* = .{
        .vfs_node = new_vfs,
        .next_sibling = dir_ramfs.data.dir.first_child,
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
        .data = switch (opts.kind) {
            .file => .{ .file = .{
                .data = .empty,
            } },
            .dir => .{ .dir = .{
                .first_child = .none,
            } },
        },
    };
    @memcpy(node_ptr.name_buf[0..name.len], name);
    dir_ramfs.data.dir.first_child = .wrap(new);

    return new_vfs;
}

fn destroy(node: vfs.Node.Ref) vfs.Error!void {
    const fs = fsFromVfsNode(node);
    fs.lock.lock();
    defer fs.lock.unlock();

    const node_ptr = &vfs.nodes[@intFromEnum(node)];
    std.debug.assert(node_ptr.ref_count != 0);
    if (node_ptr.ref_count != 1) return error.FileBusy;

    const ramfs_node: Node.Ref = @enumFromInt(node_ptr.userdata);
    const parent_vfs = node.get().parent;
    const parent_ramfs: Node.Ref = @enumFromInt(parent_vfs.get().userdata);

    if (parent_ramfs.get(fs).data.dir.first_child.unwrap().? == ramfs_node) {
        parent_ramfs.get(fs).data.dir.first_child = ramfs_node.get(fs).next_sibling;
    } else {
        var maybe_next = parent_ramfs.get(fs).data.dir.first_child;

        while (maybe_next.unwrap()) |next| {
            if (next.get(fs).next_sibling == Node.OptRef.wrap(ramfs_node)) {
                next.get(fs).next_sibling = ramfs_node.get(fs).next_sibling;
            }

            maybe_next = next.get(fs).next_sibling;
        }
    }

    vfs.freeNode(node);
    fs.freeNode(ramfs_node);
}

fn open(node: vfs.Node.Ref) vfs.Error!vfs.File.Ref {
    const fs = fsFromVfsNode(node);
    fs.lock.lock();
    defer fs.lock.unlock();

    if (node.get().kind != .file) return error.NotAFile;

    const file_ref = try vfs.allocFile();
    errdefer vfs.freeFile(file_ref);

    const file = &vfs.files[@intFromEnum(file_ref)];
    file.node = node;
    file.userdata = 0;

    node.incRef();
    return file_ref;
}

fn close(file: vfs.File.Ref) void {
    const file_ptr = vfs.files[@intFromEnum(file)];
    const fs = fsFromVfsNode(file_ptr.node);
    fs.lock.lock();
    defer fs.lock.unlock();

    file_ptr.node.decRef();
    vfs.freeFile(file);
}

fn read(file: vfs.File.Ref, buffer: []u8) vfs.Error!usize {
    const fs = fsFromVfsNode(file.get().node);
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: Node.Ref = @enumFromInt(file.get().node.get().userdata);
    const data = &node.get(fs).data.file.data;
    if (file.get().userdata >= data.items.len) return error.EndOfFile;
    const remaining = data.items[file.get().userdata..];

    const bytes_to_read = @min(remaining.len, buffer.len);
    @memcpy(buffer[0..bytes_to_read], remaining[0..bytes_to_read]);
    file.get().userdata += bytes_to_read;
    return bytes_to_read;
}

fn write(file: vfs.File.Ref, data: []const u8) vfs.Error!usize {
    const file_ptr = &vfs.files[@intFromEnum(file)];
    const fs = fsFromVfsNode(file_ptr.node);
    fs.lock.lock();
    defer fs.lock.unlock();

    const node: Node.Ref = @enumFromInt(file.get().node.get().userdata);
    const file_data = &node.get(fs).data.file.data;
    const old_size = file_data.items.len;
    const new_head = file_ptr.userdata + data.len;

    if (new_head > old_size) {
        try file_data.resize(fs.alloc, new_head);
    }

    @memcpy(file_data.items[file_ptr.userdata..], data);
    file_ptr.userdata = new_head;
    return data.len;
}

fn seek(file: vfs.File.Ref, pos: usize) vfs.Error!void {
    const file_ptr = &vfs.files[@intFromEnum(file)];
    const fs = fsFromVfsNode(file_ptr.node);
    fs.lock.lock();
    defer fs.lock.unlock();

    file_ptr.userdata = pos;
}

fn fsFromVfsNode(node: vfs.Node.Ref) *Ramfs {
    const sb = vfs.nodes[@intFromEnum(node)].sb;
    return @ptrFromInt(vfs.super_blocks[@intFromEnum(sb)].userdata);
}

fn allocNode(fs: *Ramfs) error{TooManyNodes}!Node.Ref {
    if (fs.next_node_alloc < max_nodes) {
        const result: Node.Ref = @enumFromInt(fs.next_node_alloc);
        fs.next_node_alloc += 1;
        return result;
    }

    const ref = fs.first_free_node.unwrap() orelse return error.TooManyNodes;
    fs.first_free_node = fs.nodes[@intFromEnum(ref)].next_sibling;
    return ref;
}

fn freeNode(fs: *Ramfs, node: Node.Ref) void {
    fs.nodes[@intFromEnum(node)].next_sibling = fs.first_free_node;
    fs.first_free_node = .wrap(node);
}
