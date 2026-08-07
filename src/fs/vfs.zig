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
    lock: Spinlock,
    root: *Node,
};

/// represents an object in the filesystem
/// such as a file or directory
pub const Node = struct {
    kind: Kind,
    vtable: *const Ops,
    sb: *SuperBlock,
    mount: ?*Node = null,
    ref_count: u32 = 0,

    pub fn decRef(node: *Node) void {
        node.ref_count -= 1;
        if (node.ref_count == 0)
            node.vtable.free(node);
    }

    pub const Ops = struct {
        free: *const fn (node: *Node) void,
        lookup: *const fn (dir: *Node, name: []const u8) Error!*Node,
        create: *const fn (dir: *Node, name: []const u8, opts: CreateOptions) Error!*Node = &unimplementedCreate,
        unlink: *const fn (dir: *Node, name: []const u8) Error!void = &unimplementedUnlink,
        open: *const fn (node: *Node) Error!*File = &unimplementedOpen,
    };

    pub const Kind = enum {
        file,
        dir,
    };
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
