const arch = @import("arch.zig");
const std = @import("std");
const mem = @This();

pub const page_size = arch.page_size;
pub const kernel_virt_base: usize = arch.kernel_virt_base;
pub const direct_map: []mem.Page = arch.paging.direct_map;

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
    const len = (end - start) / @sizeOf(Child);
    return ptr[0..len];
}

pub fn physPageAlignOutwards(x: []Phys(u8)) []PhysPage {
    const aligned = alignOutwards([]Phys(u8), x, page_size);
    const start: [*]PhysPage = @ptrCast(@alignCast(aligned.ptr));
    return start[0 .. aligned.len / page_size];
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

pub fn Phys(comptime Child: type) type {
    return struct {
        data: Child,

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
            try writer.print("0x{x} - 0x{x}", .{
                @intFromPtr(this.range.ptr),
                @intFromPtr(this.range.ptr + this.range.len),
            });
        }
    };
}

pub const Module = struct {
    pub const max_name_len = 16;

    phys_range: []align(page_size) Phys(u8),
    data: ?[]align(page_size) u8,
    name_buf: [max_name_len]u8,
    name_len: usize,

    pub inline fn name(this: @This()) []const u8 {
        return this.name_buf[0..this.name_len];
    }
};
