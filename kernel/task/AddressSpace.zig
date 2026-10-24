const std = @import("std");
const mem = @import("../memory.zig");
const arch = @import("../arch/arch.zig").current;
const gpa = @import("../heap/gpa.zig").allocator;
const Spinlock = @import("../sync/Spinlock.zig");
const AddressSpace = @This();

table: *arch.paging.Table,
ref_count: std.atomic.Value(u32),
first_region: ?*Region,
lock: Spinlock,

pub fn acquire(as: *AddressSpace) void {
    const prev = as.ref_count.fetchAdd(1, .monotonic);
    std.debug.assert(prev != 0);
}

pub fn release(as: *AddressSpace) void {
    const prev = as.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(prev != 0);
    if (prev == 1) as.destroy();
}

pub fn create() !*AddressSpace {
    const as = try gpa.create(AddressSpace);
    errdefer gpa.destroy(as);

    const table = try arch.paging.createTable();

    as.* = .{
        .table = table,
        .ref_count = .init(1),
        .first_region = null,
        .lock = .init,
    };

    return as;
}

pub fn destroy(as: *AddressSpace) void {
    var maybe_region = as.first_region;
    while (maybe_region) |region| {
        if (region.flags.alloc)
            arch.paging.unmapAndFreeRegion(as.table, region.first_page, region.page_len);

        maybe_region = region.next;
        gpa.destroy(region);
    }

    arch.paging.destroyTable(as.table);
    gpa.destroy(as);
}

/// assumes lock is held
pub fn find(as: *AddressSpace, page_index: usize) ?*Region {
    var maybe_region = as.first_region;
    while (maybe_region) |region| : (maybe_region = region.next) {
        if (region.first_page > page_index) return null;
        if (page_index - region.first_page < region.page_len) return region;
    }

    return null;
}

/// assumes lock is held
/// returns virtual page index
pub fn findGap(as: *AddressSpace, page_count: usize, hint: ?usize) ?usize {
    _ = hint;

    const min_page = 1024 * 1024 / mem.page_size;
    const max_page = arch.paging.max_user_addr / mem.page_size;

    var gap_start: usize = min_page;
    var maybe_region = as.first_region;
    while (maybe_region) |region| : (maybe_region = region.next) {
        if (region.first_page > gap_start and region.first_page - gap_start >= page_count) {
            return gap_start;
        }

        gap_start = @max(gap_start, region.first_page + region.page_len);
    }

    if (max_page > gap_start and max_page - gap_start >= page_count) return gap_start;
    return null;
}

/// assumes lock is held
pub fn map(as: *AddressSpace, first_page: usize, page_count: usize, flags: Region.Flags) !void {
    const region = try gpa.create(Region);
    errdefer gpa.destroy(region);

    try as.unmap(first_page, page_count);

    if (flags.alloc)
        try arch.paging.mapAndAllocRegion(as.table, first_page, page_count, .{
            .global = false,
            .executable = flags.x,
            .cache_mode = .full,
            .user = true,
            .writable = flags.w,
        }, true);
    errdefer if (flags.alloc) arch.paging.unmapAndFreeRegion(as.table, first_page, page_count);

    var maybe_prev: ?*Region = null;
    var maybe_next = as.first_region;
    while (maybe_next) |next| : ({
        maybe_prev = maybe_next;
        maybe_next = next.next;
    }) {
        if (next.first_page > first_page) break;
    }

    region.* = .{
        .next = maybe_next,
        .first_page = first_page,
        .page_len = page_count,
        .flags = flags,
    };

    if (maybe_prev) |prev| {
        prev.next = region;
    } else {
        as.first_region = region;
    }
}

/// assumes lock is held
pub fn unmap(as: *AddressSpace, first_page: usize, page_count: usize) !void {
    _ = as;
    _ = first_page;
    _ = page_count;
}

pub const Region = struct {
    next: ?*Region,
    first_page: usize,
    page_len: usize,
    flags: Flags,

    pub const Flags = packed struct {
        w: bool,
        x: bool,
        alloc: bool,
    };
};
