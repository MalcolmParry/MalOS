const std = @import("std");
const Mem = @import("Memory.zig");

pub const maxBitmaps = 8;
var bitmapsRangesRaw: [maxBitmaps]Mem.PhysRange = undefined;
var dataRangesRaw: [maxBitmaps]Mem.PhysRange = undefined;
pub var bitmapRanges: std.ArrayList(Mem.PhysRange) = .initBuffer(&bitmapsRangesRaw);
pub var dataRanges: std.ArrayList(Mem.PhysRange) = .initBuffer(&dataRangesRaw);

pub fn PreInit() void {
    for (Mem.availableRanges.items) |wholeRange| {
        const pagesInRange = wholeRange.length / Mem.pageSize;
        const bitmapWidth = std.mem.alignForward(usize, pagesInRange, 8) / 8;

        const bitmapRange: Mem.PhysRange = .{
            .base = wholeRange.base,
            .length = std.mem.alignForward(usize, bitmapWidth, @sizeOf(usize)), // std.DynamicBitSetUnmanaged works in chunks of @sizeOf(usize)
        };
        const bitmapRangeAligned = bitmapRange.AlignOutwards(Mem.pageSize);

        bitmapRanges.appendBounded(bitmapRange) catch @panic("out of memory");
        dataRanges.appendBounded(.{
            .base = bitmapRangeAligned.base + bitmapRangeAligned.length,
            .length = wholeRange.length - bitmapRangeAligned.length,
        }) catch @panic("out of memory");
    }
}
