const std = @import("std");

const max_super_blocks = 8;
const max_nodes = 256;
const max_files = 16;

pub const Error = error{
    NoEntry,
    TooManyNodes,
    TooManyOpenFiles,
    FileBusy,
    NotEmpty,
    NotAFile,
    NotADir,
    NameTooLong,
    NotSupported,
};

pub const CreateOptions = struct {
    kind: Node.Kind,
};

pub const FileSystem = struct {
    lookup: *const fn (dir: Node.Ref, name: []const u8) Error!Node.Ref,
    create: *const fn (dir: Node.Ref, name: []const u8, opts: CreateOptions) Error!Node.Ref,
    destroy: *const fn (node: Node.Ref) Error!void,

    open: *const fn (node: Node.Ref) Error!File.Ref,
    close: *const fn (file: File.Ref) void,
    read: *const fn (file: File.Ref, buffer: []u8) Error!usize,
    write: *const fn (file: File.Ref, data: []const u8) Error!usize,
};

/// represents a single mounted filesystem
pub const SuperBlock = struct {
    fs: *const FileSystem,
    userdata: usize,
    root: Node.Ref,

    pub const Ref = enum(u32) { _ };
};

/// represents an object in the filesystem
/// such as a file or directory
pub const Node = struct {
    kind: Kind,
    /// number of opened files/directories
    /// referencing this node
    ref_count: u32 = 0,
    /// superblock this node is from
    sb: SuperBlock.Ref,
    /// the parent of this node
    /// if this node is the root of this superblock,
    /// the parent should be set to itself
    parent: Node.Ref,
    /// this is a directory node that is mounted onto this node
    /// this is ignored if kind != .dir
    mount: OptRef,
    userdata: usize,

    pub const Kind = enum {
        file,
        dir,
    };

    pub const Ref = enum(u32) {
        _,

        pub fn lookup(dir: Node.Ref, name: []const u8) Error!Node.Ref {
            const sb = nodes[@intFromEnum(dir)].sb;
            const fs = super_blocks[@intFromEnum(sb)].fs;
            return fs.lookup(dir, name);
        }

        pub fn create(dir: Node.Ref, name: []const u8, opts: CreateOptions) Error!Node.Ref {
            const sb = nodes[@intFromEnum(dir)].sb;
            const fs = super_blocks[@intFromEnum(sb)].fs;
            return fs.create(dir, name, opts);
        }
    };

    pub const OptRef = enum(u32) {
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

/// represents and opened file
pub const File = struct {
    node: Node.Ref,
    userdata: usize,

    pub const Ref = enum(u32) { _ };
    pub const OptRef = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn wrap(maybe_ref: ?Ref) OptRef {
            if (maybe_ref) |ref| std.debug.assert(ref != @intFromEnum(OptRef.none));
            return if (maybe_ref) |ref| @enumFromInt(@intFromEnum(ref)) else .none;
        }

        pub fn unwrap(maybe_ref: OptRef) ?Ref {
            if (maybe_ref == .none) return null;
            return @enumFromInt(@intFromEnum(maybe_ref));
        }
    };
};

pub var root: Node.Ref = undefined;
pub var super_blocks: [max_super_blocks]SuperBlock = undefined;

pub var nodes: [max_nodes]Node = undefined;
var first_free_node: Node.OptRef = .none;
var next_node_alloc: u32 = 0;

pub var files: [max_files]File = undefined;
var first_free_file: File.OptRef = .none;
var next_file_alloc: u32 = 0;

pub fn allocNode() error{TooManyNodes}!Node.Ref {
    if (next_node_alloc < max_nodes) {
        const result: Node.Ref = @enumFromInt(next_node_alloc);
        next_node_alloc += 1;
        return result;
    }

    const ref = first_free_node.unwrap() orelse return error.TooManyNodes;
    first_free_node = @enumFromInt(nodes[@intFromEnum(ref)].userdata);
    return ref;
}

pub fn freeNode(node: Node.Ref) void {
    nodes[@intFromEnum(node)].userdata = @intFromEnum(first_free_node);
    first_free_node = .wrap(node);
}

pub fn allocFile() error{TooManyFiles}!File.Ref {
    if (next_file_alloc < max_files) {
        const result: File.Ref = @enumFromInt(next_file_alloc);
        next_file_alloc += 1;
        return result;
    }

    const ref = first_free_file.unwrap() orelse return error.TooManyFiles;
    first_free_file = @enumFromInt(files[@intFromEnum(ref)].userdata);
    return ref;
}

pub fn freeFile(file: File.Ref) void {
    files[@intFromEnum(file)].userdata = @intFromEnum(first_free_file);
    first_free_file = file;
}
