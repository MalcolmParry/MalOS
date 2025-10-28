const builtin = @import("builtin");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("Arch/x86-64/Arch.zig"),
    else => @compileError("Unknown architecture."),
};

pub const kernel_virt_base = arch.kernel_virt_base;
pub const page_size = arch.page_size;
pub const boot_call_conv = arch.boot_call_conv;

pub const interrupt = arch.interrupt;
pub const vga = arch.vga;
pub const paging = arch.paging;
pub const PageTable = arch.PageTable;

pub const initBootInfo = arch.initBootInfo;
pub const halt = arch.halt;
pub const spinWait = arch.spinWait;
pub const syscall = arch.syscall;
