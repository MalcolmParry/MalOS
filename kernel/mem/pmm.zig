const std = @import("std");
const builtin = @import("builtin");
const mem = @import("memory.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const boot_info = @import("../boot_info.zig");
const assert = std.debug.assert;
const debug = builtin.mode.runtimeSafety();

pub var total_pages: usize = 0;
pub var used_pages: std.atomic.Value(usize) = .init(0);

var next_bump_alloc: std.atomic.Value(usize) = .init(0);
var largest_bump_alloc: u32 = 0;

var init_free_ranges_buffer: [16][]mem.PhysPage = undefined;
var init_free_ranges: std.ArrayList([]mem.PhysPage) = .initBuffer(&init_free_ranges_buffer);

var spinlock: Spinlock = .init;
var maybe_first_free: OptIndex = .none;

pub fn init() void {
    init_free_ranges.appendSliceBounded(boot_info.available_phys_ranges.items) catch @panic("too many ranges");
    reserveAvailableRegion(boot_info.kernel_phys_range);
    for (boot_info.modules.items) |module| {
        reserveAvailableRegion(module.data);
    }

    for (&boot_info.elf_sections.values) |maybe_section| {
        const section = maybe_section orelse continue;
        reserveAvailableRegion(section.data);
    }

    for (boot_info.available_phys_ranges.items) |range| {
        total_pages += range.len;
    }

    // done as a hack so that early allocations are below 4gb
    // TODO: add proper way to allocate below 4gb
    std.mem.sort([]mem.PhysPage, init_free_ranges.items, {}, struct {
        fn lessThan(_: void, left: []mem.PhysPage, right: []mem.PhysPage) bool {
            return @intFromPtr(left.ptr) < @intFromPtr(right.ptr);
        }
    }.lessThan);

    var free_pages: usize = 0;
    for (init_free_ranges.items) |range| {
        free_pages += range.len;
    }
    used_pages.raw = total_pages - free_pages;
    largest_bump_alloc = @intCast(free_pages);
}

pub fn allocPage() !Index {
    if (next_bump_alloc.load(.monotonic) < largest_bump_alloc) {
        const bump_alloc = next_bump_alloc.fetchAdd(1, .monotonic);
        if (bump_alloc < largest_bump_alloc) {
            var offset: usize = 0;
            for (init_free_ranges.items) |range| {
                if (offset + range.len > bump_alloc) {
                    _ = used_pages.fetchAdd(1, .monotonic);
                    return .fromPtr(&range[bump_alloc - offset]);
                }

                offset += range.len;
            }

            unreachable;
        }
    }

    const lock = spinlock.lock();
    defer lock.unlock();

    if (maybe_first_free.unwrap()) |first_free| {
        const desc: *FreeDesc = @ptrCast(first_free.toDirectMap());
        maybe_first_free = desc.next;

        if (debug) {
            assert(desc.magic == FreeDesc.magic_num);
            desc.magic = 0;
        }

        _ = used_pages.fetchAdd(1, .monotonic);
        return first_free;
    }

    return error.OutOfMemory;
}

pub fn allocPageZeroed() !Index {
    const page = try allocPage();
    @memset(&page.toDirectMap().bytes, 0);
    return page;
}

pub fn freePage(page: Index) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    const desc: *FreeDesc = @ptrCast(page.toDirectMap());
    if (debug and desc.magic == FreeDesc.magic_num) {
        // TODO: get used bitmap in debug mode
        std.log.warn("double free at 0x{x}", .{page.toAddr()});
    }

    desc.* = .{ .next = maybe_first_free };
    maybe_first_free = .wrap(page);
    _ = used_pages.fetchSub(1, .monotonic);
}

const FreeDesc = struct {
    next: OptIndex,
    magic: if (debug) usize else void = if (debug) magic_num else {},

    const magic_num = 0x1234_5678_9abc;
};

var zero_page_virt: mem.Page = .{ .bytes = @splat(0) };
var one_page_virt: mem.Page = .{ .bytes = @splat(0xff) };

pub fn zeroPage() Index {
    return .fromAddr(@intFromPtr(&zero_page_virt) - mem.kernel_virt_base);
}

pub fn onePage() Index {
    return .fromAddr(@intFromPtr(&one_page_virt) - mem.kernel_virt_base);
}

pub const Index = enum(u32) {
    _,

    pub fn fromPtr(ptr: *mem.PhysPage) Index {
        return fromAddr(@intFromPtr(ptr));
    }

    pub fn toPtr(index: Index) *mem.PhysPage {
        return @ptrFromInt(index.toAddr());
    }

    pub fn fromAddr(addr: usize) Index {
        return @fromBackingInt(@intCast(addr / mem.page_size));
    }

    pub fn toAddr(index: Index) usize {
        return @as(usize, @backingInt(index)) * mem.page_size;
    }

    pub fn toDirectMap(index: Index) *mem.Page {
        return &mem.direct_map[@backingInt(index)];
    }

    pub fn fromDirect(direct: *mem.Page) Index {
        return .fromAddr(@intFromPtr(direct) - mem.direct_map_base);
    }
};

pub const OptIndex = enum(u32) {
    none = 0,
    _,

    pub inline fn wrap(maybe_index: ?Index) OptIndex {
        if (maybe_index) |index| {
            assert(@backingInt(index) != 0);
            return @fromBackingInt(@backingInt(index));
        } else {
            return .none;
        }
    }

    pub inline fn unwrap(opt_index: OptIndex) ?Index {
        return if (opt_index == .none) null else @fromBackingInt(@backingInt(opt_index));
    }
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
