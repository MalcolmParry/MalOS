const builtin = @import("builtin");

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("Arch/x86-64/Arch.zig"),
    else => @compileError("Unknown architecture."),
};
