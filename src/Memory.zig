const Arch = @import("Arch.zig");
const std = @import("std");

pub const pageSize = Arch.pageSize;
pub const Page = [pageSize]u8;

var fixedAllocBuffer: [1024 * 8]u8 = undefined;
var fixedAllocStruct = std.heap.FixedBufferAllocator.init(&fixedAllocBuffer);
pub var fixedAlloc = fixedAllocStruct.allocator();

pub var kernelStart: ?*anyopaque = null;
pub var kernelEnd: ?*anyopaque = null;
pub var kernelVirtBase: ?*anyopaque = null;
pub var modules: ?[]Module = null;
pub var memoryBlocks: ?[][]allowzero Page = null;

pub const Module = struct {
    data: []const u8,
    name: []const u8,
};
