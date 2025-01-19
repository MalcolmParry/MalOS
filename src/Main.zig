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
    for (Mem.modules.?) |module| {
        TTY.Print("\nName: {s}, Start: {x}, Length: {x}\n", .{ module.name, @intFromPtr(module.data.ptr), module.data.len });
    }

    for (Mem.memoryBlocks.?) |block| {
        TTY.Print("Start: {x}, End: {x}, Size: {x}\n", .{ @intFromPtr(block.ptr), @intFromPtr(block.ptr) + @as(u64, block.len * 4096), block.len * 4096 });
    }

    TTY.Print("KernelStart: {x}\n", .{@intFromPtr(Mem.kernelStart.?)});
    TTY.Print("KernelEnd: {x}\n", .{@intFromPtr(Mem.kernelEnd.?)});
    TTY.Print("KernelVirtBase: {x}\n", .{Mem.kernelVirtBase});

    //Arch.Interrupt.Enable();
    Arch.halt();
}

export fn KernelEntry() callconv(Arch.BootCallConv) noreturn {
    KernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    std.debug.panic("KernelMain returned\n", .{});
}
