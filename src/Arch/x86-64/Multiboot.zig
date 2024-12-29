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

const BootInfoInterater = struct {
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

fn BootInfoIterate() BootInfoInterater {
    var result: BootInfoInterater = undefined;
    result.reset();
    return result;
}

extern var __KERNEL_START__: anyopaque;
extern var __KERNEL_END__: anyopaque;
extern var __KERNEL_VIRT_BASE__: anyopaque;

pub fn InitBootInfo(alloc: std.mem.Allocator) !void {
    Mem.kernelVirtBase = &__KERNEL_VIRT_BASE__;
    Mem.kernelStart = &__KERNEL_START__;
    Mem.kernelEnd = @ptrFromInt(@intFromPtr(&__KERNEL_END__) - @intFromPtr(Mem.kernelVirtBase.?));

    var moduleCount: u32 = 0;
    var mmapCount: u32 = 0;

    var iter = BootInfoIterate();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .Module => {
                moduleCount += 1;
            },
            .MMap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tagAddr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entrySize)) {
                    if (entry.t != .Available)
                        continue;

                    mmapCount += 1;
                }
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

                Mem.modules.?[moduleIndex] = .{
                    .data = try alloc.dupe(u8, start[0..len]),
                    .name = try alloc.dupe(u8, name),
                };

                moduleIndex += 1;
            },
            else => {},
        }
    }

    Mem.memoryBlocks = try alloc.alloc([]allowzero Mem.Page, mmapCount);
    var mmapIndex: u32 = 0;

    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .MMap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                std.debug.assert(mmap.version == 0);

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tagAddr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entrySize)) {
                    if (entry.t != .Available)
                        continue;

                    const start: u64 = std.mem.alignForward(usize, entry.base, Arch.pageSize);
                    const end: u64 = std.mem.alignBackward(usize, entry.base + entry.length, Arch.pageSize);

                    if (end <= start) {
                        Mem.memoryBlocks.?.len -= 1;
                        continue;
                    }

                    const len: u64 = end - start;
                    const block: []allowzero Mem.Page = @as([*]allowzero Mem.Page, @ptrFromInt(start))[0..(len / 4096)];
                    Mem.memoryBlocks.?[mmapIndex] = block;

                    mmapIndex += 1;
                }
            },
            else => {},
        }
    }
}
