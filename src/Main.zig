const Arch = @import("Arch.zig");
const TTY = @import("TTY.zig");
const std = @import("std");

pub fn panic(str: []const u8, trace: ?*std.builtin.StackTrace, returnAddress: ?usize) noreturn {
    _ = trace;
    _ = returnAddress;

    TTY.Print("PANIC: {s}\n", .{str});
    Arch.Interrupt.Disable();
    Arch.halt();
}

var fixedAllocBuffer: [1024]u8 = undefined;
var fixedAllocStruct = std.heap.FixedBufferAllocator.init(&fixedAllocBuffer);
var fixedAlloc = fixedAllocStruct.allocator();

export fn KernelMain() noreturn {
    Arch.Interrupt.Disable();
    Arch.Interrupt.Init();
    TTY.Clear();

    try Arch.InitBootInfo(fixedAlloc);

    //Arch.Interrupt.Enable();
    Arch.halt();
}
