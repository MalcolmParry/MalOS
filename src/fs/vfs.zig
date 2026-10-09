const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const arch = @import("../arch/arch.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const Mutex = @import("../sync/Mutex.zig");
const BlockDevice = @import("../block/BlockDevice.zig");
const alloc = @import("../heap/gpa.zig").allocator;

pub var root: Mount = undefined;

pub const Error = error{
    OutOfMemory,
    NoEntry,
    AlreadyExists,
    Busy,
    NotEmpty,
    NotAFile,
    NotADir,
    NameTooLong,
    ReadOnly,
    NoParent,
    InvalidName,
    NotSupported,
    Io,
    Corrupt,
};

pub const CreateOptions = struct {
    kind: Node.Kind,
};

/// represents a single mounted filesystem
pub const SuperBlock = struct {
    root: *DirEntry,
};

/// represents an object in the filesystem
/// such as a file or directory
pub const Node = struct {
    /// immutable
    kind: Kind,
    /// immutable
    vtable: *const VTable,
    /// immutable
    sb: *SuperBlock,

    /// count of cached dentries pointing to this + open files + other things using this
    ref_count: std.atomic.Value(u32),
    lock: Spinlock = .init,
    mutex: Mutex = .init,
    data: Data,

    pub const VTable = struct {
        node_free: *const fn (node: *Node) void,
        node_lookup: *const fn (parent: *Node, name: []const u8) Error!*Node = &nodeLookupNoEntry,
        node_create: *const fn (parent: *Node, name: []const u8, opts: CreateOptions) Error!*Node = &nodeCreateReadOnly,
        node_unlink: *const fn (parent: *Node, name: []const u8) Error!void = &nodeUnlinkReadOnly,

        /// assumes caller already locked the page
        node_read_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &nodeReadPageZero,
        /// assumes caller already locked the page
        node_write_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &nodeWritePageNoop,
        /// assumes caller has the node lock
        /// shouldn't touch the page cache, the vfs handles that
        node_resize: ?*const fn (node: *Node, new_size: usize) Error!void = null,

        file_open: *const fn (node: *Node) Error!*File = &fileOpenDefault,
        file_close: *const fn (file: *File) void = &fileCloseDefault,
        file_read: ?*const fn (file: *File, buffer: []u8) Error!usize = null,
        file_write: ?*const fn (file: *File, data: []const u8) Error!usize = null,
        /// returns true if wrote to record
        file_read_dir: *const fn (file: *File, record: *DirRecord) Error!bool = &fileReadDirNotSupported,
    };

    pub const Kind = enum {
        file,
        dir,
        block_device,
    };

    pub const Data = union {
        dir: Dir,
        file: Data.File,
        block_device: *BlockDevice,

        pub const Dir = struct {
            /// owned by mutex
            entries: std.StringHashMapUnmanaged(*DirEntry),
        };

        pub const File = struct {
            /// owned by lock
            size: usize,
            /// owned by lock
            /// key is page offset into file
            cache: std.AutoHashMapUnmanaged(u32, pmm.Index),
        };
    };

    pub fn acquire(node: *Node) void {
        const prev = node.ref_count.fetchAdd(1, .acquire);
        std.debug.assert(prev != 0);
    }

    pub fn release(node: *Node) void {
        const prev = node.ref_count.fetchSub(1, .release);
        std.debug.assert(prev != 0);
        if (prev != 1) return;

        _ = node.ref_count.load(.acquire);
        node.destroy();
    }

    fn destroy(node: *Node) void {
        std.debug.assert(node.ref_count.load(.monotonic) == 0);

        switch (node.kind) {
            .file => {
                const data = &node.data.file;

                var iter = data.cache.iterator();
                while (iter.next()) |kv| {
                    pmm.freePage(kv.value_ptr.toPtr());
                }

                data.cache.deinit(alloc);
            },
            .dir => {
                const data = &node.data.dir;
                std.debug.assert(data.entries.count() == 0);
                data.entries.deinit(alloc);
            },
            .block_device => {},
        }

        node.vtable.node_free(node);
    }

    pub fn open(node: *Node) Error!*File {
        return node.vtable.file_open(node);
    }

    /// caller needs to unlock page
    /// node lock must be held
    fn getOrCreatePage(node: *Node, page_offset: u32) !struct { pmm.Index, Spinlock.Lock } {
        std.debug.assert(node.kind == .file);
        const file = &node.data.file;
        if (file.cache.get(page_offset)) |index| {
            const lock = index.getDesc().data.vfs_cache.lock.lock();
            return .{ index, lock };
        }

        const page = try pmm.allocatePage();
        errdefer pmm.freePage(page);

        const index: pmm.Index = .fromPtr(page);
        const desc = index.getDesc();
        desc.data = .{ .vfs_cache = .{
            .lock = .init,
            .dirty = false,
        } };

        try node.vtable.node_read_page(node, page_offset, index);

        try file.cache.put(alloc, page_offset, index);
        return .{ index, desc.data.vfs_cache.lock.lock() };
    }

    pub fn resizeLocked(node: *Node, new_size: usize) Error!void {
        if (node.vtable.node_resize) |func| try func(node, new_size);

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

pub const DirRecord = struct {
    name_len: u16,
    name_buf: [max_embedded_name_len]u8,
    kind: Node.Kind,

    pub fn getName(record: *const DirRecord) []const u8 {
        return record.name_buf[0..record.name_len];
    }
};

pub const max_embedded_name_len = 32;
pub const DirEntry = struct {
    /// immutable
    node: *Node,
    /// immutable
    name_len: u16,
    /// immutable
    name_buf: [max_embedded_name_len]u8,

    /// immutable
    parent: ?*DirEntry,
    /// number of child dentries + things currently using this dentry + 1 if root of superblock
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
        alloc.destroy(entry);
    }

    pub fn getName(entry: *const DirEntry) []const u8 {
        return entry.name_buf[0..entry.name_len];
    }

    pub fn lookupNameLocal(parent: *DirEntry, name: []const u8) Error!*DirEntry {
        const node = parent.node;
        if (node.kind != .dir) return error.NotADir;
        if (name.len == 0 or name.len > max_embedded_name_len) return error.NoEntry;

        if (name[0] == '.') {
            if (name.len == 1) {
                parent.acquire();
                return parent;
            } else if (name.len == 2 and name[1] == '.') {
                const parent_parent = parent.parent orelse return error.NoParent;
                parent_parent.acquire();
                return parent_parent;
            }
        }

        const data = &node.data.dir;
        node.mutex.lock();
        defer node.mutex.unlock();

        if (data.entries.get(name)) |entry| {
            entry.acquire();
            return entry;
        }

        const child_node = try node.vtable.node_lookup(parent.node, name);
        errdefer child_node.release();

        const child_dentry = try alloc.create(DirEntry);
        errdefer alloc.destroy(child_dentry);

        child_dentry.* = .{
            .node = child_node,
            .name_len = @intCast(name.len),
            .name_buf = @splat(0),

            .parent = parent,
            .ref_count = .init(1),
        };
        @memcpy(child_dentry.name_buf[0..name.len], name);

        try data.entries.put(alloc, child_dentry.getName(), child_dentry);

        parent.acquire();
        return child_dentry;
    }

    pub fn lookupLocal(parent: *DirEntry, path: []const u8) Error!*DirEntry {
        if (path.len == 0) return error.NoEntry;
        if (path[0] == '/') return error.NoParent;

        var current = parent;
        var should_release: bool = false;
        errdefer if (should_release) current.release();

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |name| {
            if (name.len == 0) continue;
            if (current.node.kind != .dir) return error.NotADir;

            const next = try current.lookupNameLocal(name);
            if (should_release) current.release();
            should_release = true;
            current = next;
        }

        return current;
    }

    pub fn create(parent: *DirEntry, name: []const u8, opts: CreateOptions) Error!*DirEntry {
        if (parent.node.kind != .dir) return error.NotADir;
        if (!isNameValid(name)) return error.InvalidName;
        return parent.node.vtable.dentry_create(parent, name, opts);
    }

    pub fn unlink(parent: *DirEntry, child: *DirEntry) Error!void {
        if (parent.node.kind != .dir) return error.NotADir;
        try parent.node.vtable.dentry_unlink(parent, child);
    }
};

pub const File = struct {
    /// immutable
    node: *Node,
    head: u64 = 0,

    pub fn close(file: *File) void {
        return file.node.vtable.file_close(file);
    }

    pub fn read(file: *File, buffer: []u8) Error!usize {
        if (file.node.kind != .file) return error.NotAFile;
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
        if (file.node.kind != .file) return error.NotAFile;
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

    pub fn readDir(file: *File, record: *DirRecord) Error!bool {
        if (file.node.kind != .dir) return error.NotADir;
        return file.node.vtable.file_read_dir(file, record);
    }
};

pub const Mount = struct {
    target: ?*DirEntry,
    src: *DirEntry,

    parent: ?*Mount,
    first_child: ?*Mount,
    next_sibling: ?*Mount,

    pub fn acquireRootPath(mount: *Mount) Path {
        mount.src.acquire();
        return .{
            .mount = mount,
            .dentry = mount.src,
        };
    }
};

pub const Path = struct {
    mount: *Mount,
    dentry: *DirEntry,

    pub fn acquire(path: Path) void {
        path.dentry.acquire();
    }

    pub fn release(path: Path) void {
        path.dentry.release();
    }

    pub fn lookupName(parent: Path, name: []const u8) Error!Path {
        if (std.mem.eql(u8, name, "..")) {
            if (parent.mount.src == parent.dentry) {
                const mount = parent.mount.parent orelse return error.NoParent;
                const target = parent.mount.target orelse return error.NoParent;
                const dentry = target.parent orelse return error.NoParent;
                dentry.acquire();

                return .{
                    .mount = mount,
                    .dentry = dentry,
                };
            }

            const dentry = parent.dentry.parent orelse return error.NoParent;
            dentry.acquire();

            return .{
                .mount = parent.mount,
                .dentry = dentry,
            };
        }

        if (std.mem.eql(u8, name, ".")) {
            parent.acquire();
            return parent;
        }

        const direct = try parent.dentry.lookupNameLocal(name);

        var maybe_child = parent.mount.first_child;
        while (maybe_child) |child| : (maybe_child = child.next_sibling) {
            if (child.target != direct) continue;
            child.src.acquire();
            direct.release();

            return .{
                .mount = child,
                .dentry = child.src,
            };
        }

        return .{
            .mount = parent.mount,
            .dentry = direct,
        };
    }

    pub fn lookup(parent: Path, path: []const u8) Error!Path {
        if (path.len == 0) return error.NoEntry;

        var current = parent;
        var should_release: bool = false;
        errdefer if (should_release) current.release();

        if (path[0] == '/') {
            current = root.acquireRootPath();
            should_release = true;
        }

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |name| {
            if (name.len == 0) continue;

            const next = try current.lookupName(name);
            if (should_release) current.release();
            should_release = true;
            current = next;
        }

        return current;
    }
};

pub fn isNameValid(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > max_embedded_name_len) return false;

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

pub fn nodeFreePanic(_: *Node) void {
    @panic("not implemented");
}

pub fn dentryFreePanic(_: *DirEntry) void {
    @panic("not implemented");
}

pub fn nodeReadPageZero(_: *Node, _: u32, index: pmm.Index) Error!void {
    const direct = index.toDirectMap();
    @memset(direct.bytes[0..], 0);
}

pub fn nodeWritePageNoop(_: *Node, _: u32, _: pmm.Index) Error!void {}

pub fn nodeLookupNoEntry(parent: *Node, _: []const u8) Error!*Node {
    std.debug.assert(parent.kind == .dir);
    return error.NoEntry;
}

pub fn nodeCreateReadOnly(parent: *Node, _: []const u8, _: CreateOptions) Error!*Node {
    std.debug.assert(parent.kind == .dir);
    return error.ReadOnly;
}

pub fn nodeUnlinkReadOnly(parent: *Node, _: []const u8) Error!void {
    std.debug.assert(parent.kind == .dir);
    return error.ReadOnly;
}

pub fn fileOpenDefault(node: *Node) Error!*File {
    const file = try alloc.create(File);
    file.* = .{
        .node = node,
        .head = 0,
    };

    node.acquire();
    return file;
}

pub fn fileCloseDefault(file: *File) void {
    file.node.release();
    alloc.destroy(file);
}

pub fn fileReadDirInCache(file: *File, record: *DirRecord) Error!bool {
    file.node.mutex.lock();
    defer file.node.mutex.unlock();

    var lowest: ?*DirEntry = null;
    var iter = file.node.data.dir.entries.iterator();
    while (iter.next()) |kv| {
        const entry = kv.value_ptr.*;
        const addr = @intFromPtr(entry);
        if (addr > file.head and (lowest == null or addr < @intFromPtr(lowest.?)))
            lowest = entry;
    }

    const entry = lowest orelse return false;
    record.* = .{
        .kind = entry.node.kind,
        .name_len = entry.name_len,
        .name_buf = @splat(0),
    };
    @memcpy(record.name_buf[0..entry.name_len], entry.getName());

    file.head = @intFromPtr(entry);
    return true;
}

pub fn fileReadDirNotSupported(file: *File, _: *DirRecord) Error!bool {
    std.debug.assert(file.node.kind == .dir);
    return error.NotSupported;
}
