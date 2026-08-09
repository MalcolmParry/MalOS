const std = @import("std");
const Spinlock = @import("../Spinlock.zig");

pub var root: *Node = undefined;

pub const Error = error{
    OutOfMemory,
    NoEntry,
    AlreadyExists,
    Busy,
    NotEmpty,
    NotAFile,
    NotADir,
    NameTooLong,
    NotSupported,
};

pub const CreateOptions = struct {
    kind: Node.Kind,
};

pub const SeekBase = enum {
    start,
    end,
    current,
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

    ref_count: std.atomic.Value(u32),
    lock: Spinlock = .init,
    data: Data,

    pub const Ops = struct {
        free: *const fn (node: *Node) void,
        free_dir_entry: *const fn (entry: *DirEntry) void,
        lookup: *const fn (parent: *DirEntry, name: []const u8) Error!*DirEntry = &unimplementedLookup,
        create: *const fn (parent: *DirEntry, name: []const u8, opts: CreateOptions) Error!*DirEntry = &unimplementedCreate,
        unlink: *const fn (parent: *DirEntry, child: *DirEntry) Error!void = &unimplementedUnlink,
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
            first_child: ?*DirEntry,
        };
    };

    pub fn incRef(node: *Node) void {
        const prev_count = node.ref_count.fetchAdd(1, .acquire);
        std.debug.assert(prev_count != 0);
    }

    pub fn decRef(node: *Node) void {
        const prev_count = node.ref_count.fetchSub(1, .release);

        std.debug.assert(prev_count != 0);
        if (prev_count == 1) {
            node.vtable.free(node);
        }
    }
};

pub const max_embedded_name_len = 32;
pub const DirEntry = struct {
    node: *Node,
    name_len: u16,
    name_buf: [max_embedded_name_len]u8,

    parent: ?*DirEntry,
    next_sibling: ?*DirEntry,

    ref_count: std.atomic.Value(u32),

    pub fn incRef(entry: *DirEntry) void {
        const prev_count = entry.ref_count.fetchAdd(1, .acquire);
        std.debug.assert(prev_count != 0);
    }

    pub fn decRef(entry: *DirEntry) void {
        const prev_count = entry.ref_count.fetchSub(1, .release);

        std.debug.assert(prev_count != 0);
        if (prev_count == 1) {
            entry.node.vtable.free_dir_entry(entry);
        }
    }

    pub fn getName(entry: *const DirEntry) []const u8 {
        return entry.name_buf[0..entry.name_len];
    }

    pub fn lookup(parent: *DirEntry, name: []const u8) Error!*DirEntry {
        if (parent.node.kind != .dir) return error.NotADir;

        {
            const lock = parent.node.lock.lock();
            defer lock.unlock();

            var maybe_entry = parent.node.data.dir.first_child;
            while (maybe_entry) |entry| : (maybe_entry = entry.next_sibling) {
                if (!std.mem.eql(u8, entry.getName(), name)) continue;
                entry.incRef();
                return entry;
            }
        }

        return parent.node.vtable.lookup(parent, name);
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

pub fn unimplementedLookup(parent: *DirEntry, _: []const u8) Error!*DirEntry {
    if (parent.node.kind != .dir) return error.NotADir;
    return error.NoEntry;
}

pub fn unimplementedCreate(_: *DirEntry, _: []const u8, _: CreateOptions) Error!*DirEntry {
    return error.NotSupported;
}

pub fn unimplementedUnlink(_: *DirEntry, _: *DirEntry) Error!void {
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
