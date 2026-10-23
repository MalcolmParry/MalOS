const std = @import("std");
const mem = @import("../../memory.zig");
const pmm = @import("../../pmm.zig");
const arch = @import("../../arch/arch.zig");
const Spinlock = @import("../../sync/Spinlock.zig");
const Mutex = @import("../../sync/Mutex.zig");
const BlockDevice = @import("../../block/BlockDevice.zig");
const alloc = @import("../../heap/gpa.zig").allocator;

pub var root: ?*Mount = null;

pub const Node = @import("Node.zig");
pub const DirEntry = @import("DirEntry.zig");
pub const Mount = @import("Mount.zig");
pub const DirRecord = Node.DirRecord;
pub const Path = Mount.Path;
pub const File = Mount.File;

pub const IoError = error{ Io, Corrupt, OutOfMemory };
pub const FileError = IoError || error{ IsADir, NotSupported };
pub const ReadError = FileError;
pub const WriteError = FileError || error{ReadOnly};
pub const LookupError = IoError || error{ NotADir, NameTooLong, InvalidName, NoEntry };
pub const CreateError = IoError || error{ NotADir, NameTooLong, InvalidName, AlreadyExists, ReadOnly };
pub const UnlinkError = LookupError || error{ Busy, NotEmpty, ReadOnly };
pub const ReadDirError = IoError || error{ NotADir, NotSupported };
pub const ResizeError = FileError || error{ReadOnly};
pub const OpenError = IoError;
pub const UnmountError = error{Busy};

/// represents a single mounted filesystem
pub const SuperBlock = struct {
    /// + 1 if permanent
    mount_count: std.atomic.Value(u32),
    destroy_ptr: *const fn (sb: *SuperBlock) void,
    root: *DirEntry,

    pub fn destroy(sb: *SuperBlock) void {
        std.debug.assert(sb.mount_count.load(.monotonic) == 0);

        var current = sb.root;
        current.release();

        while (true) {
            if (current.ref_count.load(.monotonic) == 0) {
                const next = current.parent;
                const node = current.node;
                current.destroy();
                node.release();
                current = next orelse break;
                continue;
            }

            std.debug.assert(current.node.kind == .dir);
            const map = &current.node.data.dir.entries;
            var iter = map.iterator();
            const kv = iter.next() orelse @panic("dentry still referenced at unmount");
            current = kv.value_ptr.*;
            map.removeByPtr(kv.key_ptr);
        }

        sb.destroy_ptr(sb);
    }
};

pub const max_path_len = 4096;
pub const max_name_len = 255;
pub const max_embedded_name_len = 31;

pub const Name = struct {
    data: [max_embedded_name_len + 1]u8 align(@alignOf([]u8)),

    comptime {
        std.debug.assert(@sizeOf(Name) == max_embedded_name_len + 1);
        std.debug.assert(@sizeOf([]u8) <= max_embedded_name_len);
    }

    pub fn initEmbedded(str: []const u8) Name {
        std.debug.assert(str.len != 0);
        std.debug.assert(str.len <= max_embedded_name_len);

        var name: Name = undefined;
        const embedded = name.data[0..max_embedded_name_len];
        name.data[max_embedded_name_len] = @intCast(str.len);

        @memcpy(embedded[0..str.len], str);
        @memset(embedded[str.len..], 0);
        return name;
    }

    pub fn init(name: *Name, str: []const u8) !void {
        if (str.len <= max_embedded_name_len) {
            name.* = initEmbedded(str);
            return;
        }

        const heap = try alloc.dupe(u8, str);
        name.* = undefined;
        name.data[max_embedded_name_len] = 0;
        const heap_ptr: *[]u8 = @ptrCast(&name.data);
        heap_ptr.* = heap;
    }

    pub fn deinit(name: *Name) void {
        const len = name.data[max_embedded_name_len];
        if (len != 0) return;
        const heap_ptr: *[]u8 = @ptrCast(&name.data);
        alloc.free(heap_ptr.*);
    }

    pub fn get(name: *const Name) []const u8 {
        const len = name.data[max_embedded_name_len];
        if (len == 0) {
            const heap_ptr: *const []u8 = @ptrCast(&name.data);
            return heap_ptr.*;
        }

        return name.data[0..len];
    }
};

pub fn isNameValid(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > max_name_len) return false;

    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;

    for (name) |c| {
        switch (c) {
            0...31, 127, '/' => return false,
            else => {},
        }
    }

    return true;
}

pub fn sbDestroyPanic(_: *SuperBlock) void {
    @panic("not implemented");
}
