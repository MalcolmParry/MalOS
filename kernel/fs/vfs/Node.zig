//! represents an object in the filesystem
//! such as a file or directory

const std = @import("std");
const mem = @import("../../memory.zig");
const pmm = @import("../../pmm.zig");
const Spinlock = @import("../../sync/Spinlock.zig");
const Mutex = @import("../../sync/Mutex.zig");
const BlockDevice = @import("../../block/BlockDevice.zig");
const alloc = @import("../../heap/gpa.zig").allocator;
const DirEntry = @import("DirEntry.zig");
const Node = @This();

const vfs = @import("vfs.zig");
const SuperBlock = vfs.SuperBlock;
const Error = vfs.Error;

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
    destroy: *const fn (node: *Node) void,
    lookup: *const fn (parent: *Node, name: []const u8) Error!*Node = &default_impls.lookupNoEntry,
    create: *const fn (parent: *Node, name: []const u8, opts: CreateOptions) Error!*Node = &default_impls.createReadOnly,
    unlink: *const fn (parent: *Node, name: []const u8) Error!void = &default_impls.unlinkReadOnly,

    /// assumes caller already locked the page
    read_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &default_impls.readPageZero,
    /// assumes caller already locked the page
    write_page: *const fn (node: *Node, page_offset: u32, page: pmm.Index) Error!void = &default_impls.writePageNoop,
    /// assumes caller has the node lock
    /// shouldn't touch the page cache, the vfs handles that
    resize: ?*const fn (node: *Node, new_size: usize) Error!void = null,

    open: *const fn (node: *Node) Error!*Handle = &Handle.default_impls.OpenDefault(&.{}),
};

pub const DirRecord = struct {
    kind: Kind,
    name_len: u8,
    name_buf: [vfs.max_name_len]u8,

    pub fn getName(record: *const DirRecord) []const u8 {
        return record.name_buf[0..record.name_len];
    }
};

pub const CreateOptions = struct {
    kind: Node.Kind,
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

pub fn open(node: *Node) Error!*Handle {
    const handle = try node.vtable.open(node);
    node.acquire();
    return handle;
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

    node.vtable.destroy(node);
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

    try node.vtable.read_page(node, page_offset, index);

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

pub const Handle = struct {
    /// immutable
    node: *Node,
    /// immutable
    vtable: *const Handle.VTable,
    cur: u64,

    pub const VTable = struct {
        close: *const fn (handle: *Handle) void = &Handle.default_impls.closeDefault,
        read: ?*const fn (handle: *Handle, buffer: []u8) Error!usize = null,
        write: ?*const fn (handle: *Handle, data: []const u8) Error!usize = null,
        /// returns true if wrote to record
        read_dir: *const fn (handle: *Handle, record: *DirRecord) Error!bool = &Handle.default_impls.readDirNotSupported,
    };

    pub fn close(handle: *Handle) void {
        const node = handle.node;
        handle.vtable.close(handle);
        node.release();
    }

    pub fn read(handle: *Handle, buffer: []u8) Error!usize {
        const node = handle.node;
        if (node.kind != .file) return error.NotAFile;
        if (handle.vtable.read) |func| return func(handle, buffer);

        const lock = node.lock.lock();
        defer lock.unlock();

        const file_data = &node.data.file;
        const end = @min(handle.cur + buffer.len, file_data.size);
        if (end <= handle.cur) return 0;

        var cur = handle.cur;
        var bytes_read: usize = 0;
        while (cur < end) {
            const page_offset: u32 = @intCast(cur / mem.page_size);

            const page_index, const page_lock = try node.getOrCreatePage(page_offset);
            defer page_lock.unlock();

            const direct = page_index.toDirectMap();
            const head_offset_from_page = cur % mem.page_size;
            const end_offset_from_page = @min(end - (@as(usize, page_offset) * mem.page_size), mem.page_size);
            const to_read = end_offset_from_page - head_offset_from_page;

            @memcpy(buffer[bytes_read..][0..to_read], direct.bytes[head_offset_from_page..end_offset_from_page]);

            cur += to_read;
            bytes_read += to_read;
        }

        handle.cur = cur;
        return bytes_read;
    }

    pub fn readDir(handle: *Handle, record: *DirRecord) Error!bool {
        if (handle.node.kind != .dir) return error.NotADir;
        return handle.vtable.read_dir(handle, record);
    }

    pub fn reader(handle: *Handle, buffer: []u8) Reader {
        return .{
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .stream = &Reader.stream },
                .end = 0,
                .seek = 0,
            },
            .handle = handle,
        };
    }

    pub const default_impls = struct {
        pub fn OpenDefault(comptime vtable: *const Handle.VTable) fn (node: *Node) Error!*Handle {
            return struct {
                fn open(node: *Node) Error!*Handle {
                    const handle = try alloc.create(Handle);
                    handle.* = .{
                        .node = node,
                        .vtable = vtable,
                        .cur = 0,
                    };
                    return handle;
                }
            }.open;
        }

        pub fn closeDefault(handle: *Handle) void {
            alloc.destroy(handle);
        }

        pub fn readDirInCache(handle: *Handle, record: *DirRecord) Error!bool {
            const node = handle.node;
            node.mutex.lock();
            defer node.mutex.unlock();

            var lowest: ?*DirEntry = null;
            var iter = node.data.dir.entries.iterator();
            while (iter.next()) |kv| {
                const entry = kv.value_ptr.*;
                const addr = @intFromPtr(entry);
                if (addr > handle.cur and (lowest == null or addr < @intFromPtr(lowest.?)))
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

            handle.cur = @intFromPtr(entry);
            return true;
        }

        pub fn readDirNotSupported(handle: *Handle, _: *DirRecord) Error!bool {
            std.debug.assert(handle.node.kind == .dir);
            return error.NotSupported;
        }
    };

    pub const Reader = struct {
        interface: std.Io.Reader,
        handle: *Handle,

        pub fn logicalPos(r: *const Reader) u64 {
            return r.handle.cur - r.interface.bufferedLen();
        }

        pub fn seekTo(r: *Reader, pos: u64) void {
            const logical_pos = r.logicalPos();
            if (pos < logical_pos or pos >= r.handle.cur) {
                r.interface.tossBuffered();
                r.handle.cur = pos;
            } else r.interface.toss(pos - logical_pos);
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const this: *Reader = @fieldParentPtr("interface", r);
            const dest = limit.slice(try w.writableSliceGreedy(1));

            const n = this.handle.read(dest) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;

            w.advance(n);
            return n;
        }
    };
};

pub const default_impls = struct {
    pub fn destroyPanic(_: *Node) void {
        @panic("not implemented");
    }

    pub fn readPageZero(_: *Node, _: u32, index: pmm.Index) Error!void {
        const direct = index.toDirectMap();
        @memset(direct.bytes[0..], 0);
    }

    pub fn writePageNoop(_: *Node, _: u32, _: pmm.Index) Error!void {}

    pub fn lookupNoEntry(parent: *Node, _: []const u8) Error!*Node {
        std.debug.assert(parent.kind == .dir);
        return error.NoEntry;
    }

    pub fn createReadOnly(parent: *Node, _: []const u8, _: CreateOptions) Error!*Node {
        std.debug.assert(parent.kind == .dir);
        return error.ReadOnly;
    }

    pub fn unlinkReadOnly(parent: *Node, _: []const u8) Error!void {
        std.debug.assert(parent.kind == .dir);
        return error.ReadOnly;
    }
};
