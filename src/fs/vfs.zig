const std = @import("std");
const Spinlock = @import("../Spinlock.zig");

pub var root: *Node = undefined;

pub const Error = error{
    OutOfMemory,
    NoEntry,
    FileBusy,
    NotEmpty,
    NotAFile,
    NotADir,
    NameTooLong,
    EndOfFile,
    NotSupported,
};

pub const CreateOptions = struct {
    kind: Node.Kind,
};

pub const SeekBase = enum {
    start,
    end,
    head,
};

/// represents a single mounted filesystem
pub const SuperBlock = struct {
    root: *Node,
};

/// represents an object in the filesystem
/// such as a file or directory
pub const Node = struct {
    kind: Kind,
    vtable: *const Ops,
    sb: *SuperBlock,
    mount: ?*Node = null,

    ref_count: std.atomic.Value(u32),
    lock: Spinlock = .init,
    data: Data,

    pub const Ops = struct {
        free: *const fn (node: *Node) void,
        lookup: *const fn (dir: *Node, name: []const u8) Error!*Node = &unimplementedLookup,
        create: *const fn (dir: *Node, name: []const u8, opts: CreateOptions) Error!*Node = &unimplementedCreate,
        unlink: *const fn (dir: *Node, name: []const u8) Error!void = &unimplementedUnlink,
        open: *const fn (node: *Node) Error!*File = &unimplementedOpen,
    };

    pub const Kind = enum {
        file,
        dir,
    };

    pub const Data = union {
        none: void,
        dir: Dir,

        pub const Dir = struct {
            entry_cache: std.ArrayList(DirEntry),
        };
    };

    pub fn decRef(node: *Node) void {
        const prev_count = node.ref_count.fetchSub(1, .monotonic);

        std.debug.assert(prev_count != 0);
        if (prev_count == 1) {
            node.vtable.free(node);
        }
    }

    pub fn lookup(dir: *Node, name: []const u8) Error!*Node {
        if (dir.kind != .dir) return error.NotADir;

        {
            const lock = dir.lock.lock();
            defer lock.unlock();

            for (dir.data.dir.entry_cache.items) |*entry| {
                if (!std.mem.eql(u8, entry.name(), name)) continue;
                _ = entry.node.ref_count.fetchAdd(1, .monotonic);
                return entry.node;
            }
        }

        return dir.vtable.lookup(dir, name);
    }
};

pub const max_embedded_name_len = 64 - @sizeOf(*Node) - @sizeOf(u16);
pub const DirEntry = struct {
    node: *Node,
    name_len: u16,
    name_buf: [max_embedded_name_len]u8,

    pub fn name(entry: *const DirEntry) []const u8 {
        return entry.name_buf[0..entry.name_len];
    }
};

pub const File = struct {
    node: *Node,
    vtable: *const Ops,

    pub const Ops = struct {
        close: *const fn (file: *File) void = &unimplementedClose,
        read: *const fn (file: *File, buffer: []u8) Error!usize = &unimplementedRead,
        write: *const fn (file: *File, data: []const u8) Error!usize = &unimplementedWrite,
        seek: *const fn (file: *File, base: SeekBase, offset: isize) Error!void = &unimplementedSeek,
    };
};

pub fn unimplementedLookup(dir: *Node, _: []const u8) Error!*Node {
    if (dir.kind != .dir) return error.NotADir;
    return error.NoEntry;
}

pub fn unimplementedCreate(_: *Node, _: []const u8, _: CreateOptions) Error!*Node {
    return error.NotSupported;
}

pub fn unimplementedUnlink(_: *Node, _: []const u8) Error!void {
    return error.NotSupported;
}

pub fn unimplementedOpen(_: *Node) Error!*File {
    return error.NotSupported;
}

pub fn unimplementedClose(_: *File) void {
    @panic("not implemented");
}

pub fn unimplementedRead(_: *File, _: []u8) Error!usize {
    return error.NotSupported;
}

pub fn unimplementedWrite(_: *File, _: []const u8) Error!usize {
    return error.NotSupported;
}

pub fn unimplementedSeek(_: *File, _: SeekBase, _: isize) Error!void {
    return error.NotSupported;
}
