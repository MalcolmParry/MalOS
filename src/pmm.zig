const std = @import("std");
const builtin = @import("builtin");
const mem = @import("memory.zig");
const Spinlock = @import("Spinlock.zig");
const BootInfo = @import("BootInfo.zig");
const debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

pub var total_pages: usize = 0;
pub var used_pages: std.atomic.Value(usize) = .init(0);
pub var reclaimable_pages: std.atomic.Value(usize) = .init(0);

var next_bump_alloc: std.atomic.Value(usize) = .init(0);
var largest_bump_alloc: u32 = 0;

var init_free_ranges_buffer: [16][]mem.PhysPage = undefined;
var init_free_ranges: std.ArrayList([]mem.PhysPage) = .initBuffer(&init_free_ranges_buffer);

var spinlock: Spinlock = .init;
var page_descs: []PageDesc = &.{};
var maybe_first_free: OptIndex = .none;
var maybe_first_reclaimable: OptIndex = .none;

pub fn tempInit(boot_info: *const BootInfo) void {
    init_free_ranges.appendSliceBounded(boot_info.availablePhysRanges()) catch @panic("too many ranges");
    reserveAvailableRegion(boot_info.kernel_phys_range);
    for (boot_info.modules()) |module| {
        reserveAvailableRegion(module.phys_range);
    }

    for (boot_info.availablePhysRanges()) |range| {
        total_pages += range.len;
    }

    var free_pages: usize = 0;
    for (init_free_ranges.items) |range| {
        free_pages += range.len;
    }
    used_pages.raw = total_pages - free_pages;
    largest_bump_alloc = @intCast(free_pages);
}

pub fn init(boot_info: *const BootInfo, alloc: std.mem.Allocator) void {
    const desc_count = @intFromPtr(boot_info.max_phys_addr) / mem.page_size;
    page_descs = alloc.alloc(PageDesc, desc_count) catch @panic("cant allocate physical page descs");

    @memset(page_descs, .{
        .next = .none,
        .prev = .none,
        .gen_state = .init(.{
            .gen = 0,
            .state = .used,
        }),
    });
}

pub fn allocPage() !*mem.PhysPage {
    if (bumpAllocPage()) |page| return page;

    const lock = spinlock.lock();
    defer lock.unlock();

    if (maybe_first_free.unwrap()) |first_free| {
        @branchHint(.likely);

        const desc = &page_descs[@intFromEnum(first_free)];
        maybe_first_free = desc.next;

        const gen_state = desc.gen_state.load(.monotonic);
        std.debug.assert(gen_state.state == .free);

        desc.* = .{
            .next = .none,
            .prev = .none,
            .gen_state = .init(.{
                .gen = gen_state.gen,
                .state = .used,
            }),
        };

        _ = used_pages.fetchAdd(1, .monotonic);
        return first_free.toPtr();
    }

    var maybe_reclaimable = maybe_first_reclaimable;
    while (maybe_reclaimable.unwrap()) |index| {
        const desc = &page_descs[@intFromEnum(index)];
        const gen_state = desc.gen_state.load(.monotonic);

        if (desc.gen_state.cmpxchgStrong(
            .{ .gen = gen_state.gen, .state = .reclaimable },
            .{ .gen = gen_state.gen +% 1, .state = .free },
            .acquire,
            .monotonic,
        ) != null) {
            maybe_reclaimable = desc.next;
            continue;
        }

        if (desc.prev.unwrap()) |prev_index| {
            @branchHint(.likely);
            const prev = &page_descs[@intFromEnum(prev_index)];
            prev.next = desc.next;
        }

        if (desc.next.unwrap()) |next_index| {
            @branchHint(.likely);
            const next = &page_descs[@intFromEnum(next_index)];
            next.prev = desc.prev;
        }

        if (maybe_first_reclaimable.unwrapAssert() == index) {
            maybe_first_reclaimable = desc.next;
        }

        desc.* = .{
            .next = maybe_first_free,
            .prev = .none,
            .gen_state = .init(.{
                .gen = gen_state.gen +% 1,
                .state = .used,
            }),
        };

        _ = reclaimable_pages.fetchSub(1, .monotonic);
        _ = used_pages.fetchAdd(1, .monotonic);
        return index.toPtr();
    }

    return error.OutOfMemory;
}

