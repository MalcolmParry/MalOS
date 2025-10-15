const Arch = @import("Arch.zig");
const std = @import("std");

pub const pageSize = Arch.pageSize;
pub const Page = [pageSize]u8;

pub fn Phys(comptime Child: type) type {
    return opaque {
        fn GetVirt(this: *@This()) *Child {
            // todo: check page tables
            return @ptrCast(this);
        }
    };
}

pub var kernelRange: PhysRange = undefined;
pub const kernelVirtBase: usize = Arch.kernelVirtBase;
pub const maxModules = 8;
pub var physModules: []PhysModule = undefined;
pub const maxAvailableRanges = 16;
pub var availableRanges: std.ArrayList(PhysRange) = undefined;

pub const PhysModule = struct {
    physData: PhysRange,
    name: []const u8,
};

pub const PhysRange = struct {
    base: usize,
    length: usize,

    pub fn AlignInwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignForward(usize, this.base, alignment),
            .length = std.mem.alignBackward(usize, this.length, alignment),
        };
    }

    pub fn AlignOutwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignBackward(usize, this.base, alignment),
            .length = std.mem.alignForward(usize, this.length, alignment),
        };
    }

    pub fn End(this: @This()) usize {
        return this.base + this.length;
    }

    pub fn FromStartAndEnd(start: usize, end: usize) @This() {
        return .{
            .base = start,
            .length = end - start,
        };
    }

    pub fn AddrInRange(this: @This(), addr: usize) bool {
        return (addr >= this.base) and (addr <= this.End());
    }

    pub fn PagesInside(this: @This()) usize {
        return this.length / pageSize;
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        try writer.print("0x{x} - 0x{x}", .{ this.base, this.base + this.length });
    }
};
