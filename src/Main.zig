const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");
const Mem = @import("Memory.zig");
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
    Arch.Interrupt.Disable();
    Arch.Interrupt.Init();
    TTY.Clear();

    Arch.InitBootInfo(fixedAlloc);
    for (Mem.physModules) |module| {
        std.log.info("Module '{s}' at 0x{x} - 0x{x}\n", .{ module.name, module.physData.base, module.physData.base + module.physData.length });
    }

    for (Mem.availableRanges.items) |range| {
        std.log.info("Available: 0x{x} - 0x{x}\n", .{ range.base, range.base + range.length });
    }

    std.log.info("Kernel 0x{x} - 0x{x}\n", .{ Mem.kernelRange.base, Mem.kernelRange.base + Mem.kernelRange.length });
    std.log.info("KernelVirtBase: {x}\n", .{Mem.kernelVirtBase});

    //Arch.Interrupt.Enable();
    Arch.halt();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
