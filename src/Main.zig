const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");
const Mem = @import("Memory.zig");
const PMM = @import("PMM.zig");
const std = @import("std");

pub const panic = @import("Panic.zig").panic;
pub const std_options: std.Options = .{
    .logFn = TTY.Log,
    .page_size_min = Mem.pageSize,
    .page_size_max = Mem.pageSize,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = null;
    };
};

var fixedAllocBuffer: [512]u8 = undefined;
var fixedAllocStruct = std.heap.FixedBufferAllocator.init(&fixedAllocBuffer);
pub var fixedAlloc = fixedAllocStruct.allocator();

fn KernelMain() !void {
    TTY.Clear();
    Arch.Interrupt.Disable();
    Arch.Interrupt.Init();

    Arch.InitBootInfo(fixedAlloc);
    for (Mem.physModules) |module| {
        std.log.info("Module '{s}' at {f}\n", .{ module.name, module.physData });
    }

    for (Mem.availableRanges.items) |range| {
        std.log.info("Available: {f}\n", .{range});
    }

    std.log.info("Kernel {f}\n", .{Mem.kernelRange});
    std.log.info("KernelVirtBase: {x}\n", .{Mem.kernelVirtBase});

    PMM.PreInit();
    for (PMM.bitmapRanges.items, PMM.dataRanges.items) |bitmapRange, dataRange| {
        std.log.info("Bitmap: {f}\n", .{bitmapRange});
        std.log.info("DataRange: {f}\n\n", .{dataRange});
    }
    Arch.Paging.PreInit();

    const x: u32 = 5;
    const px: *u32 = @constCast(&x);
    px.* = 2; // TODO: get this to cause an error

    //Arch.Interrupt.Enable();
    Arch.SpinWait();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
