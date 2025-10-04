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
pub const kernelVirtBase: u64 = Arch.kernelVirtBase;
pub const maxModules = 8;
pub var physModules: []PhysModule = undefined;
pub const maxAvailableRanges = 16;
pub var availableRanges: []PhysRange = undefined;

pub const PhysModule = struct {
    physData: PhysRange,
    name: []const u8,
};

pub const PhysRange = struct {
    base: u64,
    length: u64,

    pub fn AlignInwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignForward(u64, this.base, alignment),
            .length = std.mem.alignBackward(u64, this.length, alignment),
        };
    }

    pub fn AlignOutwards(this: @This(), alignment: u16) @This() {
        return .{
            .base = std.mem.alignBackward(u64, this.base, alignment),
            .length = std.mem.alignForward(u64, this.length, alignment),
        };
    }

    pub fn End(this: @This()) u64 {
        return this.base + this.length - 1;
    }

    pub fn FromStartAndEnd(start: u64, end: u64) @This() {
        return .{
            .base = start,
            .length = end - start + 1,
        };
    }

    pub fn AddrInRange(this: @This(), addr: u64) bool {
        return (addr >= this.base) and (addr <= this.End());
    }
};
