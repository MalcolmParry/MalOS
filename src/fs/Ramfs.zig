const std = @import("std");
const vfs = @import("vfs.zig");
const mem = @import("../memory.zig");
const Spinlock = @import("../Spinlock.zig");
const Ramfs = @This();

const max_name_len = 32;
const max_nodes = 64;

alloc: std.mem.Allocator,
nodes: [max_nodes]Node,
first_free_node: Node.OptRef,
next_node_alloc: u32,

const Node = struct {
    vfs_node: vfs.Node.Ref,
    first_child: OptRef,
    next_sibling: OptRef,
    name_buf: [max_name_len]u8,
    name_len: u8,
    data: std.ArrayList(u8),

    fn name(node: *Node) []u8 {
        return node.name_buf[0..node.name_len];
    }

    const Ref = enum(u32) { _ };
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
    .destroy = undefined,

    .open = undefined,
    .close = undefined,
    .read = undefined,
    .write = undefined,
};

pub fn init(fs: *Ramfs, alloc: std.mem.Allocator, sb: vfs.SuperBlock.Ref) !void {
    fs.* = .{
        .alloc = alloc,
        .nodes = undefined,
        .first_free_node = .none,
        .next_node_alloc = 0,
    };

    const root = try fs.allocNode();
    const vfs_root = try vfs.allocNode();

    vfs.nodes[@intFromEnum(vfs_root)] = .{
        .kind = .dir,
        .sb = sb,
        .parent = vfs_root,
        .mount = .none,
        .userdata = @intFromEnum(root),
    };

    const root_ptr = &fs.nodes[@intFromEnum(root)];
    root_ptr.* = .{
        .vfs_node = vfs_root,
        .first_child = .none,
        .next_sibling = .none,
        .name_buf = @splat(0),
        .name_len = 4,
        .data = .empty,
    };

    @memcpy(root_ptr.name_buf[0..4], "root");
    root_ptr.name_len = 4;

    vfs.super_blocks[@intFromEnum(sb)] = .{
        .fs = &fs_info,
        .userdata = @intFromPtr(fs),
        .root = vfs_root,
    };
}

fn lookup(dir: vfs.Node.Ref, name: []const u8) vfs.Error!vfs.Node.Ref {
    const fs = fsFromVfsNode(dir);
    const dir_ramfs = &fs.nodes[vfs.nodes[@intFromEnum(dir)].userdata];

    var maybe_next = dir_ramfs.first_child;
    while (maybe_next.unwrap()) |next_ref| {
        const next = &fs.nodes[@intFromEnum(next_ref)];

        if (std.mem.eql(u8, name, next.name())) {
            return next.vfs_node;
        }

        maybe_next = next.next_sibling;
    }

    return error.NoEntry;
}

fn create(dir: vfs.Node.Ref, name: []const u8, opts: vfs.CreateOptions) vfs.Error!vfs.Node.Ref {
    if (name.len > max_name_len) return error.NameTooLong;

    const fs = fsFromVfsNode(dir);
    const dir_vfs = &vfs.nodes[@intFromEnum(dir)];
    if (dir_vfs.kind != .dir) return error.NotADir;
    const dir_ramfs = &fs.nodes[dir_vfs.userdata];

    const new_vfs = try vfs.allocNode();
    errdefer vfs.freeNode(new_vfs);

    const new = try fs.allocNode();
    errdefer fs.freeNode(new);

    vfs.nodes[@intFromEnum(new_vfs)] = .{
        .kind = opts.kind,
        .sb = dir_vfs.sb,
        .parent = dir,
        .mount = .none,
        .userdata = @intFromEnum(new),
    };

    const node_ptr = &fs.nodes[@intFromEnum(new)];
    node_ptr.* = .{
        .vfs_node = new_vfs,
        .first_child = .none,
        .next_sibling = dir_ramfs.first_child,
        .name_buf = @splat(0),
        .name_len = @intCast(name.len),
        .data = .empty,
    };
    @memcpy(node_ptr.name_buf[0..name.len], name);
    dir_ramfs.first_child = .wrap(new);

    return new_vfs;
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
