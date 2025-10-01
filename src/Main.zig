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

fn KernelMain() !void {
    Arch.Interrupt.Disable();
    Arch.Interrupt.Init();
    TTY.Clear();

    try Arch.InitBootInfo(Mem.fixedAlloc);
    for (Mem.modules) |module| {
        std.log.info("\nName: {s}, Start: {x}, Length: {x}\n", .{ module.name, @intFromPtr(module.data.ptr), module.data.len });
    }

    for (Mem.memReserved.items) |block| {
        std.log.info("Start: {x}, End: {x}, Size: {x}\n", .{ block.base, block.base + block.length - 1, block.length });
    }

    std.log.info("KernelStart: {x}\n", .{Mem.kernelRange.base});
    std.log.info("KernelEnd: {x}\n", .{Mem.kernelRange.base + Mem.kernelRange.length - 1});
    std.log.info("KernelVirtBase: {x}\n", .{Mem.kernelVirtBase});
    std.log.info("MemStart: {x}\n", .{Mem.memAvailable.base});
    std.log.info("MemEnd: {x}\n", .{Mem.memAvailable.base + Mem.memAvailable.length - 1});

    //Arch.Interrupt.Enable();
    Arch.halt();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
