const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");
const Mem = @import("Memory.zig");
const std = @import("std");

pub const panic = @import("Panic.zig").panic;

fn KernelMain() !void {
    Arch.Interrupt.Disable();
    Arch.Interrupt.Init();
    TTY.Clear();

    try Arch.InitBootInfo(Mem.fixedAlloc);
    for (Mem.modules) |module| {
        TTY.Print("\nName: {s}, Start: {x}, Length: {x}\n", .{ module.name, @intFromPtr(module.data.ptr), module.data.len });
    }

    for (Mem.memReserved.items) |block| {
        TTY.Print("Start: {x}, End: {x}, Size: {x}\n", .{ block.base, block.base + block.length - 1, block.length });
    }

    TTY.Print("KernelStart: {x}\n", .{Mem.kernelRange.base});
    TTY.Print("KernelEnd: {x}\n", .{Mem.kernelRange.base + Mem.kernelRange.length - 1});
    TTY.Print("KernelVirtBase: {x}\n", .{Mem.kernelVirtBase});
    TTY.Print("MemStart: {x}\n", .{Mem.memAvailable.base});
    TTY.Print("MemEnd: {x}\n", .{Mem.memAvailable.base + Mem.memAvailable.length - 1});

    //Arch.Interrupt.Enable();
    Arch.halt();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
