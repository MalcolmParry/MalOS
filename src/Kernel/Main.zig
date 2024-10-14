const Core = @import("Core.zig");
const Console = @import("Console.zig");
const Interrupt = @import("Interrupt.zig");

export fn KernelMain() noreturn {
    Interrupt.Disable();
    Console.Init();
    Interrupt.Init();
    //Interrupt.Enable();

    Core.int(0x80);
    //@panic("fsugdfs");

    Core.hlt();
}
