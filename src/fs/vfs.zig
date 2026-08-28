const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const arch = @import("../arch.zig");
const Spinlock = @import("../Spinlock.zig");
const alloc = &@import("../heap/direct_map.zig").page_alloc;

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
    vtable: *const VTable,
    sb: *SuperBlock,

    ref_count: std.atomic.Value(u32),
    lock: Spinlock = .init,
    data: Data,

    pub const VTable = struct {
        node_free: *const fn (node: *Node) void,
        dir_entry_free: *const fn (entry: *DirEntry) void,

        node_lookup: *const fn (parent: *DirEntry, name: []const u8) Error!*DirEntry = &unimplementedLookup,
        node_create: *const fn (parent: *DirEntry, name: []const u8, opts: CreateOptions) Error!*DirEntry = &unimplementedCreate,
        node_unlink: *const fn (parent: *DirEntry, child: *DirEntry) Error!void = &unimplementedUnlink,

        /// assumes caller already locked the page
        node_read_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &defaultReadPage,
        /// assumes caller already locked the page
        node_write_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &defaultWritePage,
        /// assumes caller has the node lock
        /// shouldn't touch the page cache, the vfs handles that
        node_resize: ?*const fn (node: *Node, new_size: usize) Error!void = null,

        file_open: *const fn (node: *Node) Error!*File = &unimplementedOpen,
        file_close: *const fn (file: *File) void = &unimplementedClose,
        file_read: ?*const fn (file: *File, buffer: []u8) Error!usize = null,
        file_write: ?*const fn (file: *File, data: []const u8) Error!usize = null,
    };

    pub const Kind = enum {
        file,
        dir,
    };

    pub const Data = union {
        dir: Dir,
        file: Data.File,

        pub const Dir = struct {
            first_child: ?*DirEntry,
        };

        pub const File = struct {
            size: usize,
            /// key is page offset into file
            cache: std.AutoHashMapUnmanaged(u32, pmm.Index),
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
            node.vtable.node_free(node);
        }
    }

    /// caller needs to unlock page
    /// node lock must be held
    fn getOrCreatePage(node: *Node, page_offset: u32) !struct { pmm.Index, Spinlock.Lock } {
        std.debug.assert(node.kind == .file);
        const file = &node.data.file;
        if (file.cache.get(page_offset)) |page| {
            const lock = pmm.getPageDesc(page).data.vfs_cache.lock.lock();
            return .{ page, lock };
        }

        const page = try pmm.allocatePage();
        errdefer pmm.freePage(page);

        const index: pmm.Index = .fromPtr(page);
        const desc = pmm.getPageDesc(index);
        desc.data = .{ .vfs_cache = .{
            .lock = .init,
            .dirty = false,
        } };

        try node.vtable.node_read_page(node, page_offset, index);

        try file.cache.put(alloc.*, page_offset, index);
        return .{ index, desc.data.vfs_cache.lock.lock() };
    }

    pub fn resizeLocked(node: *Node, new_size: usize) Error!void {
        if (node.vtable.node_resize) |func| return func(node, new_size);

        const file_data = &node.data.file;
        const old_page_size = (file_data.size + mem.page_size - 1) / mem.page_size;
        const new_page_size = (new_size + mem.page_size - 1) / mem.page_size;

        if (new_page_size < old_page_size) {
            for (new_page_size..old_page_size) |page_offset| {
                const kv = file_data.cache.fetchRemove(@intCast(page_offset)) orelse continue;
                pmm.freePage(kv.value.toPtr());
            }
        }

        file_data.size = new_size;
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
            entry.node.vtable.dir_entry_free(entry);
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

        return parent.node.vtable.node_lookup(parent, name);
    }
};

pub const File = struct {
    node: *Node,
    head: usize = 0,

    pub fn read(file: *File, buffer: []u8) Error!usize {
        if (file.node.vtable.file_read) |func| return func(file, buffer);

        const lock = file.node.lock.lock();
        defer lock.unlock();

        const file_data = &file.node.data.file;
        const end = @min(file.head + buffer.len, file_data.size);
        if (end <= file.head) return 0;

        var head = file.head;
        var bytes_read: usize = 0;
        while (head < end) {
            const page_offset: u32 = @intCast(head / mem.page_size);

            const page_index, const page_lock = try file.node.getOrCreatePage(page_offset);
            defer page_lock.unlock();

            const direct = page_index.toDirectMap();
            const head_offset_from_page = head % mem.page_size;
            const end_offset_from_page = @min(end - (@as(usize, page_offset) * mem.page_size), mem.page_size);
            const to_read = end_offset_from_page - head_offset_from_page;

            @memcpy(buffer[bytes_read..][0..to_read], direct.bytes[head_offset_from_page..end_offset_from_page]);

            head += to_read;
            bytes_read += to_read;
        }

        file.head = head;
        return bytes_read;
    }

    pub fn write(file: *File, data: []const u8) Error!usize {
        if (file.node.vtable.file_write) |func| return func(file, data);

        const lock = file.node.lock.lock();
        defer lock.unlock();

        const file_data = &file.node.data.file;
        const end = file.head + data.len;
        if (end > file_data.size) try file.node.resizeLocked(end);

        var head = file.head;
        var written: usize = 0;
        while (head < end) {
            const page_offset: u32 = @intCast(head / mem.page_size);
            const page_index, const page_lock = try file.node.getOrCreatePage(page_offset);
            defer page_lock.unlock();

            const direct = page_index.toDirectMap();
            const head_offset_from_page = head % mem.page_size;
            const end_offset_from_page = @min(end - (@as(usize, page_offset) * mem.page_size), mem.page_size);
            const to_write = end_offset_from_page - head_offset_from_page;

            @memcpy(direct.bytes[head_offset_from_page..end_offset_from_page], data[written..][0..to_write]);
            pmm.getPageDesc(page_index).data.vfs_cache.dirty = true;

            head += to_write;
            written += to_write;
        }

        file.head = head;
        return written;
    }
};

fn defaultReadPage(_: *Node, _: u32, index: pmm.Index) Error!void {
    const direct = index.toDirectMap();
    @memset(direct.bytes[0..], 0);
}

fn defaultWritePage(_: *Node, _: u32, index: pmm.Index) Error!void {
    const desc = pmm.getPageDesc(index);
    desc.data.vfs_cache.dirty = false;
}

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
