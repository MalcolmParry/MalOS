const Mem = @import("../../Memory.zig");
const std = @import("std");
const TTY = @import("../../TTY.zig");
const Arch = @import("Arch.zig");

extern var multibootInfo: *Info;

const Info = packed struct {
    totalSize: u32,
    reserved: u32,
};

const Tag = packed struct {
    const MMap = packed struct {
        const Entry = packed struct {
            const Type = enum(u32) {
                Available = 1,
                Reserved = 2,
                ACPIReclaimable = 3,
                NVS = 4,
                Bad = 5,
            };

            base: u64,
            length: u64,
            t: Entry.Type,
            pad: u32 = 0,
        };

        entrySize: u32,
        version: u32,
    };

    const Module = packed struct {
        start: u32,
        end: u32,
    };

    const LoadBaseAddr = u32;

    const Type = enum(u32) {
        End,
        CMDLine,
        BootLoaderName,
        Module,
        MemInfo,
        BootDev,
        MMap,
        VBE,
        FrameBuffer,
        ELFSections,
        APM,
        EFI32,
        EFI64,
        SMBIOS,
        ACPIOld,
        ACPINew,
        Network,
        EFIMMap,
        EFIBS,
        EFI32IH,
        EFI64IH,
        LoadBaseAddr,
    };

    t: Type,
    size: u32,
};

const BootInfoIterater = struct {
    tagAddr: u64,

    fn next(this: *@This()) ?*align(1) Tag {
        const tag: *align(1) Tag = @ptrFromInt(this.tagAddr);
        this.tagAddr += (tag.size + 7) & ~@as(u64, 7);
        if (this.tagAddr > @intFromPtr(multibootInfo) + 8 + multibootInfo.totalSize)
            return null;
        if (tag.t == .End)
            return null;
        return tag;
    }

    fn reset(this: *@This()) void {
        this.tagAddr = @intFromPtr(multibootInfo) + 8;
    }
};

extern var __KERNEL_START__: anyopaque;
extern var __KERNEL_END__: anyopaque;

var physModules: [Mem.maxModules]Mem.PhysModule = undefined;
var rawAvailableRanges: [Mem.maxAvailableRanges]Mem.PhysRange = undefined;

pub fn InitBootInfo(alloc: std.mem.Allocator) void {
    Mem.kernelRange = Mem.PhysRange.FromStartAndEnd(@intFromPtr(&__KERNEL_START__), @intFromPtr(&__KERNEL_END__));

    var moduleIndex: u32 = 0;
    var availableRanges = std.ArrayList(Mem.PhysRange).fromOwnedSlice(&rawAvailableRanges);
    availableRanges.items.len = 0;

    var iter: BootInfoIterater = undefined;
    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .Module => {
                const module: *align(1) Tag.Module = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                const nameStart: [*]u8 = @ptrFromInt(@intFromPtr(module) + @sizeOf(Tag.Module));
                const nameEnd: *u8 = @ptrFromInt(@intFromPtr(tag) + tag.size - 1);
                const name: []u8 = nameStart[0 .. @intFromPtr(nameEnd) - @intFromPtr(nameStart)];

                const len: u32 = module.end - module.start + 1;

                physModules[moduleIndex] = .{
                    .physData = .{ .base = module.start, .length = len },
                    .name = alloc.dupe(u8, name) catch @panic("out of memory"),
                };

                moduleIndex += 1;
            },
            .MMap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));
                if (mmap.version != 0)
                    @panic("wrong mmap version");

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tagAddr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entrySize)) {
                    if (entry.t == .ACPIReclaimable)
                        std.log.info("ACPI Reclaimable memory at 0x{x} - 0x{x}\n", .{ entry.base, entry.base + entry.length });

                    if (entry.t != .Available)
                        continue;

                    std.log.info("mem free: 0x{x} - 0x{x}\n", .{ entry.base, entry.base + entry.length });
                    var start: usize = std.mem.alignForward(usize, entry.base, Arch.pageSize);
                    const end: usize = std.mem.alignBackward(usize, entry.base + entry.length, Arch.pageSize);

                    const minAvailableMemory = 64 * 1024;
                    if (start < minAvailableMemory)
                        start = minAvailableMemory;

                    if (start >= end)
                        continue;

                    const range: Mem.PhysRange = .{
                        .base = start,
                        .length = end - start,
                    };

                    availableRanges.appendBounded(range) catch @panic("not enough memory ranges");
                }
            },
            .LoadBaseAddr => {
                const loadBaseAddr: *align(1) Tag.LoadBaseAddr = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));
                if (loadBaseAddr.* != Mem.kernelRange.base)
                    @panic("wrong kernel load address");
            },
            else => std.log.info("multiboot tag: {s}\n", .{@tagName(tag.t)}),
        }
    }

    for (availableRanges.items) |range| {
        std.log.info("Range 0x{x} - 0x{x}\n", .{ range.base, range.base + range.length });
    }

    ReserveRegion(&availableRanges, Mem.kernelRange.AlignOutwards(Mem.pageSize));

    for (availableRanges.items) |range| {
        std.log.info("Range2 0x{x} - 0x{x}\n", .{ range.base, range.base + range.length });
    }

    Mem.physModules = physModules[0..moduleIndex];
    Mem.availableRanges = availableRanges.items;
}

fn ReserveRegion(availableRanges: *std.ArrayList(Mem.PhysRange), reserved: Mem.PhysRange) void {
    var i: u32 = 0;
    while (i < availableRanges.items.len) {
        const range = availableRanges.items[i];
        var start = range.base;
        var end = range.base + range.length;

        if (reserved.AddrInRange(start))
            start = reserved.End() + 1;

        if (reserved.AddrInRange(end))
            end = reserved.base;

        start = std.mem.alignForward(usize, start, Mem.pageSize);
        end = std.mem.alignBackward(usize, end, Mem.pageSize);

        if (start >= end) {
            _ = availableRanges.swapRemove(i);
            continue;
        }

        availableRanges.items[i] = .{ .base = start, .length = end - start };
        i += 1;
    }
}
