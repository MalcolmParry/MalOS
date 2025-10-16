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

extern fn functionInRodata() callconv(.{ .x86_64_sysv = .{} }) void;
const x: u32 = 5;

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

    PMM.TempInit();
    // for (PMM.bitmapRanges.items, PMM.dataRanges.items) |bitmapRange, dataRange| {
    //     std.log.info("Bitmap: {f}\n", .{bitmapRange});
    //     std.log.info("DataRange: {f}\n\n", .{dataRange});
    // }
    Arch.Paging.PreInit();

    const page = try PMM.AllocatePage();
    std.log.info("PMM Allocation: 0x{x}", .{@intFromPtr(page)});
    try Arch.Paging.l4Table.MapPage(page, @ptrFromInt(Arch.Paging.kernelHeapStart), .{
        .present = true,
        .cacheMode = .Full,
        .executable = true,
        .global = false,
        .kernelOnly = true,
        .writable = true,
    }, std.testing.failing_allocator);
    Arch.Paging.InvalidatePages();
    const virt: *volatile u32 = @ptrFromInt(Arch.Paging.kernelHeapStart);
    virt.* = 5;

    const px: *volatile u32 = @constCast(&x);
    px.* = 2; // TODO: get this to cause an error

    // TODO: get this to cause error
    functionInRodata();

    // Arch.Interrupt.Enable();
    Arch.SpinWait();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
