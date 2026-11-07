const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const mem = @import("../memory.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Spinlock = @import("../sync/Spinlock.zig");
const Vmo = @import("Vmo.zig");
const Object = @import("Object.zig");
const Vmar = @This();

obj: Object,
lock: Spinlock,
page_table: *arch.paging.Table,
first_region: ?*Region,

pub const Region = struct {
    next: ?*Region,
    vmo: *Vmo,
    first_page: usize,
    page_len: usize,
    flags: Flags,

    const Flags = packed struct {
        w: bool,
        x: bool,
    };
};

pub fn create() !*Vmar {
    const vmar = try gpa.create(Vmar);
    errdefer gpa.destroy(vmar);

    vmar.* = .{
        .obj = .{
            .kind = .vmar,
            .ref_count = .init(1),
        },
        .lock = .init,
        .page_table = try arch.paging.createTable(),
        .first_region = null,
    };
    return vmar;
}

pub fn destroy(vmar: *Vmar) void {
    std.debug.assert(vmar.obj.ref_count.load(.monotonic) == 0);

    var maybe_region = vmar.first_region;
    while (maybe_region) |region| {
        maybe_region = region.next;
        region.vmo.obj.release();
        gpa.destroy(region);
    }

    arch.paging.destroyTable(vmar.page_table);
    gpa.destroy(vmar);
}

pub fn findLocked(vmar: *Vmar, page_index: usize) ?*Region {
    var maybe_region = vmar.first_region;
    while (maybe_region) |region| : (maybe_region = region.next) {
        if (region.first_page > page_index) return null;
        if (page_index - region.first_page < region.page_len) return region;
    }

    return null;
}

/// returns virtual page index
pub fn findGapLocked(vmar: *Vmar, page_count: usize, hint: ?usize) ?usize {
    _ = hint;

    const min_page = 1024 * 1024 / mem.page_size;
    const max_page = arch.paging.max_user_addr / mem.page_size;

    var gap_start: usize = min_page;
    var maybe_region = vmar.first_region;
    while (maybe_region) |region| : (maybe_region = region.next) {
        if (region.first_page > gap_start and region.first_page - gap_start >= page_count) {
            return gap_start;
        }

        gap_start = @max(gap_start, region.first_page + region.page_len);
    }

    if (max_page > gap_start and max_page - gap_start >= page_count) return gap_start;
    return null;
}

/// assumes vmar & vmo locks are held
pub fn mapLocked(vmar: *Vmar, vmo: *Vmo, vmo_first_page: usize, first_page: usize, page_count: usize, flags: Region.Flags) !void {
    if (vmo_first_page > vmo.pageCount()) return error.OutOfRange;

    const region = try gpa.create(Region);
    errdefer gpa.destroy(region);

    try vmar.unmapLocked(first_page, page_count);

    try arch.paging.mapVmoLocked(vmar.page_table, vmo, vmo_first_page, first_page, @min(page_count, vmo.pageCount() - vmo_first_page), .{
        .global = false,
        .user = true,
        .executable = flags.x,
        .cache_mode = .full,
        .writable = flags.w,
    });

    var maybe_prev: ?*Region = null;
    var maybe_next = vmar.first_region;
    while (maybe_next) |next| : ({
        maybe_prev = maybe_next;
        maybe_next = next.next;
    }) {
        if (next.first_page > first_page) break;
    }

    vmo.obj.acquire();
    region.* = .{
        .next = maybe_next,
        .vmo = vmo,
        .first_page = first_page,
        .page_len = page_count,
        .flags = flags,
    };

    if (maybe_prev) |prev| {
        prev.next = region;
    } else {
        vmar.first_region = region;
    }
}

pub fn unmapLocked(vmar: *Vmar, first_page: usize, page_count: usize) !void {
    _ = vmar;
    _ = first_page;
    _ = page_count;
}
