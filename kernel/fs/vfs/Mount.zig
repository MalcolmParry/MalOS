const std = @import("std");
const Spinlock = @import("../../sync/Spinlock.zig");
const Node = @import("Node.zig");
const DirEntry = @import("DirEntry.zig");
const alloc = @import("../../heap/gpa.zig").allocator;
const Mount = @This();

const vfs = @import("vfs.zig");
const Error = vfs.Error;

var mounts: std.AutoHashMapUnmanaged(Path, *Mount) = .empty;
var mounts_lock: Spinlock = .init;

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

pub fn unmount(mount: *Mount) Error!void {
    if (mount == vfs.root) return error.Busy;

    {
        const lock = mounts_lock.lock();
        defer lock.unlock();

        if (mount.ref_count.load(.monotonic) != 0) return error.Busy;
        if (mount.target) |x| {
            std.debug.assert(mounts.remove(x));
        }
    }

    if (mount.target) |x| x.release();

    const sb = mount.src.node.sb;
    mount.src.release();
    alloc.destroy(mount);

    const prev = sb.mount_count.fetchSub(1, .release);
    std.debug.assert(prev != 0);
    if (prev == 1) {
        _ = sb.mount_count.load(.acquire);
        sb.destroy();
    }
}

/// not thread safe
pub fn makeOrphan(mount: *Mount) void {
    const target = mount.target orelse return;
    mount.target = null;
    std.debug.assert(mounts.remove(target));
    target.release();
}

pub fn acquireRootPath(mount: *Mount) Path {
    const path: Path = .{
        .mount = mount,
        .dentry = mount.src,
    };

    path.acquire();
    return path;
}

pub fn create(src: *DirEntry) !*Mount {
    const m = try alloc.create(Mount);
    m.* = .{
        .target = null,
        .src = src,
        .ref_count = .init(0),
    };

    src.acquire();
    _ = src.node.sb.mount_count.fetchAdd(1, .acquire);
    return m;
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
        if (parent.dentry.node.kind != .dir) return error.NotADir;
        if (name.len == 0) return error.NoEntry;
        if (name.len > vfs.max_name_len) return error.NameTooLong;

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
            const root = vfs.root orelse return error.NoParent;
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

    pub fn open(path: Path) Error!File {
        const handle = try path.dentry.node.open();
        path.acquire();
        return .{
            .handle = handle,
            .path = path,
        };
    }
};

pub const File = struct {
    handle: *Node.Handle,
    path: Path,

    pub fn acquire(file: File) void {
        file.path.acquire();
        file.handle.acquire();
    }

    pub fn release(file: File) void {
        file.handle.release();
        file.path.release();
    }

    pub fn read(file: File, offset: u64, buffer: []u8) Error!usize {
        return file.handle.read(offset, buffer);
    }

    pub fn write(file: File, offset: u64, buffer: []const u8) Error!usize {
        return file.handle.write(offset, buffer);
    }

    pub fn readDir(file: File, pos: u64, record: *Node.DirRecord) Error!?u64 {
        return file.handle.readDir(pos, record);
    }

    pub fn reader(file: File, buffer: []u8) Node.Handle.Reader {
        return file.handle.reader(buffer);
    }
};