inline fn bumpAllocPage() ?*mem.PhysPage {
    if (next_bump_alloc.load(.monotonic) >= largest_bump_alloc) {
        @branchHint(.likely);
        return null;
    }

    const bump_alloc = next_bump_alloc.fetchAdd(1, .monotonic);
    if (bump_alloc >= largest_bump_alloc) {
        @branchHint(.unlikely);
        return null;
    }

    var offset: usize = 0;
    for (init_free_ranges.items) |range| {
        if (offset + range.len > bump_alloc) {
            const page_index = bump_alloc - offset;

            if (page_descs.len != 0) {
                @branchHint(.likely);

                const desc = &page_descs[page_index];
                desc.* = .{
                    .next = .none,
                    .prev = .none,
                    .gen_state = .init(.{
                        .gen = 0,
                        .state = .used,
                    }),
                };
            }

            _ = used_pages.fetchAdd(1, .monotonic);
            return &range[page_index];
        }

        offset += range.len;
    }

    unreachable;
}

pub fn freePage(page: *mem.PhysPage) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];
    const gen_state = desc.gen_state.load(.monotonic);
    std.debug.assert(gen_state.state == .used);

    desc.* = .{
        .next = maybe_first_free,
        .prev = .none,
        .gen_state = .init(.{
            .gen = gen_state.gen,
            .state = .free,
        }),
    };

    maybe_first_free = .wrap(desc_index);
    _ = used_pages.fetchSub(1, .monotonic);
}

/// unlockReclaimable must be called after
/// returns generation counter
pub fn markReclaimable(page: *mem.PhysPage) PageDesc.Gen {
    const lock = spinlock.lock();
    defer lock.unlock();

    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];
    const gen_state = desc.gen_state.load(.monotonic);
    std.debug.assert(gen_state.state == .used);

    if (maybe_first_reclaimable.unwrap()) |other_index| {
        @branchHint(.likely);
        const other = &page_descs[@intFromEnum(other_index)];
        other.prev = .wrap(desc_index);
    }

    desc.* = .{
        .next = maybe_first_reclaimable,
        .prev = .none,
        .gen_state = .init(.{
            .gen = gen_state.gen,
            .state = .reclaimable_locked,
        }),
    };

    _ = used_pages.fetchSub(1, .monotonic);
    _ = reclaimable_pages.fetchAdd(1, .monotonic);
    maybe_first_reclaimable = .wrap(desc_index);
    return gen_state.gen;
}

pub fn freeReclaimable(page: *mem.PhysPage, gen: PageDesc.Gen) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];

    const gen_state = desc.gen_state.load(.monotonic);
    if (gen_state.gen != gen) return;
    switch (gen_state.state) {
        .reclaimable, .reclaimable_locked => {},
        else => unreachable,
    }

    if (desc.prev.unwrap()) |prev_index| {
        @branchHint(.likely);
        const prev = &page_descs[@intFromEnum(prev_index)];
        prev.next = desc.next;
    }

    if (desc.next.unwrap()) |next_index| {
        @branchHint(.likely);
        const next = &page_descs[@intFromEnum(next_index)];
        next.prev = desc.prev;
    }

    desc.* = .{
        .next = maybe_first_free,
        .prev = .none,
        .gen_state = .init(.{
            .gen = gen_state.gen,
            .state = .free,
        }),
    };

    _ = reclaimable_pages.fetchSub(1, .monotonic);
    maybe_first_free = .wrap(desc_index);
}

/// returns false if page has already been reclaimed
pub fn lockReclaimable(page: *mem.PhysPage, gen: PageDesc.Gen) bool {
    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];

    return desc.gen_state.cmpxchgStrong(
        .{ .gen = gen, .state = .reclaimable },
        .{ .gen = gen, .state = .reclaimable_locked },
        .acquire,
        .monotonic,
    ) == null;
}

