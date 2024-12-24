const std = @import("std");
const TTY = @import("../../TTY.zig");

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

pub fn InitBootInfo(alloc: std.mem.Allocator) !void {
    _ = alloc;

    var tagAddr: u64 = @intFromPtr(multibootInfo) + 8;
    const limit = tagAddr + multibootInfo.totalSize;

    while (tagAddr < limit) {
        const tag: *align(1) Tag = @ptrFromInt(tagAddr);
        tagAddr += (tag.size + 7) & ~@as(u64, 7);

        switch (tag.t) {
            .MMap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));
                TTY.Print("size: {} bytes, version: {}\n", .{ mmap.entrySize, mmap.version });

                if (mmap.version != 0) {
                    std.debug.panic("Invalid MMap tag version in multiboot info.", .{});
                }

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < tagAddr) {
                    TTY.Print("Start: {x}, End: {x}, ", .{ entry.base, entry.base + entry.length });
                    if (entry.length < 1024 * 1024) {
                        TTY.Print("Size: {}KB", .{entry.length / 1024});
                    } else if (entry.length < 1024 * 1024 * 1024) {
                        TTY.Print("Size: {}MB", .{entry.length / (1024 * 1024)});
                    } else {
                        TTY.Print("Size: {}GB", .{entry.length / (1024 * 1024 * 1024)});
                    }
                    TTY.Print(", Type: {s}\n", .{@tagName(entry.t)});

                    entry = @ptrFromInt(@intFromPtr(entry) + mmap.entrySize);
                }
            },
            .End => {
                break;
            },
            else => {
                TTY.Print("{}\n", .{tag.t});
            },
        }
    }
}
