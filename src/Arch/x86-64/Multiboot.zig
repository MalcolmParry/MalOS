const std = @import("std");
const TTY = @import("../../TTY.zig");

extern var multibootInfo: *Info;

const Info = packed struct {
    totalSize: u32,
    reserved: u32,
};

const Tag = packed struct {
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
        const tag: *Tag = @ptrFromInt(tagAddr);
        tagAddr += (@as(u64, tag.size) + 7) & 0xffff_ffff_ffff_fff8;

        TTY.Print("{}\n", .{tag.t});

        if (tag.t == .End)
            break;
    }
}