pub fn unlockReclaimable(page: *mem.PhysPage) void {
    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];
    const gen_state = desc.gen_state.load(.monotonic);
    std.debug.assert(gen_state.state == .reclaimable_locked);

    desc.gen_state.store(.{
        .gen = gen_state.gen,
        .state = .reclaimable,
    }, .release);
}

pub const Index = enum(u32) {
    _,

    pub fn fromPtr(ptr: *mem.PhysPage) Index {
        return @enumFromInt(@intFromPtr(ptr) / mem.page_size);
    }

    pub fn toPtr(index: Index) *mem.PhysPage {
        return @ptrFromInt(@intFromEnum(index) * mem.page_size);
    }
};

pub const OptIndex = enum(u32) {
    none = 0,
    _,

    pub inline fn wrap(maybe_index: ?Index) OptIndex {
        if (maybe_index) |index| {
            std.debug.assert(@intFromEnum(index) != 0);
            return @enumFromInt(@intFromEnum(index));
        } else {
            return .none;
        }
    }

    pub inline fn unwrap(opt_index: OptIndex) ?Index {
        return if (opt_index == .none) null else opt_index.unwrapAssert();
    }

    pub inline fn unwrapAssert(opt_index: OptIndex) Index {
        std.debug.assert(opt_index != .none);
        return @enumFromInt(@intFromEnum(opt_index));
    }
};

const PageDesc = struct {
    gen_state: std.atomic.Value(GenState),
    next: OptIndex,
    /// only used for reclaimable pages
    prev: OptIndex,

    const Gen = u28;
    const GenState = packed struct(u32) {
        /// incremented when reclaimed
        gen: Gen,
        state: State,
    };

    const State = enum(u4) {
        free,
        used,
        reclaimable,
        reclaimable_locked,
    };
};

fn reserveAvailableRegion(reserved: []mem.Phys(u8)) void {
    const res_aligned = mem.physPageAlignOutwards(reserved);
    const res_end = res_aligned.ptr + res_aligned.len;

    var i: u32 = 0;
    while (i < init_free_ranges.items.len) {
        const range = init_free_ranges.items[i];
        var start = range.ptr;
        var end = range.ptr + range.len;

        if (mem.addrInSlice([]mem.PhysPage, res_aligned, start))
            start = res_end;

        if (mem.addrInSlice([]mem.PhysPage, res_aligned, end))
            end = res_aligned.ptr;

        if (@intFromPtr(start) >= @intFromPtr(end)) {
            _ = init_free_ranges.swapRemove(i);
            continue;
        }

        const len = (@intFromPtr(end) - @intFromPtr(start)) / mem.page_size;
        const new_range = start[0..len];

        if (mem.addrInSlice([]mem.PhysPage, new_range, res_aligned.ptr)) {
            const add_len = (@intFromPtr(end) - @intFromPtr(res_end)) / mem.page_size;
            const additional = res_end[0..add_len];

            init_free_ranges.appendBounded(additional) catch @panic("not enough memory ranges");
            end = res_aligned.ptr;
        }

        init_free_ranges.items[i] = mem.fromStartAndEnd([]mem.PhysPage, start, end);
        i += 1;
    }
}

pub fn printStats() void {
    const used = used_pages.load(.monotonic);
    const reclaimable = reclaimable_pages.load(.monotonic);

    std.log.info("Used:        {Bi: >4.2} / {Bi}", .{ used * mem.page_size, total_pages * mem.page_size });
    std.log.info("Reclaimable: {Bi: >4.2} / {Bi}", .{ reclaimable * mem.page_size, total_pages * mem.page_size });
    std.log.info("Available:   {Bi: >4.2} / {Bi}", .{ (total_pages - used) * mem.page_size, total_pages * mem.page_size });
    std.log.info("Free:        {Bi:0>4.2} / {Bi}", .{ (total_pages - used - reclaimable) * mem.page_size, total_pages * mem.page_size });
}
