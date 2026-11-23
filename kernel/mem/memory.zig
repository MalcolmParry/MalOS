const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const virt_layout = @import("virt_layout.zig");
const mem = @This();

pub const page_size = arch.page_size;
pub const page_align: std.mem.Alignment = .fromByteUnits(page_size);
pub const log2_page_size = std.math.log2(page_size);
pub const kernel_virt_base: usize = arch.layout.kernel_virt_base;
pub const direct_map: []mem.Page = getRegion(.direct_map).page_slice;
pub const direct_map_base = @intFromPtr(direct_map.ptr);

pub const PhysPage = Phys(Page);
pub const Page = extern struct {
    bytes: [page_size]u8 align(page_size),
};

comptime {
    std.debug.assert(@sizeOf(Page) == page_size);
    std.debug.assert(@alignOf(Page) == page_size);
    std.debug.assert(@sizeOf(PhysPage) == page_size);
    std.debug.assert(@alignOf(PhysPage) == page_size);
}

pub const PageFlags = packed struct {
    const CacheMode = enum(u2) {
        full,
        // for memory that is read by hardware
        write_through,
        // for io
        disabled,
    };

    cache_mode: CacheMode,
    writable: bool,
    executable: bool,
    user: bool,
    global: bool,

    pub const kernel_rw: PageFlags = .{
        .cache_mode = .full,
        .writable = true,
        .executable = false,
        .user = false,
        .global = true,
    };

    pub const mmio: PageFlags = .{
        .cache_mode = .disabled,
        .writable = true,
        .executable = false,
        .user = false,
        .global = true,
    };
};

pub const getRegion = virt_layout.get;
pub fn pageAlignForward(addr: usize) usize {
    return std.mem.alignForward(usize, addr, page_size);
}

pub fn pageAlignBackward(addr: usize) usize {
    return std.mem.alignBackward(usize, addr, page_size);
}

pub fn lengthPagesInclusive(length: usize) usize {
    return pageAlignForward(length) / page_size;
}

pub fn pageSliceFromBytesInclusive(bytes: []u8) []Page {
    const start_aligned = pageAlignBackward(@intFromPtr(bytes.ptr));
    const page_many_ptr: [*]Page = @ptrFromInt(start_aligned);
    const pages = lengthPagesInclusive(bytes.len);
    return page_many_ptr[0..pages];
}

pub fn alignInwards(T: type, x: T, alignment: u16) T {
    const Child = std.meta.Child(T);
    const start = std.mem.alignForward(usize, @intFromPtr(x.ptr), alignment);
    const end = std.mem.alignBackward(usize, @intFromPtr(&x.ptr[x.len]), alignment);
    const ptr: [*]Child = @ptrFromInt(start);
    const len = (end - start) / @sizeOf(Child);
    return ptr[0..len];
}

pub fn alignOutwards(T: type, x: T, alignment: u16) T {
    const Child = std.meta.Child(T);
    const start = std.mem.alignBackward(usize, @intFromPtr(x.ptr), alignment);
    const end = std.mem.alignForward(usize, @intFromPtr(x.ptr + x.len), alignment);
    const ptr: [*]Child = @ptrFromInt(start);
    const len = @divExact(end - start, @sizeOf(Child));
    return ptr[0..len];
}

pub fn physPageAlignOutwards(x: []Phys(u8)) []PhysPage {
    const aligned = alignOutwards([]Phys(u8), x, page_size);
    const start: [*]PhysPage = @ptrCast(@alignCast(aligned.ptr));
    return start[0..@divExact(aligned.len, page_size)];
}

pub fn fromStartAndEnd(T: type, start: anytype, end: anytype) T {
    std.debug.assert(@TypeOf(start) == @TypeOf(end));
    const len = (@intFromPtr(end) - @intFromPtr(start)) / page_size;
    return start[0..len];
}

pub fn addrInSlice(T: type, slice: T, addr: anytype) bool {
    const start = @intFromPtr(slice.ptr);
    const end = @intFromPtr(slice.ptr + slice.len);
    const addr_int: usize = switch (@typeInfo(@TypeOf(addr))) {
        .pointer => @intFromPtr(addr),
        .int => addr,
        else => @compileError("invalid type"),
    };

    return (addr_int >= start) and (addr_int < end);
}

pub fn PhysToDirectResult(T: type) type {
    const ptr_info = @typeInfo(T).pointer;
    const PhysChild = ptr_info.child;
    const Child = PhysChild.Child;
    return @Pointer(ptr_info.size, ptr_info.attrs, Child, null);
}

pub fn physToDirect(ptr: anytype) PhysToDirectResult(@TypeOf(ptr)) {
    return switch (@typeInfo(@TypeOf(ptr)).pointer.size) {
        .one, .many => @ptrFromInt(@intFromPtr(ptr) + direct_map_base),
        .slice => if (ptr.len > 0) physToDirect(ptr.ptr)[0..ptr.len] else &.{},
        .c => @compileError("not supported"),
    };
}

pub fn Phys(comptime ChildT: type) type {
    return struct {
        data: Child,

        pub const Child = ChildT;
        comptime {
            std.debug.assert(@sizeOf(@This()) == @sizeOf(Child));
            std.debug.assert(@alignOf(@This()) == @alignOf(Child));
        }
    };
}

pub fn fmtRange(range: anytype) RangeFormatter(@TypeOf(range)) {
    return .{ .range = range };
}

pub fn RangeFormatter(Range: type) type {
    return struct {
        range: Range,
        pub inline fn format(this: @This(), writer: *std.Io.Writer) !void {
            const slice = std.mem.sliceAsBytes(this.range);
            if (slice.len == 0) {
                try writer.print("0x{x} (empty)", .{@intFromPtr(slice.ptr)});
                return;
            }

            try writer.print("0x{x} - 0x{x}", .{
                @intFromPtr(slice.ptr),
                @intFromPtr(slice.ptr + (slice.len - 1)),
            });
        }
    };
}
