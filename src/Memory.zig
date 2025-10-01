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

var fixedAllocBuffer: [1024 * 1024]u8 = undefined;
var fixedAllocStruct = std.heap.FixedBufferAllocator.init(&fixedAllocBuffer);
pub var fixedAlloc = fixedAllocStruct.allocator();

pub var kernelRange: PhysRange = undefined;
pub const kernelVirtBase: u64 = Arch.kernelVirtBase;
pub var modules: []Module = undefined;
pub var memReserved: std.ArrayList(PhysRange) = undefined;
pub var memAvailable: PhysRange = undefined;

pub const Module = struct {
    data: []const u8,
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
};
