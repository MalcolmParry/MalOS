const arch = @import("arch.zig");
const std = @import("std");
const mem = @This();

pub const page_size = arch.page_size;
pub const kernel_virt_base: usize = arch.kernel_virt_base;

pub const Page = [page_size]u8;
pub const PagePtr = *align(page_size) Page;
pub const PageManyPtr = [*]align(page_size) Page;
pub const PageSlice = []align(page_size) Page;

pub const PhysPage = Phys(Page);
pub const PhysPagePtr = *align(page_size) PhysPage;
pub const PhysPageManyPtr = [*]align(page_size) PhysPage;
pub const PhysPageSlice = []align(page_size) PhysPage;

pub fn pageAlignForward(addr: usize) usize {
    return std.mem.alignForward(usize, addr, page_size);
}

pub fn pageAlignBackward(addr: usize) usize {
    return std.mem.alignBackward(usize, addr, page_size);
}

pub fn lengthPagesInclusive(length: usize) usize {
    return pageAlignForward(length) / page_size;
}

pub fn pageSliceFromBytesInclusive(bytes: []u8) PageSlice {
    const start_aligned = pageAlignBackward(@intFromPtr(bytes.ptr));
    const page_many_ptr: PageManyPtr = @ptrFromInt(start_aligned);
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
    const end = std.mem.alignForward(usize, @intFromPtr(&x.ptr[x.len]), alignment);
    const ptr: [*]Child = @ptrFromInt(start);
    const len = (end - start) / @sizeOf(Child);
    return ptr[0..len];
}

pub fn addrInSlice(T: type, slice: T, addr: anytype) bool {
    const start = @intFromPtr(slice.ptr);
    const end = @intFromPtr(&slice.ptr[slice.len]);
    const addr_int: usize = switch (@typeInfo(@TypeOf(addr))) {
        .pointer => @intFromPtr(addr),
        .int => addr,
        else => @compileError("invalid type"),
    };

    return (addr_int >= start) and (addr_int < end);
}

pub const PhysRange = Phys(u8).Slice;
pub fn Phys(comptime Child: type) type {
    return opaque {
        const This = @This();

        pub const Slice = struct {
            ptr: usize,
            len: usize,

            pub fn virt(x: Slice) []Child {
                const many: [*]Child = @ptrFromInt(x.ptr);
                return many[0..x.len];
            }

            pub fn fromVirt(x: []Child) Slice {
                return .{
                    .ptr = @intFromPtr(x.ptr),
                    .len = x.len,
                };
            }

            pub fn fromStartAndEnd(start: usize, end_: usize) Slice {
                return .{
                    .ptr = start,
                    .len = (end_ - start) / @sizeOf(Child),
                };
            }

            pub fn end(x: Slice) usize {
                return x.ptr + x.len * @sizeOf(Child);
            }

            pub fn alignInwards(x: Slice, alignment: u16) Slice {
                return fromVirt(mem.alignInwards([]Child, x.virt(), alignment));
            }

            pub fn alignOutwards(x: Slice, alignment: u16) Slice {
                return fromVirt(mem.alignOutwards([]Child, x.virt(), alignment));
            }

            pub fn addrInSlice(x: Slice, addr: anytype) bool {
                return mem.addrInSlice([]Child, x.virt(), addr);
            }

            pub fn lengthPagesInclusive(x: Slice) usize {
                return mem.lengthPagesInclusive(x.len * @sizeOf(Child));
            }

            pub fn lengthBytes(x: Slice) usize {
                return x.len * @sizeOf(Child);
            }

            pub fn format(x: Slice, writer: *std.Io.Writer) !void {
                try writer.print("0x{x} - 0x{x}", .{ x.ptr, x.ptr + x.lengthBytes() });
            }
        };
    };
}

var modules_buffer: [8]Module = undefined;
pub var modules: std.ArrayList(Module) = .initBuffer(&modules_buffer);

pub const Module = struct {
    pub const max_name_len = 16;

    phys_range: PhysRange,
    data: ?[]align(page_size) u8,
    name_buf: [max_name_len]u8,
    name_len: usize,

    pub inline fn name(this: @This()) []const u8 {
        return this.name_buf[0..this.name_len];
    }
};
