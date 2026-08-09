const std = @import("std");
const builtin = @import("builtin");
const mem = @import("memory.zig");
const Spinlock = @import("Spinlock.zig");
const debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

var available_ranges_buffer: [16][]mem.PhysPage = undefined;
var init_free_ranges_buffer: [16][]mem.PhysPage = undefined;

pub var kernel_range: []mem.Phys(u8) = undefined;
pub var available_ranges: std.ArrayList([]mem.PhysPage) = .initBuffer(&available_ranges_buffer);
var init_free_ranges: std.ArrayList([]mem.PhysPage) = .initBuffer(&init_free_ranges_buffer);

pub var total_pages: usize = 0;
pub var used_pages: std.atomic.Value(usize) = .init(0);

var next_bump_alloc: std.atomic.Value(usize) = .init(0);
var largest_bump_alloc: u32 = 0;

var spinlock: Spinlock = .init;
var page_descs: []PageDesc = &.{};
var maybe_first_free: OptIndex = .none;

pub fn tempInit() void {
    init_free_ranges.appendSliceBounded(available_ranges.items) catch @panic("too many ranges");
    reserveAvailableRegion(kernel_range);
    for (mem.modules.items) |module| {
        reserveAvailableRegion(module.phys_range);
    }

    for (available_ranges.items) |range| {
        total_pages += range.len;
    }

    var free_pages: usize = 0;
    for (init_free_ranges.items) |range| {
        free_pages += range.len;
    }
    used_pages.raw = total_pages - free_pages;
    largest_bump_alloc = @intCast(free_pages);
}

pub fn init(alloc: std.mem.Allocator) void {
    var highest: [*]allowzero mem.PhysPage = @ptrFromInt(0);
    for (available_ranges.items) |range| {
        const end = range.ptr + range.len;
        if (@intFromPtr(highest) < @intFromPtr(end)) {
            highest = end;
        }
    }

    const desc_count = @intFromPtr(highest) / mem.page_size;
    page_descs = alloc.alloc(PageDesc, desc_count) catch @panic("cant allocate physical page descs");
}

pub fn allocatePage() !*mem.PhysPage {
    if (next_bump_alloc.load(.monotonic) < largest_bump_alloc) {
        const bump_alloc = next_bump_alloc.fetchAdd(1, .monotonic);
        if (bump_alloc < largest_bump_alloc) {
            var offset: usize = 0;
            for (init_free_ranges.items) |range| {
                if (offset + range.len > bump_alloc) {
                    _ = used_pages.fetchAdd(1, .monotonic);
                    return &range[bump_alloc - offset];
                }

                offset += range.len;
            }

            unreachable;
        }
    }

    const lock = spinlock.lock();
    defer lock.unlock();

    if (maybe_first_free.unwrap()) |first_free| {
        const desc = &page_descs[@intFromEnum(first_free)];
        maybe_first_free = desc.next;

        if (debug) {
            std.debug.assert(desc.magic == PageDesc.magic_num);
            std.debug.assert(desc.state == .free);
        }

        desc.* = .{
            .state = if (debug) .used else {},
            .next = .none,
        };

        _ = used_pages.fetchAdd(1, .monotonic);
        return first_free.toPtr();
    }

    return error.OutOfMemory;
}

pub fn freePage(page: *mem.PhysPage) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    std.debug.assert(page_descs.len != 0);
    const desc_index: Index = .fromPtr(page);
    const desc = &page_descs[@intFromEnum(desc_index)];

    if (debug and desc.magic == PageDesc.magic_num) {
        std.debug.assert(desc.state == .used);
    }

    desc.* = .{
        .next = maybe_first_free,
        .state = if (debug) .free else {},
    };
    maybe_first_free = .wrap(desc_index);
    _ = used_pages.fetchSub(1, .monotonic);
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
        return if (opt_index == .none) null else @enumFromInt(@intFromEnum(opt_index));
    }
};

const PageDesc = struct {
    next: OptIndex,

    magic: if (debug) u32 else void = if (debug) magic_num else {},
    state: if (debug) State else void,

    const magic_num: u32 = 0x6769_0420;
    const State = enum(u8) {
        free,
        used,
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
            _ = available_ranges.swapRemove(i);
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
