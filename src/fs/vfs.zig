const std = @import("std");
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const arch = @import("../arch/arch.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const Mutex = @import("../sync/Mutex.zig");
const BlockDevice = @import("../block/BlockDevice.zig");
const alloc = @import("../heap/gpa.zig").allocator;

pub var root: ?*Mount = null;
var mounts: std.AutoHashMapUnmanaged(Path, *Mount) = .empty;
var mounts_lock: Spinlock = .init;

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
    mount_count: std.atomic.Value(u32),
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
        node_destroy: *const fn (node: *Node) void,
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

        node.vtable.node_destroy(node);
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
    kind: Node.Kind,
    name_len: u8,
    name_buf: [max_name_len]u8,

    pub fn getName(record: *const DirRecord) []const u8 {
        return record.name_buf[0..record.name_len];
    }
};

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

pub const DirEntry = struct {
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
        std.debug.assert(name.len != 0 and name.len <= max_name_len);

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

        const child_node = try node.vtable.node_lookup(parent.node, name);
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
    path: Path,
    head: u64 = 0,

    pub fn close(file: *File) void {
        const path = file.path;
        const node = path.dentry.node;
        node.vtable.file_close(file);
        path.release();
    }

    pub fn read(file: *File, buffer: []u8) Error!usize {
        const node = file.path.dentry.node;
        if (node.kind != .file) return error.NotAFile;
        if (node.vtable.file_read) |func| return func(file, buffer);

        const lock = node.lock.lock();
        defer lock.unlock();

        const file_data = &node.data.file;
        const end = @min(file.head + buffer.len, file_data.size);
        if (end <= file.head) return 0;

        var head = file.head;
        var bytes_read: usize = 0;
        while (head < end) {
            const page_offset: u32 = @intCast(head / mem.page_size);

            const page_index, const page_lock = try node.getOrCreatePage(page_offset);
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
        const node = file.path.dentry.node;
        if (node.kind != .dir) return error.NotADir;
        return node.vtable.file_read_dir(file, record);
    }
};

pub const Mount = struct {
    target: ?Path,
    src: *DirEntry,
    /// open path count + sub mount count
    ref_count: std.atomic.Value(u32),

    pub fn acquire(mount: *Mount) void {
        _ = mount.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(mount: *Mount) void {
        const prev = mount.ref_count.fetchSub(1, .release);
        std.debug.assert(prev != 0);
    }

    pub fn acquireRootPath(mount: *Mount) Path {
        const path: Path = .{
            .mount = mount,
            .dentry = mount.src,
        };

        path.acquire();
        return path;
    }

    pub fn mountOnto(mount: *Mount, target: Path) !void {
        if (mount.target != null) return error.AlreadyMounted;
        if (target.dentry == target.mount.src) return error.Busy;
        if (target.dentry.node.kind != .dir) return error.NotADir;

        const lock = mounts_lock.lock();
        defer lock.unlock();

        const res = try mounts.getOrPut(alloc, target);
        if (res.found_existing) return error.Busy;
        res.value_ptr.* = mount;

        mount.target = target;
        target.acquire();
    }
};

pub const Path = struct {
    mount: *Mount,
    dentry: *DirEntry,

    pub fn acquire(path: Path) void {
        path.mount.acquire();
        path.dentry.acquire();
    }

    pub fn release(path: Path) void {
        path.dentry.release();
        path.mount.release();
    }

    pub fn lookupName(parent: Path, name: []const u8) Error!Path {
        if (name.len == 0) return error.NoEntry;

        if (name[0] == '.') {
            if (name.len == 2 and name[1] == '.') {
                if (parent.mount.src == parent.dentry) {
                    const target = parent.mount.target orelse return error.NoParent;
                    const dentry = target.dentry.parent orelse return error.NoParent;
                    const path: Path = .{
                        .mount = target.mount,
                        .dentry = dentry,
                    };

                    path.acquire();
                    return path;
                }

                const dentry = parent.dentry.parent orelse return error.NoParent;
                const path: Path = .{
                    .mount = parent.mount,
                    .dentry = dentry,
                };

                path.acquire();
                return path;
            } else if (name.len == 1) {
                parent.acquire();
                return parent;
            }
        }

        const direct = try parent.dentry.lookupNameLocal(name);
        const direct_path: Path = .{
            .mount = parent.mount,
            .dentry = direct,
        };

        const lock = mounts_lock.lock();
        defer lock.unlock();

        if (mounts.get(direct_path)) |mount| {
            const new = mount.acquireRootPath();
            direct.release();
            return new;
        }

        parent.mount.acquire();
        return direct_path;
    }

    pub fn lookup(parent: Path, path: []const u8) Error!Path {
        if (path.len == 0) return error.NoEntry;

        var current = parent;
        var should_release: bool = false;
        errdefer if (should_release) current.release();

        if (path[0] == '/') {
            if (root == null) return error.NoParent;
            current = root.?.acquireRootPath();
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

    pub fn open(path: Path) Error!*File {
        const node = path.dentry.node;
        const file = try node.vtable.file_open(node);
        file.path = path;
        path.acquire();
        return file;
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

pub fn nodeDestroyPanic(_: *Node) void {
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

pub fn fileOpenDefault(_: *Node) Error!*File {
    const file = try alloc.create(File);
    file.* = .{
        .path = undefined,
        .head = 0,
    };
    return file;
}

pub fn fileCloseDefault(file: *File) void {
    alloc.destroy(file);
}

pub fn fileReadDirInCache(file: *File, record: *DirRecord) Error!bool {
    const node = file.path.dentry.node;
    node.mutex.lock();
    defer node.mutex.unlock();

    var lowest: ?*DirEntry = null;
    var iter = node.data.dir.entries.iterator();
    while (iter.next()) |kv| {
        const entry = kv.value_ptr.*;
        const addr = @intFromPtr(entry);
        if (addr > file.head and (lowest == null or addr < @intFromPtr(lowest.?)))
            lowest = entry;
    }

    const entry = lowest orelse return false;
    const name = entry.name.get();

    record.* = .{
        .kind = entry.node.kind,
        .name_len = @intCast(name.len),
        .name_buf = undefined,
    };

    @memcpy(record.name_buf[0..name.len], name);
    @memset(record.name_buf[name.len..], 0);

    file.head = @intFromPtr(entry);
    return true;
}

pub fn fileReadDirNotSupported(file: *File, _: *DirRecord) Error!bool {
    std.debug.assert(file.path.dentry.node.kind == .dir);
    return error.NotSupported;
}
