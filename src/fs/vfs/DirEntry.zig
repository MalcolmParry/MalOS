const std = @import("std");
const Node = @import("Node.zig");
const DirEntry = @This();
const alloc = @import("../../heap/gpa.zig").allocator;

const vfs = @import("vfs.zig");
const Name = vfs.Name;
const Error = vfs.Error;

/// immutable
node: *Node,
/// immutable
name: Name,

/// immutable
parent: ?*DirEntry,
/// number of child dentries + things currently using this dentry + 1 if root of superblock + 1 if mount root
/// highest bit is unlinked flag
ref_count: std.atomic.Value(u32),

const unlinked_bit: u32 = 1 << 31;
pub fn acquire(entry: *DirEntry) void {
    const prev = entry.ref_count.fetchAdd(1, .acquire);
    std.debug.assert(prev != unlinked_bit);
    std.debug.assert(prev & ~unlinked_bit != ~unlinked_bit);
}

pub fn release(entry: *DirEntry) void {
    const prev = entry.ref_count.fetchSub(1, .release);
    std.debug.assert(prev & ~unlinked_bit != 0);

    if (prev == 1 | unlinked_bit) {
        _ = entry.ref_count.load(.acquire);
        const node = entry.node;
        entry.destroy();
        node.release();
    }
}

pub fn destroy(entry: *DirEntry) void {
    std.debug.assert(entry.ref_count.load(.monotonic) & ~unlinked_bit == 0);
    if (entry.parent) |p| p.release();
    entry.name.deinit();
    alloc.destroy(entry);
}

pub fn lookupNameLocal(parent: *DirEntry, name: []const u8) Error!*DirEntry {
    const node = parent.node;
    std.debug.assert(node.kind == .dir);
    std.debug.assert(name.len != 0 and name.len <= vfs.max_name_len);

    if (name[0] == '.') {
        if (name.len == 1) unreachable;
        if (name.len == 2 and name[1] == '.') unreachable;
    }

    const data = &node.data.dir;
    node.mutex.lock();
    defer node.mutex.unlock();

    if (data.entries.get(name)) |entry| {
        entry.acquire();
        return entry;
    }

    const child_node = try node.vtable.lookup(parent.node, name);
    errdefer child_node.release();

    const child_dentry = try alloc.create(DirEntry);
    errdefer alloc.destroy(child_dentry);

    child_dentry.* = .{
        .node = child_node,
        .name = undefined,
        .parent = parent,
        .ref_count = .init(1),
    };
    try child_dentry.name.init(name);
    errdefer child_dentry.name.deinit();

    try data.entries.put(alloc, child_dentry.name.get(), child_dentry);

    parent.acquire();
    return child_dentry;
}
