const std = @import("std");

pub var root: *Node = undefined;

pub const Error = error{
    OutOfMemory,
    NoEntry,
    TooManySuperBlocks,
    TooManyNodes,
    TooManyFiles,
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

pub const FileSystem = struct {
    lookup: *const fn (dir: *Node, name: []const u8) Error!*Node,
    create: *const fn (dir: *Node, name: []const u8, opts: CreateOptions) Error!*Node = &unimplementedCreate,
    destroy: *const fn (node: *Node) Error!void = &unimplementedDestroy,

    open: *const fn (node: *Node) Error!*File = &unimplementedOpen,
    close: *const fn (file: *File) void = &unimplementedClose,
    read: *const fn (file: *File, buffer: []u8) Error!usize = &unimplementedRead,
    write: *const fn (file: *File, data: []const u8) Error!usize = &unimplementedWrite,
    seek: *const fn (file: *File, pos: usize) Error!void = &unimplementedSeek,
};

/// represents a single mounted filesystem
pub const SuperBlock = struct {
    fs: *const FileSystem,
    root: *Node,
};

/// represents an object in the filesystem
/// such as a file or directory
pub const Node = struct {
    kind: Kind,
    ref_count: u32,
    /// superblock this node is from
    sb: *SuperBlock,
    /// the parent of this node
    /// if this node is the root of this superblock,
    /// the parent should be set to itself
    parent: *Node,
    /// this is a directory node that is mounted onto this node
    /// this is ignored if kind != .dir
    mount: ?*Node,

    pub const Kind = enum {
        file,
        dir,
    };

    pub fn lookup(dir: *Node, name: []const u8) Error!*Node {
        return dir.sb.fs.lookup(dir, name);
    }

    pub fn create(dir: *Node, name: []const u8, opts: CreateOptions) Error!*Node {
        return dir.sb.fs.create(dir, name, opts);
    }

    pub fn destroy(node: *Node) Error!void {
        try node.sb.fs.destroy(node);
    }

    pub fn open(node: *Node) Error!*File {
        return node.sb.fs.open(node);
    }
};

/// represents and opened file
pub const File = struct {
    node: *Node,

    pub fn close(file: *File) void {
        file.node.sb.fs.close(file);
    }

    pub fn read(file: *File, buffer: []u8) Error!usize {
        return file.node.sb.fs.read(file, buffer);
    }

    pub fn write(file: *File, data: []const u8) Error!usize {
        return file.node.sb.fs.write(file, data);
    }

    pub fn seek(file: *File, pos: usize) Error!void {
        return file.node.sb.fs.seek(file, pos);
    }
};

pub fn unimplementedCreate(_: *Node, _: []const u8, _: CreateOptions) Error!*Node {
    return error.NotSupported;
}

pub fn unimplementedDestroy(_: *Node) Error!void {
    return error.NotSupported;
}

pub fn unimplementedOpen(_: *Node) Error!*File {
    return error.NotSupported;
}

pub fn unimplementedClose(_: *File) void {}

pub fn unimplementedRead(_: *File, _: []u8) Error!usize {
    return error.NotSupported;
}

pub fn unimplementedWrite(_: *File, _: []const u8) Error!usize {
    return error.NotSupported;
}

pub fn unimplementedSeek(_: *File, _: usize) Error!void {
    return error.NotSupported;
}
