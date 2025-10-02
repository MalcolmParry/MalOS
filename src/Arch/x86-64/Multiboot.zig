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

fn BootInfoIterate() BootInfoIterater {
    var result: BootInfoIterater = undefined;
    result.reset();
    return result;
}

extern var __KERNEL_START__: anyopaque;
extern var __KERNEL_END__: anyopaque;

pub fn InitBootInfo(alloc: std.mem.Allocator) !void {
    Mem.memReserved = try std.ArrayList(Mem.PhysRange).initCapacity(alloc, 5);
    Mem.kernelRange = Mem.PhysRange.FromStartAndEnd(@intFromPtr(&__KERNEL_START__), @intFromPtr(&__KERNEL_END__) - Mem.kernelVirtBase);
    try Mem.memReserved.append(alloc, Mem.kernelRange);

    var moduleCount: u32 = 0;

    var iter = BootInfoIterate();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .Module => {
                moduleCount += 1;
            },
            else => {},
        }
    }

    Mem.modules = try alloc.alloc(Mem.Module, moduleCount);
    var moduleIndex: u32 = 0;

    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .Module => {
                const module: *align(1) Tag.Module = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                const nameStart: [*]u8 = @ptrFromInt(@intFromPtr(module) + @sizeOf(Tag.Module));
                const nameEnd: *u8 = @ptrFromInt(@intFromPtr(tag) + tag.size - 1);
                const name: []u8 = nameStart[0 .. @intFromPtr(nameEnd) - @intFromPtr(nameStart)];

                const start: [*]u8 = @ptrFromInt(module.start);
                const len: u32 = module.end - module.start + 1;

                std.log.info("module loaded: {s}\n", .{name});

                Mem.modules[moduleIndex] = .{
                    .data = try alloc.dupe(u8, start[0..len]),
                    .name = try alloc.dupe(u8, name),
                };

                moduleIndex += 1;
            },
            else => {},
        }
    }

    var memStart: u64 = std.math.maxInt(u64);
    var memEnd: u64 = 0;

    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .MMap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                std.debug.assert(mmap.version == 0);

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tagAddr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entrySize)) {
                    if (entry.t == .Available) {
                        const entryEnd = entry.base + entry.length - 1;

                        if (entry.base < memStart)
                            memStart = entry.base;

                        if (entryEnd > memEnd)
                            memEnd = entryEnd;

                        continue;
                    }

                    try Mem.memReserved.append(alloc, .{ .base = entry.base, .length = entry.length });
                }
            },
            else => {},
        }
    }

    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .MMap, .Module => {},
            else => std.log.info("multiboot tag: {s}\n", .{@tagName(tag.t)}),
        }
    }

    Mem.memAvailable = Mem.PhysRange.FromStartAndEnd(memStart, memEnd);
}
