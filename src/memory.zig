const arch = @import("arch.zig");
const std = @import("std");

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

pub fn pageAlign(addr: usize) usize {
    return std.mem.alignForward(usize, addr, page_size);
}

pub fn pagesInLength(length: usize) usize {
    return pageAlign(length) / page_size;
}

pub fn pageSliceFromBytes(bytes: []u8) PageSlice {
    const page_many_ptr: PageManyPtr = @ptrCast(@alignCast(bytes.ptr));
    const pages = pagesInLength(bytes.len);
    return page_many_ptr[0..pages];
}

pub fn Phys(comptime Child: type) type {
    _ = Child;
    return opaque {};
}

pub var kernel_range: PhysRange = undefined;
pub const max_modules = 8;
pub var phys_modules: []PhysModule = undefined;
pub const max_available_ranges = 16;
pub var available_ranges: std.ArrayList(PhysRange) = undefined;

pub const PhysModule = struct {
    phys_range: PhysRange,
    name: []const u8,
};

pub const PhysRange = struct {
    base: usize,
    len: usize,

    pub fn alignInwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignForward(usize, this.base, alignment),
            .len = std.mem.alignBackward(usize, this.len, alignment),
        };
    }

    pub fn alignOutwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignBackward(usize, this.base, alignment),
            .len = std.mem.alignForward(usize, this.len, alignment),
        };
    }

    pub fn end(this: @This()) usize {
        return this.base + this.len;
    }

    pub fn fromStartAndEnd(start: usize, end_: usize) @This() {
        return .{
            .base = start,
            .len = end_ - start,
        };
    }

    pub fn addrInRange(this: @This(), addr: usize) bool {
        return (addr >= this.base) and (addr <= this.end());
    }

    pub fn pagesInside(this: @This()) usize {
        return this.len / page_size;
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        try writer.print("0x{x} - 0x{x}", .{ this.base, this.base + this.len });
    }
};
