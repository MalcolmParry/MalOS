const builtin = @import("builtin");

pub const Arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("Arch/x86-64/Arch.zig"),
    else => @compileError("Unknown architecture."),
};

pub const kernelVirtBase = Arch.kernelVirtBase;
pub const pageSize = Arch.pageSize;
pub const BootCallConv = Arch.BootCallConv;

pub const Interrupt = Arch.Interrupt;
pub const VGA = Arch.VGA;

pub const InitBootInfo = Arch.InitBootInfo;
pub const halt = Arch.halt;
